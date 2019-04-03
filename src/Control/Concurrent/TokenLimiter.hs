-- | Fast rate-limiting via token bucket algorithm.

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
  , initialBucketTokens :: {-# UNPACK #-} !Count
  , bucketRefillTokensPerSecond :: {-# UNPACK #-} !Count
  , clockAction :: IO TimeSpec
  , delayAction :: TimeSpec -> IO ()
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
newRateLimiter (LimitConfig _ initial _ nowIO _) = do
    !now <- nowIO
    !mv <- newMVar now
    mk mv
  where
    !(I# initial#) = initial
    !(I# nbytes#) = sizeOf (0 :: Count)
    mk mv = IO $ \s# ->
            case newByteArray# nbytes# s# of
              (# s1#, arr# #) -> case writeIntArray# arr# 0# initial# s1# of
                s2# -> (# s2#, RateLimiter arr# mv #)

rateToNsPer :: Integral a => a -> a
rateToNsPer tps = 1000000000 `div` tps

newtype DebitResult = DebitResult Int
  deriving (Eq)

readBucket :: MutableByteArray# RealWorld -> IO Int
readBucket bucket# = IO $ \s# ->
                     case readIntArray# bucket# 0# s# of
                       (# s1#, w# #) -> (# s1#, I# w# #)

tryDebit :: LimitConfig -> RateLimiter -> Count -> IO Bool
tryDebit cfg@(LimitConfig _ _ _ nowIO _) = tryDebit' nowIO cfg


tryDebit' :: IO TimeSpec -> LimitConfig -> RateLimiter -> Count -> IO Bool
tryDebit' nowIO (LimitConfig maxTokens _ refillRate _ _)
         (RateLimiter bucket# mv) ndebits = tryGrab
  where
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
            b@(I# bb#) <- rdBucket
            let !b'@(I# bb'#) = min (fromIntegral maxTokens) (b + numNewTokens)
            -- only possible if b == maxTokens
            if b == b'
              then return False
              else IO $ \s# -> case casIntArray# bucket# 0# bb# bb'# s# of
                                 (# s1#, prev# #) -> if (I# prev#) == b
                                                        then (# s1#, True #)
                                                        else let (IO f) = go in f s1#

    fetchMore = modifyMVar mv $ \lastUpdated -> do
        !now <- nowIO
        let !numNanos = toNanoSecs $ now - lastUpdated
        let !nanosPerToken = toInteger $ rateToNsPer refillRate
        let !numNewTokens0 = numNanos `div` nanosPerToken
        let numNewTokens = fromIntegral numNewTokens0
        -- TODO: allow partial debit fulfillment?
        if numNewTokens < ndebits
          then return (lastUpdated, False)
          else do
              if numNewTokens == fromIntegral ndebits
                then return (now, True)
                else do
                  b <- addLoop (numNewTokens - fromIntegral ndebits)
                  if b
                    then return (now, True)
                    else return (lastUpdated, True)

waitForTokens :: TimeSpec -> LimitConfig -> RateLimiter -> Count -> IO ()
waitForTokens now (LimitConfig _ _ refillRate _ sleepFor)
              (RateLimiter bucket# mv) ntokens = do
    b <- rdBucket
    if fromIntegral b >= ntokens
      then return ()
      else do
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

waitDebit :: LimitConfig -> RateLimiter -> Count -> IO ()
waitDebit lc rl ndebits = go
  where
    -- ask for time at most once through the loop.
    cacheClock ref = do
        m <- readIORef ref
        case m of
          Nothing -> do now <- clockAction lc
                        writeIORef ref (Just now)
                        return now
          (Just t) -> return t

    go = do
        ref <- newIORef Nothing
        let clock = cacheClock ref
        b <- tryDebit' clock lc rl ndebits
        if b
          then return ()
          else do
            now <- clock
            waitForTokens now lc rl ndebits >> go
