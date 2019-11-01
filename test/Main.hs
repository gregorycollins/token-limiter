{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
tests = testGroup "token-limiter" [
    ioTest,
    mockTests
  ]

nowIO :: IO TimeSpec
nowIO = getTime MonotonicCoarse

rateToNsPer :: Integral a => a -> a
rateToNsPer tps = 1000000000 `div` tps

-- TODO: move this test to another executable, because of the way that it works
-- it's inherently flaky.
ioTest :: TestTree
ioTest = testCaseSteps "concurrent token limit operation in IO" $
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
        let expectedNanos = toNanoSecs (end - startP)
        let maxNumExpected = 4 + (maxNanos * toInteger qps) `div` 1000000000
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
    confidence = 90
    approx x = (x * confidence) `div` 100
    nsecs :: Double
    nsecs = 0.5
    ratecfg = defaultLimitConfig {
                 maxBucketTokens = bucketSz,
                 initialBucketTokens = 1,
                 bucketRefillTokensPerSecond = qps
                 }

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

mockTests :: TestTree
mockTests = testGroup "mock tests" [
    mockEmptyRead,
    mockRateLimit,
    mockDelay,
    mockLongerRateLimit,
    mockPenalize
    ]

mockConfig
    :: Count
    -> Count
    -> Count
    -> [Integer]
    -> IO (IORef ([Integer] -> [Integer]), LimitConfig)
mockConfig maxT initT refill input = do
    inputRef <- newIORef input
    outputRef <- newIORef id
    let !lc = LimitConfig maxT initT refill (clock inputRef) (delay outputRef)
    return $! (outputRef, lc)

  where
    clock ref = do
        x <- atomicModifyIORef' ref upd
        return $! fromNanoSecs x

    upd [] = ([], error "input ran dry")
    upd (x:xs) = (xs, x)

    delay ref ts = do
        let !nanos = toNanoSecs ts
        atomicModifyIORef' ref $ \dl -> (dl . (nanos:), ())

secsToNanos :: Integer -> Integer
secsToNanos = (1000000000 *)

millisToNanos :: Integer -> Integer
millisToNanos = (1000000 *)

nanosToMillis :: Integer -> Integer
nanosToMillis = (`div` 1000000)

microsToNanos :: Integer -> Integer
microsToNanos = (1000 *)

mockEmptyRead :: TestTree
mockEmptyRead = testCase "time not consulted unless bucket runs empty" $ do
    (_, cfg) <- mockConfig 3 3 1 [0, 0]
    lm <- newRateLimiter cfg
    let pull = tryDebit cfg lm 1
    pull >>= assertBool "read 1"
    pull >>= assertBool "read 2"
    pull >>= assertBool "read 3"
    pull >>= (assertBool "read 4" . not)
    -- next one should run us out of clock
    expectException pull

mockRateLimit :: TestTree
mockRateLimit = testCase "rate limit respected" $ do
    numYesVotes <- newIORef (0 :: Int)
    (_, cfg) <- mockConfig 1 0 1 inputs
    lm <- newRateLimiter cfg
    replicateM_ (length inputs0) $ trial cfg numYesVotes lm
    y <- readIORef numYesVotes
    assertEqual "should be four debits" 4 y
  where
    trial cfg ref lm = do
        b <- tryDebit cfg lm 1
        when b (modifyIORef' ref (+1))
    inputs0 = map millisToNanos [0, 200 .. 4500 ]
    inputs = (0 : inputs0) ++ repeat (millisToNanos 4500)

mockLongerRateLimit :: TestTree
mockLongerRateLimit = testCase "higher rate limit" $ do
    numYesVotes <- newIORef (0 :: Int)
    (_, cfg) <- mockConfig 100 0 250 inputs
    lm <- newRateLimiter cfg
    replicateM_ (length inputs0) $ trial cfg numYesVotes lm
    y <- readIORef numYesVotes
    assertEqual "should be 1125 debits" 1125 y
  where
    trial cfg ref lm = do
        b <- tryDebit cfg lm 1
        when b (modifyIORef' ref (+1))
    inputs0 = map millisToNanos [0, 2 .. 4500 ]
    inputs = (0 : inputs0) ++ repeat (millisToNanos 4500)



mockDelay :: TestTree
mockDelay = testCase "test that delay works" $ do
    (out, cfg) <- mockConfig 1 0 1 inputs
    lm <- newRateLimiter cfg
    let wait = waitDebit cfg lm 1

    wait
    wait
    wait
    expectException wait

    l <- ($ []) <$> readIORef out
    assertEqual "outputs" expected $ map nanosToMillis l
  where
    inputs = 0 : inputs0
    inputs0 = map millisToNanos [0, 1000, 1500, 2000, 2000, 3000, 3000]

    expected = [1000, 500, 1000, 1000]

mockPenalize :: TestTree
mockPenalize = testCase "penalize" $ do
    numYesVotes <- newIORef (0 :: Int)
    (_, cfg) <- mockConfig 100 0 250 inputs
    lm <- newRateLimiter cfg
    replicateM_ (length inputs0) $ trial cfg numYesVotes lm
    y <- readIORef numYesVotes
    assertEqual "should be 563 debits" 563 y
  where
    trial cfg ref lm = do
        b <- tryDebit cfg lm 1
        when b $ do
            modifyIORef' ref (+1)
            void $ penalize lm 1
    inputs0 = map millisToNanos [0, 2 .. 4500 ]
    inputs = (0 : inputs0) ++ repeat (millisToNanos 4500)


expectException :: IO a -> IO ()
expectException m = do
    b <- handle h (void m >> return True)
    when b $ fail "expected exception"
  where
    h (_ :: SomeException) = return False


