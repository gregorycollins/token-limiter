{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main ( main ) where

import Control.Concurrent.TokenLimiter
import Control.Exception
import Control.Monad
import Data.IORef
import System.Clock
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "token-limiter" [
    mockTests
  ]

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

millisToNanos :: Integer -> Integer
millisToNanos = (1000000 *)

nanosToMillis :: Integer -> Integer
nanosToMillis = (`div` 1000000)

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


