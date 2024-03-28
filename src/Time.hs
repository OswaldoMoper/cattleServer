{-# LANGUAGE DeriveGeneric #-}

module Time where

-- import           Config
import           Data.Aeson
import           Data.List.Extra          (breakOn, dropEnd, replace)
import           Data.Time.Clock
import           Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import           GHC.Generics             (Generic)
import           System.Directory         (doesDirectoryExist, doesFileExist)
import           System.IO
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

halfHour :: Int
halfHour = 1800000000

logFile :: String
logFile = "/cattleServer.log"

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

mkDateDir :: String -> String -> UTCTime -> IO String
mkDateDir localPath backupApp utc = do
  let (timeText, _)  = breakOn ":" (replace "T" "/T" (iso8601Show utc))
      backupDir      = backupApp <> "/" <> (replace "-" "/" timeText)
      (dir, dirTail) = breakOn "/" backupDir
  _ <- recursiveDirectoryExist localPath dir ( drop 1 dirTail )
  return (dir <> dirTail)

-- TODO: Add function to delete unused directories
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
