module Main where

import           Control.Concurrent           (threadDelay)
import           Data.List.Extra              (breakOn, dropEnd, replace)
import           Data.Time.Clock
import           Data.Time.Format.ISO8601     (iso8601ParseM, iso8601Show)
import           Network.SSH.Client.SimpleSSH as SSH
import           System.Directory             (doesDirectoryExist,
                                               doesFileExist)
import           System.Exit                  as E
import           System.IO
import           System.Process

path :: String
path = "/home/<remote-user>"

localPath :: String
localPath = "/home/<user>/backup"

sqlBackup :: String
sqlBackup = "/backup/yesod-project.sql"

host :: String
host = "0.0.0.0"

logFile :: String
logFile = "/cattleServer.log"

nominalHour :: NominalDiffTime
nominalHour = secondsToNominalDiffTime 3600

halfHour :: Int
halfHour = 1800000000

main :: IO ()
main = recursiveBackup False

-- | Calculate the difference in hours between two UTCTime values.
hoursDiff :: UTCTime -> UTCTime -> Int
hoursDiff t t' = round (diffUTCTime t t' / nominalHour)

recursiveDirectoryExist :: String -> String -> IO ()
recursiveDirectoryExist directory "" = do
  dirExistance <- doesDirectoryExist (localPath <> "/" <> directory)
  case dirExistance of
    False -> do
      callCommand $ "mkdir " <> localPath <> "/" <> directory
      writeLog "Success" (directory <> " created successfully")
    True -> return ()
recursiveDirectoryExist directory tailS = do
  recursiveDirectoryExist directory ""
  recursiveDirectoryExist ( directory <> "/" <> takeWhile (/= '/') tailS ) (drop 1 $ dropWhile (/= '/') tailS)

mkDateDir :: UTCTime -> IO String
mkDateDir utc = do
  let (timeText, _) = breakOn ":" (replace "T" "/T" (iso8601Show utc))
      (dir, dirTail) = breakOn "/" (replace "-" "/" timeText)
  recursiveDirectoryExist dir ( drop 1 dirTail )
  return (dir <> dirTail)

getLastBackup :: IO UTCTime
getLastBackup = do
  fileExistance <- doesFileExist (localPath <> logFile)
  m_time <- case fileExistance of
    False -> return Nothing
    True  -> do
      content <- readFile (localPath <> logFile)
      return $ (searchLastBackup . reverse . lines) content
  case m_time of
    Just t  -> return t
    Nothing -> do
      current <- getCurrentTime
      return (addUTCTime (-nominalDay) current)

searchLastBackup :: [String] -> Maybe UTCTime
searchLastBackup [] = Nothing
searchLastBackup (line:lineS) = do
  case dropWhile ( /= '{' ) line of
    "{ Message: Success, Description: /upload downloaded successfully }" -> do
      let timetext = takeWhile ( /= '{' ) line
      iso8601ParseM (dropEnd 2 timetext)
    _                                                                    -> searchLastBackup lineS

recursiveBackup :: Bool -> IO ()
recursiveBackup True = do
  current <- getCurrentTime
  saveBackup current
  recursiveBackup False
recursiveBackup False = do
  threadDelay (halfHour)
  doBackup <- do
    lastBackup <- getLastBackup
    current <- getCurrentTime
    return $ (hoursDiff current lastBackup) > 8
  recursiveBackup doBackup

-- | Login to the server via SSH, backs up the database and downloads the full backup locally via SCP.
-- Write to the log file during the process.
saveBackup :: UTCTime -> IO ()
saveBackup utc = do
  loginResponse <- runSimpleSSH loginToServer
  case loginResponse of
    Left err      -> do
      writeLog "Error" ("Fail to " <> show err)
    Right session -> do
      writeLog "Success" "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session
      case commandResponse of
        Left err     -> do
          writeLog "Error" (show err)
        Right result -> do
          case resultExit result of
            SSH.ExitSuccess -> writeLog "Success" "yesod-project.sql created successfully"
            _           -> writeLog "Error" (show (resultErr result))
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              writeLog "Error" (show err)
            Right () -> do
              writeLog "Success" "SSH connection closed"
              dateDir <- mkDateDir utc
              let dir = localPath <> "/" <> dateDir
              (sqlExit', _, sqlErr') <- readProcessWithExitCode "scp" ["-r", ("<remote-user>@" <> host <> ":" <> path <> sqlBackup), dir] []
              case sqlExit' of
                E.ExitSuccess -> writeLog "Success" "yesod-project.sql downloaded successfully"
                _             -> writeLog "Error" sqlErr'
              (uploadExit', _, uploadErr') <- readProcessWithExitCode "scp" ["-r", ("<remote-user>@" <> host <> ":" <> "/upload"), (dir <> "/upload")] []
              case uploadExit' of
                E.ExitSuccess -> writeLog "Success" "/upload downloaded successfully"
                _             -> writeLog "Error" uploadErr'

loginToServer :: SimpleSSH Session
loginToServer = do
  session <- openSession host 22 "/home/<user>/.ssh/known_hosts"
  auth_session <- authenticateWithKey session "<remote-user>" "/home/<user>/.ssh/exampleKey-ed25519.pub" "/home/<user>/.ssh/exampleKey-ed25519" ""
  return auth_session

databaseBackupInServer :: Session -> SimpleSSH Result
databaseBackupInServer session = do
  response <- execCommand session $ "pg_dump -U postgres yesod-project > " <> path <> sqlBackup
  return response

-- | Write a message to the log file.
writeLog :: String -> String -> IO ()
writeLog message description = do
  logs <- openFile (localPath <> logFile) AppendMode
  utcTime <- getCurrentTime
  hPutStr logs (iso8601Show utcTime <> ": { Message: " <> message <> ", Description: " <> description <> " }\n")
  hClose logs
