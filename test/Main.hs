{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Main ( main ) where

import Control.Concurrent
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.TokenLimiter
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Clock
import Test.Tasty
import Test.Tasty.HUnit
import Text.Printf

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "token-limiter" [ trivialTest ]

nowIO :: IO TimeSpec
nowIO = getTime MonotonicCoarse

rateToNsPer :: Integral a => a -> a
rateToNsPer tps = 1000000000 `div` tps

trivialTest :: TestTree
trivialTest = testCaseSteps "basic token limit operation" $
              \step -> T.putStrLn "" >> go (0 :: Int) step
  where
    go !n step = do
        void $ step $ "case " ++ show n
        ref <- newIORef (0 :: Int)
        begin <- nowIO
        startMv <- newEmptyMVar
        bracket (initialize ref) destroy (wait startMv)
        end <- nowIO

        startP <- readMVar startMv
        numTokensDebited <- toInteger <$> readIORef ref
        let maxNanos = toNanoSecs $ end - begin
        let expectedNanos = toNanoSecs (end - startP) - nsPer
        let maxNumExpected = 1 + (maxNanos * toInteger qps) `div` 1000000000
        let numExpected = (expectedNanos * toInteger qps) `div` 1000000000
        let diff = fromIntegral (abs (numTokensDebited - numExpected)) /
                   ((fromIntegral numExpected) :: Double)
        let diffS = printf "%.2f" (diff * 100.0)

        T.putStrLn $ T.pack $ concat ["got ", show numTokensDebited,
                                      ", ex rng [",
                                      show (approx numExpected),
                                      ",", show maxNumExpected,
                                      "] (got within ",
                                      diffS,
                                      "% of target ",
                                      show numExpected,
                                      ")"
                                     ]
        assertBool "no more than maxNumExpected" $ numTokensDebited <= maxNumExpected
        assertBool "got at least what we were expecting " $
          numTokensDebited >= approx numExpected
        when (n < ntests) $ go (n+1) step

    bucketSz = 10
    ntests = 30
    nthreads = 5
    qps = 1500
    nsPer = toInteger $ rateToNsPer qps
    confidence = 95
    approx x = (x * confidence) `div` 100
    nsecs :: Double
    nsecs = 0.5
    ratecfg = LimitConfig bucketSz 1 qps

    nmillis = round (nsecs * 1000000)           -- n seconds
    wait nowMv = const $ do
        nowIO >>= putMVar nowMv
        threadDelay (nmillis + fromIntegral (nsPer `div` 500))
    initialize ref = do
        limiter <- newRateLimiter ratecfg
        mvs <- replicateM nthreads newEmptyMVar
        threads <- mapM (Async.async . threadProc ref limiter) mvs
        -- wait until threads are running to begin timer
        mapM_ takeMVar mvs
        return threads

    destroy xs = mapM_ Async.uninterruptibleCancel xs

    threadProc ref limiter mv = putMVar mv () >> m
      where
        m = do
            waitDebit ratecfg limiter 1
            void $ atomicModifyIORef' ref $ \x -> let !y = x+1 in (y, y)
            m
