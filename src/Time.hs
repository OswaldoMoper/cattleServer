{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Time where

-- import           Config
import           Control.Exception        (IOException, try)
import           Control.Monad            (filterM)
import           Data.Aeson
import           Data.List.Extra          (breakOn, dropEnd, dropWhileEnd,
                                           replace, takeWhileEnd)
import           Data.Time.Clock
import           Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import           GHC.Generics             (Generic)
import           System.Directory         (createDirectoryIfMissing,
                                           doesDirectoryExist, doesFileExist,
                                           listDirectory)
import           System.IO
import           System.Posix.Files       (createSymbolicLink,
                                           getSymbolicLinkStatus, isDirectory,
                                           isSymbolicLink, removeLink)
import           System.Process

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

-- | How deep one backup sits under an application's directory: @YYYY\/MM\/DD\/THH@.
backupDepth :: Int
backupDepth = 4

-- | Name of the link that always points at the newest backup.
latestLinkName :: String
latestLinkName = "latest"

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
linkLatest :: FilePath -> FilePath -> IO (Either String ())
linkLatest root target = do
  let link = root <> "/" <> latestLinkName
  replaceable <- isExistingSymlink link
  attempt <- try $ do
    case replaceable of
      True  -> removeLink link
      False -> return ()
    createSymbolicLink target link
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

timeToStringDir :: UTCTime -> String
timeToStringDir utc = do
  let (timeText, _)  = breakOn ":" (replace "T" "/T" (iso8601Show utc))
  replace "-" "/" timeText

dropTailDir :: String -> String
dropTailDir = (dropEnd 1) . (dropWhileEnd (/= '/'))

takeTailInt :: String -> Int
takeTailInt = read . (takeWhileEnd (/= '/')) . dropTailDir

recursiveStringDir :: String -> String -> String -> Int -> String
recursiveStringDir current deleteDir "Days" number = do
  let currentDay = takeTailInt current
  case currentDay == number of
    True  -> recursiveStringDir (dropTailDir current) (dropTailDir deleteDir) "Months" 1
    False -> dropTailDir deleteDir
recursiveStringDir current deleteDir "Months" number = do
  let currentMonth = takeTailInt current
  case currentMonth == number of
    True  -> recursiveStringDir (dropTailDir current) (dropTailDir deleteDir) "Years" 1
    False -> dropTailDir deleteDir
recursiveStringDir _ deleteDir _ _ = dropTailDir deleteDir

mkDateDir :: String -> String -> UTCTime -> IO String
mkDateDir localPath backupApp utc = do
  let backupDir      = backupApp <> "/" <> timeToStringDir utc
      (dir, dirTail) = breakOn "/" backupDir
  _ <- recursiveDirectoryExist localPath dir ( drop 1 dirTail )
  return (dir <> dirTail)

recursiveDirectoryExist :: String -> String -> String -> IO Bool
recursiveDirectoryExist localPath directory "" = do
  dirExistance <- doesDirectoryExist (localPath <> "/" <> directory)
  case dirExistance of
    False -> do
      callCommand $ "mkdir " <> localPath <> "/" <> directory
      -- writeLog "Success" (directory <> " created successfully")
      return False
    True -> return True
recursiveDirectoryExist localPath directory tailS = do
  _ <- recursiveDirectoryExist localPath directory ""
  recursiveDirectoryExist localPath ( directory <> "/" <> takeWhile (/= '/') tailS ) (drop 1 $ dropWhile (/= '/') tailS)

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

-- | Write a message to the log file.
writeLog :: String -> String -> String -> IO ()
writeLog logFilePath message description = do
  logs <- openFile logFilePath AppendMode
  utcTime <- getCurrentTime
  hPutStr logs (iso8601Show utcTime <> ": { Message: " <> message <> ", Description: " <> description <> " }\n")
  hClose logs
