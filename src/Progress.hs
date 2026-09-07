{-# LANGUAGE ScopedTypeVariables #-}

-- | Reading rsync's progress output, and rationing what gets said about it.
module Progress
  ( Progress (..)
  , parseProgress
  , progressWorthReporting
  , renderRunning
  , renderFinished
  , statsWorthKeeping
  , throttled
  ) where

import           Data.Char      (isDigit, isSpace)
import           Data.IORef     (newIORef, readIORef, writeIORef)
import           Data.List      (isInfixOf, isPrefixOf)
import           Data.Time.Clock(NominalDiffTime, diffUTCTime, getCurrentTime)
import           Text.Read      (readMaybe)

-- | One @--info=progress2@ update.
--
-- rsync writes these separated by carriage returns, in the shape
--
-- >             2000000   2%  625.37MB/s    0:00:00 (xfr#1, to-chk=43/45)
--
-- where the fourth column is the time rsync expects to still need, not the
-- time it has taken -- elapsed is ours to measure. The very first update
-- carries no file counts, and is not treated as progress.
data Progress = Progress
  { progBytes     :: Integer
  , progPercent   :: Int
  , progRate      :: String
  , progEta       :: String
  , progFilesLeft :: Int
  , progFilesAll  :: Int
  } deriving (Eq, Show)

parseProgress :: String -> Maybe Progress
parseProgress record =
  case words (map unpunctuate record) of
    (bytes : percent : rate : eta : _) | "%" `isSuffix` percent -> do
      b            <- readDigits bytes
      p            <- readDigits (init percent)
      (left, allF) <- checkCounts record
      return Progress { progBytes     = b
                      , progPercent   = fromInteger p
                      , progRate      = rate
                      , progEta       = eta
                      , progFilesLeft = left
                      , progFilesAll  = allF
                      }
    _ -> Nothing
  where
    unpunctuate c = if c `elem` ("()," :: String) then ' ' else c
    isSuffix suffix s = suffix `isInfixOf` s && drop (length s - length suffix) s == suffix

-- | The @to-chk=43\/45@ tail: files left, files in total.
--
-- Also accepts @ir-chk=@, which is what rsync writes when it is still
-- building the file list, so a caller that forgets @--no-inc-recursive@ gets
-- counts that grow rather than no counts at all.
checkCounts :: String -> Maybe (Int, Int)
checkCounts record =
  case dropWhile (not . ("chk=" `isPrefixOf`)) (tails' record) of
    []       -> Nothing
    (rest:_) ->
      let after        = drop 4 rest
          (leftS, sep) = span isDigit after
      in case sep of
           ('/':allS) -> (,) <$> readInt leftS <*> readInt (takeWhile isDigit allS)
           _          -> Nothing
  where
    tails' []       = [[]]
    tails' s@(_:xs) = s : tails' xs
    readInt s = readMaybe s :: Maybe Int

-- | Whether an update is worth a line while the transfer is still running.
--
-- Bounded at both ends. The total is inferred from the percentage, so at zero
-- there is nothing to infer it from and the line would read "0.0 MB of ~0.0 MB
-- (0%)"; rsync always opens with one of those. And at a hundred there is no
-- progress left to describe and no time left to estimate, so the closing line
-- is the one that should speak -- rsync repeats that last update several times
-- over, which would otherwise be several identical lines claiming there is
-- still time remaining.
--
-- Note that no update says whether it is the last one. @to-chk=0/1@ holds for
-- the whole of a single file transfer -- which every database dump is -- so a
-- record that looks finished may be at 20%. Which update was last is knowable
-- only once the stream has ended, so that is where 'renderFinished' belongs.
progressWorthReporting :: Progress -> Bool
progressWorthReporting p = progPercent p > 0 && progPercent p < 100

-- | rsync reports how far it has got and what fraction that is, never the
-- total, so the total is inferred -- hence the tilde when it is rendered.
estimatedTotal :: Progress -> Integer
estimatedTotal p
  | progPercent p <= 0 = progBytes p
  | otherwise          = progBytes p * 100 `div` toInteger (progPercent p)

-- | An update from the middle of a transfer: how far along, and how much
-- longer.
renderRunning :: NominalDiffTime -> Progress -> String
renderRunning elapsed p = concat
  [ showMB (progBytes p), " MB of ~", showMB (estimatedTotal p), " MB"
  , " (", show (progPercent p), "%), "
  , show (progFilesAll p - progFilesLeft p), " of ", show (progFilesAll p), " files, "
  , progRate p, ", ", showDuration elapsed, " elapsed"
  , ", ", progEta p, " left"
  ]

-- | The update that turned out to be the last one, which is a different
-- statement rather than the same one at 100%.
--
-- Nothing is inferred here: the total has arrived, so there is no tilde to
-- put on it and no percentage left to state, and an estimate of the time
-- remaining would be an estimate of zero.
--
-- A transfer against a previous backup can find that nothing needs sending at
-- all. That is the incremental copy working perfectly, so it is said in those
-- words rather than as "0.0 MB at 0.00kB/s", which reads like a failure.
renderFinished :: NominalDiffTime -> Progress -> String
renderFinished elapsed p = concat
  [ plural (progFilesAll p) "file", " checked, "
  , case progBytes p of
      0 -> "nothing needed transferring"
      b -> showMB b <> " MB transferred at " <> progRate p
  , ", ", showDuration elapsed, " elapsed"
  ]

plural :: Int -> String -> String
plural n word = show n <> " " <> word <> suffix
  where
    suffix = case n == 1 of
      True  -> ""
      False -> "s"

showMB :: Integer -> String
showMB bytes =
  let tenths = bytes * 10 `div` (1024 * 1024)
      (whole, tenth) = tenths `divMod` 10
  in show whole <> "." <> show tenth

showDuration :: NominalDiffTime -> String
showDuration d =
  let total     = max 0 (round d) :: Integer
      (hrs, r)  = total `divMod` 3600
      (mins, s) = r `divMod` 60
  in case hrs of
       0 -> pad mins <> ":" <> pad s
       _ -> show hrs <> ":" <> pad mins <> ":" <> pad s
  where
    pad n = case n < 10 of
      True  -> "0" <> show n
      False -> show n

-- | The three lines of @--stats@ worth saying out loud, out of the fifteen it
-- prints: what was actually sent, what the tree weighs, and the ratio between
-- them -- which is the number that says whether the incremental copy is
-- working.
statsWorthKeeping :: String -> Bool
statsWorthKeeping line = any (`isInfixOf` line)
  [ "Total transferred file size", "Total file size", "speedup is" ]

-- | Rate-limit an action.
--
-- rsync emits several updates a second, and reporting each would bury
-- everything else in the log. So: one every interval, and the caller reports
-- the closing line itself once the stream has ended, which is the only moment
-- at which it is known to be the closing one.
throttled :: NominalDiffTime -> (a -> IO ()) -> IO (a -> IO ())
throttled interval act = do
  ref <- newIORef Nothing
  return $ \x -> do
    now      <- getCurrentTime
    previous <- readIORef ref
    let due = case previous of
                Nothing -> True
                Just t  -> diffUTCTime now t >= interval
    case due of
      False -> return ()
      True  -> do
        writeIORef ref (Just now)
        act x

readDigits :: String -> Maybe Integer
readDigits s = readMaybe (filter isDigit (dropWhile isSpace s))
