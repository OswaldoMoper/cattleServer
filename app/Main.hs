module Main where

import           Config
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

-- TODO: Add function getByJSONFile to get the static inputs
logFile :: String
logFile = "/cattleServer.log"

nominalHour :: NominalDiffTime
nominalHour = secondsToNominalDiffTime 3600

halfHour :: Int
halfHour = 1800000000

main :: IO ()
main = do
  cattleServerDir <- doesDirectoryExist "./../cattleServer-Logs/"
  case cattleServerDir of
    True  -> return ()
    False -> callCommand $ "mkdir ./../cattleServer-Logs/"
  writeLog "./../cattleServer-Logs/cattleServer.log" "Started" "The cattleServer service has been started correctly"
  recursiveBackup False
  -- writeLog "Starting" "The service cattleServer has been started successfully"
  -- recursiveBackup False

-- | Calculate the difference in hours between two UTCTime values.
hoursDiff :: UTCTime -> UTCTime -> Int
hoursDiff t t' = round (diffUTCTime t t' / nominalHour)

-- TODO: Add function to delete unused directories
recursiveDirectoryExist :: String -> String -> String -> IO ()
recursiveDirectoryExist localPath directory "" = do
  dirExistance <- doesDirectoryExist (localPath <> "/" <> directory)
  case dirExistance of
    False -> do
      callCommand $ "mkdir " <> localPath <> "/" <> directory
      -- writeLog "Success" (directory <> " created successfully")
    True -> return ()
recursiveDirectoryExist localPath directory tailS = do
  recursiveDirectoryExist localPath directory ""
  recursiveDirectoryExist localPath ( directory <> "/" <> takeWhile (/= '/') tailS ) (drop 1 $ dropWhile (/= '/') tailS)

mkDateDir :: String -> String -> UTCTime -> IO String
mkDateDir localPath backupApp utc = do
  let (timeText, _)  = breakOn ":" (replace "T" "/T" (iso8601Show utc))
      backupDir      = backupApp <> "/" <> (replace "-" "/" timeText)
      (dir, dirTail) = breakOn "/" backupDir
  recursiveDirectoryExist localPath dir ( drop 1 dirTail )
  return (dir <> dirTail)

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
      return (addUTCTime (-nominalDay) current)

searchLastBackup :: [String] -> String -> Maybe UTCTime
searchLastBackup [] _ = Nothing
searchLastBackup (line:lineS) appName = do
  let message = "{ Message: Success, Description: The service cattleServer has successfully backed up " <> appName <> " }"
  case compare message (dropWhile ( /= '{' ) line) of
    EQ -> do
      let timetext = takeWhile ( /= '{' ) line
      iso8601ParseM (dropEnd 2 timetext)
    _       -> searchLastBackup lineS appName

recursiveBackup :: Bool -> IO ()
recursiveBackup False = do
  threadDelay (halfHour)
  recursiveBackup True
recursiveBackup True = do
  m_app <- readJSONconfig
  case m_app of
    Nothing   -> do
      writeLog ("./../cattleServer-Logs" <> logFile) "Config error" "The cattleServer service hasn't been configurated correctly"
      recursiveBackup False
    Just apps -> do
      recursiveSaveAppBackup apps
      recursiveBackup False

-- TODO: Add function to delete deprecated backups (10 days ago)
saveAppBackup :: App -> IO ()
saveAppBackup app = do
  current <- getCurrentTime
  let localPath = userHome (localHost (serviceConfig app))
      nameApp   = name (appConfig app)
  doBackup <- do
    lastBackup <- getLastBackup (localPath <> "/cattleServer-Logs") nameApp
    return $ (hoursDiff current lastBackup) > 8
  case doBackup of
    True  -> do
      recursiveDirectoryExist localPath "/backup" nameApp
      saveBackup current (appConfig app) (serviceConfig app)
    False -> return ()

recursiveSaveAppBackup :: [App] -> IO ()
recursiveSaveAppBackup []     = return ()
recursiveSaveAppBackup (app:apps) = do
  saveAppBackup app
  recursiveSaveAppBackup apps

-- | Login to the server via SSH, backs up the database and downloads the full backup locally via SCP.
-- Write to the log file during the process.
saveBackup :: UTCTime -> Route -> Config -> IO ()
saveBackup utc app config = do
  let appName     = name app
      sqlFile     = structure (backupDatabase config) <> ".sql"
      localPath   = userHome (localHost config)
      remotePath  = userHome (remoteHost config)
      remoteDir   = hostName (remoteHost config)
      logFilePath = localPath <> "/cattleServer-Logs/" <> appName  <> ".log"
  writeLog ("./../cattleServer-Logs" <> logFile) "Backup in process" ("The cattleServer service is backing up " <> appName)
  loginResponse <- runSimpleSSH (loginToServer (remoteHost config) (portNumber config) (knownHosts config) (keyDirectory config))
  case loginResponse of
    Left err      -> do
      writeLog logFilePath "Error" ("Fail to " <> show err)
    Right session -> do
      writeLog logFilePath "Success" "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session (backupDatabase config) (remoteHost config)
      case commandResponse of
        Left err     -> do
          writeLog logFilePath "Error" (show err)
        Right result -> do
          case resultExit result of
            SSH.ExitSuccess -> writeLog logFilePath "Success" (sqlFile <> " created successfully")
            _           -> writeLog logFilePath "Error" (show (resultErr result))
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              writeLog logFilePath "Error" (show err)
            Right () -> do
              writeLog logFilePath "Success" "SSH connection closed"
              backupDir <- mkDateDir localPath ("backup/" <> appName ) utc
              let dir = localPath <> "/" <> backupDir
              (sqlExit', _, sqlErr') <- databaseBackupLocally (remotePath <> "/backup/" <> sqlFile ) (dir <> "/" <> sqlFile) remoteDir (keyDirectory config)
              case sqlExit' of
                E.ExitSuccess -> writeLog logFilePath "Success" (sqlFile <> " downloaded successfully")
                _             -> writeLog logFilePath "Error" sqlErr'
              (uploadExit', _, uploadErr') <- databaseBackupLocally (structure app) (dir <> "/upload") remoteDir (keyDirectory config)
              case uploadExit' of
                E.ExitSuccess -> do
                  writeLog logFilePath "Success" ("Uploads directory downloaded successfully")
                  writeLog ("./../cattleServer-Logs" <> logFile) "Success" ("The service cattleServer has successfully backed up " <> appName)
                _             -> writeLog logFilePath "Error" uploadErr'

loginToServer :: Host -> Integer -> String -> Route -> SimpleSSH Session
loginToServer remote port knownHost keys = do
  session <- openSession (hostName remote) port knownHost
  let privateKey = (structure keys <> "/" <> name keys)
      publicKey = (privateKey <> ".pub")
  auth_session <- authenticateWithKey session (userName remote) publicKey privateKey ""
  return auth_session

databaseBackupInServer :: Session -> Route -> Host -> SimpleSSH Result
databaseBackupInServer session database remote = do
  let dbName     = name database
      dbStruct   = structure database
      remoteHome = userHome remote
  response <- execCommand session $ "pg_dump -U " <> dbName <> " " <> dbStruct <> " > " <> remoteHome <> "/backup/" <> dbStruct <> ".sql"
  return response

databaseBackupLocally :: String -> String -> String -> Route -> IO (ExitCode, String, String)
databaseBackupLocally remotePath localPath remoteDir keys = do
  let privateKey = (structure keys <> "/" <> name keys)
  readProcessWithExitCode "/run/current-system/sw/bin/scp" [ "-i", privateKey, "-r", ("<remote-user>@" <> remoteDir <> ":" <> remotePath), localPath] []

-- | Write a message to the log file.
writeLog :: String -> String -> String -> IO ()
writeLog logFilePath message description = do
  logs <- openFile logFilePath AppendMode
  utcTime <- getCurrentTime
  hPutStr logs (iso8601Show utcTime <> ": { Message: " <> message <> ", Description: " <> description <> " }\n")
  hClose logs
