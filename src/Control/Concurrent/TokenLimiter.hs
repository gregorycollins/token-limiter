-- | Fast rate-limiting via token bucket algorithm. Uses lock-free
-- compare-and-swap operations on the fast path when debiting tokens.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}

module Control.Concurrent.TokenLimiter
  ( Count
  , LimitConfig(..)
  , RateLimiter
  , newRateLimiter
  , tryDebit
  , waitDebit
  , defaultLimitConfig
  ) where

import Control.Concurrent
import Data.IORef
import Foreign.Storable
import GHC.Generics
import GHC.Int
import GHC.IO
import GHC.Prim
import System.Clock

type Count = Int

data LimitConfig = LimitConfig {
    maxBucketTokens :: {-# UNPACK #-} !Count
      -- ^ maximum number of tokens the bucket can hold at any one time.
  , initialBucketTokens :: {-# UNPACK #-} !Count
      -- ^ how many tokens should be in the bucket when it's created.
  , bucketRefillTokensPerSecond :: {-# UNPACK #-} !Count
      -- ^ how many tokens should replenish the bucket per second.
  , clockAction :: IO TimeSpec
      -- ^ clock action, 'defaultLimitConfig' uses the coarse monotonic system
      -- clock. Mostly provided for mocking in the testsuite.
  , delayAction :: TimeSpec -> IO ()
      -- ^ action to delay for the given time interval. 'defaultLimitConfig'
      -- forwards to 'threadDelay'. Provided for mocking.
  } deriving (Generic)

data RateLimiter = RateLimiter {
    _bucketTokens :: !(MutableByteArray# RealWorld)
  , _bucketLastServiced :: {-# UNPACK #-} !(MVar TimeSpec)
  }


defaultLimitConfig :: LimitConfig
defaultLimitConfig = LimitConfig 5 1 1 nowIO sleepIO
  where
    nowIO = getTime MonotonicCoarse
    sleepIO x = threadDelay $! fromInteger (toNanoSecs x `div` 1000)


newRateLimiter :: LimitConfig -> IO RateLimiter
newRateLimiter lc = do
    !now <- nowIO
    !mv <- newMVar now
    mk mv
  where
    initial = initialBucketTokens lc
    nowIO = clockAction lc
    !(I# initial#) = initial
    !(I# nbytes#) = sizeOf $! initial
    mk mv = IO $ \s# ->
            case newByteArray# nbytes# s# of
              (# s1#, arr# #) -> case writeIntArray# arr# 0# initial# s1# of
                s2# -> (# s2#, RateLimiter arr# mv #)

rateToNsPer :: Integral a => a -> a
rateToNsPer tps = 1000000000 `div` tps

readBucket :: MutableByteArray# RealWorld -> IO Int
readBucket bucket# = IO $ \s# ->
                     case readIntArray# bucket# 0# s# of
                       (# s1#, w# #) -> (# s1#, I# w# #)

-- | Attempt to pull the given number of tokens from the bucket. Returns 'True'
-- if the tokens were successfully debited.
tryDebit :: LimitConfig -> RateLimiter -> Count -> IO Bool
tryDebit cfg = tryDebit' (clockAction cfg) cfg

tryDebit' :: IO TimeSpec -> LimitConfig -> RateLimiter -> Count -> IO Bool
tryDebit' nowIO cfg rl ndebits = tryGrab
  where
    bucket# = _bucketTokens rl
    mv = _bucketLastServiced rl
    maxTokens = maxBucketTokens cfg
    refillRate = bucketRefillTokensPerSecond cfg
    rdBucket = readBucket bucket#

    tryGrab = do
        !nt <- rdBucket
        if nt >= ndebits
          then tryCas nt (nt - ndebits)
          else fetchMore

    tryCas !nt@(I# nt#) !(I# newVal#) =
        IO $ \s# -> case casIntArray# bucket# 0# nt# newVal# s# of
                      (# s1#, prevV# #) -> let prevV = I# prevV#
                                               rest = if prevV == nt
                                                        then return True
                                                        else tryGrab
                                               (IO restF) = rest
                                           in restF s1#

    addLoop !numNewTokens = go
      where
        go = do
            !b@(I# bb#) <- rdBucket
            let !(I# bb'#) = min (fromIntegral maxTokens) (b + numNewTokens)
            IO $ \s# -> case casIntArray# bucket# 0# bb# bb'# s# of
                          (# s1#, prev# #) -> if (I# prev#) == b
                                                 then (# s1#, () #)
                                                 else let (IO f) = go in f s1#

    fetchMore = modifyMVar mv $ \lastUpdated -> do
        !now <- nowIO
        let !numNanos = toNanoSecs $ now - lastUpdated
        let !nanosPerToken = toInteger $ rateToNsPer refillRate
        let !numNewTokens0 = numNanos `div` nanosPerToken
        let numNewTokens = fromIntegral numNewTokens0
        -- TODO: allow partial debit fulfillment?
        if numNewTokens < ndebits
          then return $! (lastUpdated, False)
          else do
              let !lastUpdated' = lastUpdated +
                                  fromNanoSecs (toInteger numNewTokens * toInteger nanosPerToken)
              if numNewTokens == fromIntegral ndebits
                then return (lastUpdated', True)
                else do
                  addLoop (numNewTokens - fromIntegral ndebits)
                  return $! (lastUpdated', True)

waitForTokens :: TimeSpec -> LimitConfig -> RateLimiter -> Count -> IO ()
waitForTokens now cfg (RateLimiter bucket# mv) ntokens = do
    b <- rdBucket
    lastUpdated <- readMVar mv
    let numNeeded = fromIntegral ntokens - b
    let delta = toNanoSecs $ now - lastUpdated
    let nanos = nanosPerToken * toInteger numNeeded
    let sleepNanos = max 1 (fromInteger (nanos - delta + 500))
    let !sleepSpec = fromNanoSecs sleepNanos
    sleepFor sleepSpec
  where
    rdBucket = readBucket bucket#
    nanosPerToken = toInteger $ rateToNsPer refillRate
    refillRate = bucketRefillTokensPerSecond cfg
    sleepFor = delayAction cfg

-- | Attempt to pull /k/ tokens from the bucket, sleeping in a loop until they
-- become available. Will not partially fulfill token requests (i.e. it loops
-- until the entire allotment is available in one swoop), and makes no attempt
-- at fairness or queueing (i.e. you will definitely get \"thundering herd\" on
-- wakeup if a number of threads are contending for fresh tokens).
waitDebit :: LimitConfig -> RateLimiter -> Count -> IO ()
waitDebit lc rl ndebits = go
  where
    -- ask for time at most once through the loop.
    cacheClock ref = do
        m <- readIORef ref
        case m of
          Nothing -> do !now <- clockAction lc
                        writeIORef ref (Just now)
                        return now
          (Just t) -> return t

    go = do
        ref <- newIORef Nothing
        let clock = cacheClock ref
        b <- tryDebit' clock lc rl ndebits
        if b
          then return $! ()
          else do
            now <- clock
            waitForTokens now lc rl ndebits >> go
