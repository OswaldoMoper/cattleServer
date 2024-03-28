module Main where

import           Config
import           Control.Concurrent           (threadDelay)
import           Data.Time.Clock
import           Data.Time.Format.ISO8601     (iso8601Show)
import           Network.SSH.Client.SimpleSSH as SSH
import           System.Exit                  as E
import           System.IO
import           System.Process
import           Time

main :: IO ()
main = do
  cattleServerDir <- recursiveDirectoryExist "./.." "cattleServer-Logs/" ""
  case cattleServerDir of
    True  -> writeLog "./../cattleServer-Logs/cattleServer.log" "Started" "The cattleServer service has been started correctly"
    False -> writeLog "./../cattleServer-Logs/cattleServer.log" "Started" "The cattleServer service log folder has been created"
  recursiveBackup False

recursiveBackup :: Bool -> IO ()
recursiveBackup False = do
  threadDelay (halfHour)
  recursiveBackup True
recursiveBackup True = do
  m_config <- readJSONconfig
  case m_config of
    Nothing   -> do
      writeLog ("./../cattleServer-Logs" <> logFile) "Config error" "The cattleServer service hasn't been configurated correctly"
      recursiveBackup False
    Just software -> do
      recursiveSaveAppBackup (apps software) (knownHosts software) (localHost software)
      recursiveBackup False

-- TODO: Add function to delete deprecated backups (10 days ago)
saveAppBackup :: App -> String -> Host -> IO ()
saveAppBackup app knownHost localHost = do
  current <- getCurrentTime
  let localPath = userHome localHost
      nameApp   = name (appConfig app)
      backupF   = backupFrequency (serviceConfig app)
  doBackup <- do
    _ <- recursiveDirectoryExist localPath "/cattleServer-Logs" ""
    lastBackup <- getLastBackup (localPath <> "/cattleServer-Logs") nameApp
    case unit backupF of
      "Hours"  -> return $ (hoursDiff  current lastBackup) > (times backupF)
      "Days"   -> return $ (daysDiff   current lastBackup) > (times backupF)
      "Weeks"  -> return $ (weeksDiff  current lastBackup) > (times backupF)
      "Months" -> return $ (monthsDiff current lastBackup) > (times backupF)
      _        -> return $ (hoursDiff  current lastBackup) > 8
  case doBackup of
    True  -> do
      _ <- recursiveDirectoryExist localPath "/backup" nameApp
      saveBackup current (appConfig app) (databaseConfig app) (serviceConfig app) knownHost localHost
    False -> return ()

recursiveSaveAppBackup :: [App] -> String -> Host -> IO ()
recursiveSaveAppBackup [] _ _                     = return ()
recursiveSaveAppBackup (app:apps) knownHost localHost = do
  saveAppBackup app knownHost localHost
  recursiveSaveAppBackup apps knownHost localHost

-- | Login to the server via SSH, backs up the database and downloads the full backup locally via SCP.
-- Write to the log file during the process.
saveBackup :: UTCTime -> Route -> Route -> Config -> String -> Host -> IO ()
saveBackup utc app database config knownHost localHost = do
  let appName     = name app
      sqlFile     = structure database <> ".sql"
      localPath   = userHome localHost
      remotePath  = userHome (remoteHost config)
      remoteDir   = hostName (remoteHost config)
      logFilePath = localPath <> "/cattleServer-Logs/" <> appName  <> ".log"
  writeLog ("./../cattleServer-Logs" <> logFile) "Backup in process" ("The cattleServer service is backing up " <> appName)
  loginResponse <- runSimpleSSH (loginToServer (remoteHost config) (portNumber config) knownHost (keyDirectory config))
  case loginResponse of
    Left err      -> do
      writeLog logFilePath "Error" ("Fail to " <> show err)
    Right session -> do
      writeLog logFilePath "Success" "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session database (remoteHost config)
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
