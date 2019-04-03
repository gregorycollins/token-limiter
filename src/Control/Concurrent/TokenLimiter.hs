-- | Fast rate-limiting via token bucket algorithm.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}

module Control.Concurrent.TokenLimiter
  ( newRateLimiter
  , tryDebit
  , waitDebit
  , Count
  , LimitConfig(..)
  , RateLimiter
  ) where

import Control.Concurrent
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
  } deriving (Show, Generic)

data RateLimiter = RateLimiter {
    _bucketTokens :: !(MutableByteArray# RealWorld)
  , _bucketLastServiced :: {-# UNPACK #-} !(MVar TimeSpec)
  }

nowIO :: IO TimeSpec
nowIO = getTime MonotonicCoarse

newRateLimiter :: LimitConfig -> IO RateLimiter
newRateLimiter (LimitConfig _ initial _) = do
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
tryDebit (LimitConfig maxTokens _ refillRate) (RateLimiter bucket# mv) ndebits = tryGrab
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
              let !lastUpdated' = lastUpdated +
                                  fromNanoSecs (toInteger numNewTokens * toInteger nanosPerToken)
              if numNewTokens == fromIntegral ndebits
                then return (lastUpdated', True)
                else do
                  b <- addLoop (numNewTokens - fromIntegral ndebits)
                  if b
                    then return (lastUpdated', True)
                    else return (lastUpdated, True)

waitForTokens :: LimitConfig -> RateLimiter -> Count -> IO ()
waitForTokens (LimitConfig _ _ refillRate) (RateLimiter bucket# _) ntokens = do
    b <- rdBucket
    if fromIntegral b >= ntokens
      then return ()
      else do
          let numNeeded = fromIntegral ntokens - b
          let nanos = nanosPerToken * toInteger numNeeded
          let delta = nanosPerToken `div` 2
          let sleepMicros = max 1 (fromInteger ((nanos - delta + 500) `div` 1000))
          threadDelay sleepMicros
  where
    rdBucket = readBucket bucket#
    nanosPerToken = toInteger $ rateToNsPer refillRate

waitDebit :: LimitConfig -> RateLimiter -> Count -> IO ()
waitDebit lc rl ndebits = go
  where
    go = do
        b <- tryDebit lc rl ndebits
        if b
          then return ()
          else waitForTokens lc rl ndebits >> go
