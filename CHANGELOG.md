# Revision history for token-limiter

## 0.2.0.3 -- 2019-Nov-04

Move tests requiring a quiet machine to their own executable. If the executable
is starved then we may not pull as many tokens as we expected, even though we
would have had the rate limit to do so.

## 0.2.0.2 -- 2019-Nov-04

Don't use coarse monotonic clock in test suite, either.

## 0.2.0.1 -- 2019-Nov-03

Don't use coarse monotonic clock by default.

## 0.2.0.0 -- 2019-Nov-01

Add `penalize`.

## 0.1.0.0 -- 2019-Apr-04

First version.
