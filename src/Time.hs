{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Time where

-- import           Config
import           Control.Exception        (IOException, bracket, try)
import           Control.Monad            (filterM)
import           Data.Aeson
import           Data.Char                (isDigit)
import           Data.List.Extra          (dropEnd, sortOn)
import           Data.Maybe               (catMaybes)
import           Data.Time.Clock
import           Data.Time.Format         (defaultTimeLocale, formatTime,
                                           parseTimeM)
import           Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import           GHC.Generics             (Generic)
import           System.Directory         (createDirectoryIfMissing,
                                           doesDirectoryExist, doesFileExist,
                                           listDirectory, removeDirectory,
                                           renameDirectory)
import           System.Environment       (lookupEnv)
import           System.FilePath          (dropTrailingPathSeparator,
                                           takeFileName)
import           System.IO
import           System.Posix.Files       (createSymbolicLink,
                                           getSymbolicLinkStatus, isDirectory,
                                           isSymbolicLink, removeLink)

data UnitTime = UnitTime
  { unit  :: String
  , times :: Int
  } deriving (Generic, Show, Read)

instance FromJSON UnitTime
instance ToJSON UnitTime

nominalHour :: NominalDiffTime
nominalHour = secondsToNominalDiffTime 3600

nominalWeek :: NominalDiffTime
nominalWeek = nominalDay*7

nominalMonth :: NominalDiffTime
nominalMonth = nominalDay*30

-- | Minutes as the microseconds 'Control.Concurrent.threadDelay' wants.
minutesToMicros :: Int -> Int
minutesToMicros minutes = minutes * 60 * 1000000

-- | How deep a backup sat under an application's directory in the layout this
-- replaced: @YYYY\/MM\/DD\/THH@. Kept because finding those is what the
-- migration needs.
nestedBackupDepth :: Int
nestedBackupDepth = 4

-- | Directory name for a backup taken at a given time.
--
-- A truncated ISO 8601 timestamp. Every field is fixed width and zero padded,
-- so sorting the names sorts them by date, and there is no character that
-- needs quoting in a shell word or an rsync argument.
--
-- The hour is the finest grain 'backupFrequency' offers, so two backups can
-- never contend for one name -- and a retry within the same hour repairs the
-- directory it failed in rather than leaving a half written one behind.
backupDirFormat :: String
backupDirFormat = "%Y-%m-%dT%H"

backupDirName :: UTCTime -> String
backupDirName = formatTime defaultTimeLocale backupDirFormat

-- | The time a directory name stands for, if it is one of ours.
--
-- Total, where the nested layout's 'takeTailInt' was a partial 'read': a name
-- that is not a backup -- @latest@, a leftover, anything else -- is 'Nothing'
-- rather than an exception that takes the daemon down.
parseBackupDirName :: String -> Maybe UTCTime
parseBackupDirName = parseTimeM False defaultTimeLocale backupDirFormat

-- | Every backup under an application's directory, oldest first.
--
-- Only real directories whose name parses as a time count, so symlinks and
-- anything unrecognised are skipped rather than mistaken for a backup.
listBackups :: FilePath -> IO [(UTCTime, FilePath)]
listBackups root = do
  exists <- doesDirectoryExist root
  case exists of
    False -> return []
    True  -> do
      entries <- listDirectory root
      let dated = [ (t, e) | e <- entries, Just t <- [parseBackupDirName e] ]
      real <- filterM (\(_, e) -> isRealDirectory (root <> "/" <> e)) dated
      return (sortOn fst [ (t, root <> "/" <> e) | (t, e) <- real ])

-- | Create the directory a backup taken at this time belongs in.
mkBackupDir :: FilePath -> String -> UTCTime -> IO FilePath
mkBackupDir localPath appName utc = do
  let dir = localPath <> "/backup/" <> appName <> "/" <> backupDirName utc
  createDirectoryIfMissing True dir
  return dir

-- | The backups whose files a new one may be hardlinked against.
--
-- The two newest that are not the one being written -- two rather than one so
-- that a backup interrupted halfway, which leaves a directory that is real
-- but incomplete, does not force the next one to copy everything again.
linkDestinations :: FilePath -> FilePath -> IO [FilePath]
linkDestinations appRoot current = do
  existing <- listBackups appRoot
  return (take 2 [ p | (_, p) <- reverse existing, p /= current ])

-- | The nested layout's name for a backup, relative to the application root.
parseNestedBackupName :: String -> Maybe UTCTime
parseNestedBackupName = parseTimeM False defaultTimeLocale "%Y/%m/%d/T%H"

-- | Directories under an application root whose name could be a year.
--
-- This is what keeps the migration cheap once it is done: nothing else is
-- descended into, so the steady state costs one listing and stops.
yearDirectories :: FilePath -> IO [FilePath]
yearDirectories appRoot = do
  exists <- doesDirectoryExist appRoot
  case exists of
    False -> return []
    True  -> do
      entries <- listDirectory appRoot
      filterM isRealDirectory
        [ appRoot <> "/" <> e | e <- entries, length e == 4, all isDigit e ]

-- | Backups still in the layout this replaced, oldest first.
nestedBackups :: FilePath -> IO [(UTCTime, FilePath)]
nestedBackups appRoot = do
  years <- yearDirectories appRoot
  found <- concat <$> mapM (dirsAtDepth (nestedBackupDepth - 1)) years
  let prefixLen = length appRoot + 1
  return (sortOn fst
    [ (t, p) | p <- found, Just t <- [parseNestedBackupName (drop prefixLen p)] ])

-- | Rename every backup still in the nested layout to a flat dated name.
--
-- Idempotent, so it can run on every pass and needs no marker to say it has
-- finished: once nothing is nested there is nothing left to do. Every rename
-- stays inside the application root, so it is within one filesystem and
-- atomic, and an interruption leaves a mixture that the next pass completes.
migrateNestedBackups :: FilePath -> IO [(FilePath, FilePath)]
migrateNestedBackups appRoot = do
  nested <- nestedBackups appRoot
  moved  <- mapM renameOne nested
  pruneEmptyParents appRoot
  return (catMaybes moved)
  where
    renameOne (t, from) = do
      let to = appRoot <> "/" <> backupDirName t
      clash <- doesDirectoryExist to
      case clash of
        True  -> return Nothing
        False -> do
          attempt <- try (renameDirectory from to)
          return $ case attempt of
            Right ()                -> Just (from, to)
            Left (_ :: IOException) -> Nothing

-- | Remove the year, month and day directories the migration emptied.
--
-- 'removeDirectory' refuses a directory that still holds anything, so a
-- rename that failed can never have its data pulled out from under it.
pruneEmptyParents :: FilePath -> IO ()
pruneEmptyParents appRoot = do
  years  <- yearDirectories appRoot
  months <- concat <$> mapM (dirsAtDepth 1) years
  days   <- concat <$> mapM (dirsAtDepth 1) months
  mapM_ removeIfEmpty days
  mapM_ removeIfEmpty months
  mapM_ removeIfEmpty years

removeIfEmpty :: FilePath -> IO ()
removeIfEmpty dir = do
  attempt <- try (removeDirectory dir)
  return $ case attempt of
    Right ()                -> ()
    Left (_ :: IOException) -> ()

-- | Name of the link that always points at the newest backup.
latestLinkName :: String
latestLinkName = "latest"

-- | Local name for the copy of the remote uploads directory.
--
-- The basename of whatever the configuration points at, so @\/loads@ arrives
-- as @loads@ rather than under a name compiled into the program. Falls back
-- to what that name used to be unconditionally, for a path with no basename
-- of its own.
uploadDirName :: FilePath -> String
uploadDirName remotePath =
  case takeFileName (dropTrailingPathSeparator remotePath) of
    "" -> "upload"
    n  -> n

-- | Real directories exactly @depth@ levels below @root@.
--
-- Symlinks do not count and are not followed, so the @latest@ link is neither
-- mistaken for a backup of its own nor used to reach one twice.
dirsAtDepth :: Int -> FilePath -> IO [FilePath]
dirsAtDepth depth root
  | depth <= 0 = return [root]
  | otherwise  = do
      exists <- doesDirectoryExist root
      case exists of
        False -> return []
        True  -> do
          entries  <- listDirectory root
          children <- filterM isRealDirectory (map ((root <> "/") <>) entries)
          concat <$> mapM (dirsAtDepth (depth - 1)) children

-- | Whether the path is a directory in its own right, rather than a symlink
-- pointing at one.
isRealDirectory :: FilePath -> IO Bool
isRealDirectory path = do
  attempt <- try (getSymbolicLinkStatus path)
  return $ case attempt of
    Right status            -> isDirectory status
    Left (_ :: IOException) -> False

-- | Point @latest@ at a backup, replacing whatever it pointed at before.
--
-- Gives a path that does not change between backups, while the directory it
-- resolves to still carries the date. Refuses to touch anything that is not
-- already a symlink, so a directory of that name is never destroyed.
--
-- The link is /relative/: the target is always a sibling, so naming it by its
-- own name and nothing more lets the whole tree be copied, moved or mounted
-- somewhere else without the link going stale. An absolute one would still
-- name the path it was written on.
linkLatest :: FilePath -> FilePath -> IO (Either String ())
linkLatest root target = do
  let link     = root <> "/" <> latestLinkName
      sibling  = takeFileName (dropTrailingPathSeparator target)
  replaceable <- isExistingSymlink link
  attempt <- try $ do
    case replaceable of
      True  -> removeLink link
      False -> return ()
    createSymbolicLink sibling link
  return $ case attempt of
    Right ()                -> Right ()
    Left (e :: IOException) -> Left (show e)

-- | Whether the path is a symlink, and so ours to replace.
isExistingSymlink :: FilePath -> IO Bool
isExistingSymlink path = do
  attempt <- try (getSymbolicLinkStatus path)
  return $ case attempt of
    Right status            -> isSymbolicLink status
    Left (_ :: IOException) -> False

logFile :: String
logFile = "/cattleServer.log"

-- | Name of the directory holding the service and per-application logs.
defaultLogDirName :: String
defaultLogDirName = "cattleServer-Logs"

-- | Path of the service-wide log file inside a log directory.
serviceLogPath :: FilePath -> FilePath
serviceLogPath dir = dir <> logFile

-- | Path of an application's log file inside a log directory.
appLogPath :: FilePath -> String -> FilePath
appLogPath dir appName = dir <> "/" <> appName <> ".log"

-- | Create the log directory if it is missing.
-- Returns whether it already existed, which is what decides the wording of
-- the startup message.
ensureLogDir :: FilePath -> IO Bool
ensureLogDir dir = do
  existed <- doesDirectoryExist dir
  createDirectoryIfMissing True dir
  return existed

-- | Calculate the difference in hours between two UTCTime values.
hoursDiff :: UTCTime -> UTCTime -> Int
hoursDiff t t' = round (diffUTCTime t t' / nominalHour)

-- | Calculate the difference in days between two UTCTime values.
daysDiff :: UTCTime -> UTCTime -> Int
daysDiff t t' = round (diffUTCTime t t' / nominalDay)

-- | Calculate the difference in weeks between two UTCTime values.
weeksDiff :: UTCTime -> UTCTime -> Int
weeksDiff t t' = round (diffUTCTime t t' / nominalWeek)

-- | Calculate the difference in months between two UTCTime values.
monthsDiff :: UTCTime -> UTCTime -> Int
monthsDiff t t' = round (diffUTCTime t t' / nominalMonth)

-- | Add UTCTime in units of time
subsNominalTime :: Int -> String -> UTCTime -> UTCTime
subsNominalTime factor u utc =
  case u of
    "Hours"  -> addUTCTime (multiply nominalHour  (-factor)) utc
    "Days"   -> addUTCTime (multiply nominalDay   (-factor)) utc
    "Weeks"  -> addUTCTime (multiply nominalWeek  (-factor)) utc
    "Months" -> addUTCTime (multiply nominalMonth (-factor)) utc
    _        -> addUTCTime (multiply nominalDay   (-10))     utc

multiply :: NominalDiffTime -> Int -> NominalDiffTime
multiply time factor = fromRational (toRational time * toRational factor)

getLastBackup :: String -> String -> IO UTCTime
getLastBackup localPath appName = do
  fileExistance <- doesFileExist (localPath <> logFile)
  m_time <- case fileExistance of
    False -> return Nothing
    True  -> do
      content <- readFile (localPath <> logFile)
      return $ (searchLastBackup . reverse . lines) content appName
  case m_time of
    Just t  -> return t
    Nothing -> do
      current <- getCurrentTime
      return (addUTCTime (-24*nominalMonth) current)

searchLastBackup :: [String] -> String -> Maybe UTCTime
searchLastBackup [] _ = Nothing
searchLastBackup (line:lineS) appName = do
  let message = "{ Message: Success, Description: The service cattleServer has successfully backed up " <> appName <> " }"
  case compare message (dropWhile ( /= '{' ) line) of
    EQ -> do
      let timetext = takeWhile ( /= '{' ) line
      iso8601ParseM (dropEnd 2 timetext)
    _       -> searchLastBackup lineS appName

-- | Write a message to the log file, and to standard output for the journal.
--
-- Both, not one or the other. The file is not only a log: 'getLastBackup'
-- reads its own success markers back out of it to decide when the next backup
-- is due, so the shape of those lines is load-bearing and the journal's
-- priority prefix goes on the copy systemd reads, never on the copy the
-- service reads.
writeLog :: String -> String -> String -> IO ()
writeLog logFilePath message description = do
  utcTime <- getCurrentTime
  let line = iso8601Show utcTime <> ": { Message: " <> message
               <> ", Description: " <> description <> " }"
  bracket (openFile logFilePath AppendMode) hClose $ \logs -> do
    hSetEncoding logs utf8
    hPutStrLn logs line
  prefix <- journalPrefix message
  putStrLn (prefix <> message <> ": " <> description)

-- | The @\<N\>@ that systemd reads as a syslog priority and strips, so that
-- entries reach the journal at their real level instead of all being "info".
--
-- Nothing else understands it, so it is only added when systemd says it owns
-- the stream. Running the service by hand prints plain lines.
journalPrefix :: String -> IO String
journalPrefix message = do
  m_stream <- lookupEnv "JOURNAL_STREAM"
  return $ case m_stream of
    Nothing -> ""
    Just _  -> "<" <> show (syslogPriority message) <> ">"

-- | Syslog priority for a message tag: 3 err, 4 warning, 5 notice, 6 info.
--
-- An unrecognised tag is info rather than nothing, so a tag added later is
-- visible instead of being swallowed.
syslogPriority :: String -> Int
syslogPriority message
  | message `elem` errors   = 3
  | message `elem` warnings = 4
  | message `elem` notices  = 5
  | otherwise               = 6
  where
    errors   = [ "Error", "Config error", "Session Error", "Session Auth Error"
               , "Known host error", "Known host mismatch" ]
    warnings = [ "Skipped" ]
    notices  = [ "Started", "Known host added" ]
