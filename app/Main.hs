module Main where

import           Config
import           Control.Concurrent           (threadDelay)
import           Data.Time.Clock
import           Network.SSH.Client.SimpleSSH as SSH
import           System.Directory             (doesDirectoryExist)
import           System.Exit                  as E
import           System.Process
import           Time

main :: IO ()
main = do
  cattleServerDir <- recursiveDirectoryExist "./.." "cattleServer-Logs/" ""
  case cattleServerDir of
    True  -> writeLog ("./../cattleServer-Logs/" <> logFile) "Started" "The cattleServer service has been started correctly"
    False -> writeLog ("./../cattleServer-Logs/" <> logFile) "Started" "The cattleServer service log folder has been created"
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
      recursiveDeleteAppBackup (apps software) (localHost software)
      recursiveBackup False

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
      _ <- recursiveDirectoryExist localPath "backup" nameApp
      saveBackup current (appConfig app) (databaseConfig app) (serviceConfig app) knownHost localHost
    False -> return ()

recursiveSaveAppBackup :: [App] -> String -> Host -> IO ()
recursiveSaveAppBackup [] _ _                     = return ()
recursiveSaveAppBackup (app:apps) knownHost localHost = do
  saveAppBackup app knownHost localHost
  recursiveSaveAppBackup apps knownHost localHost

deleteAppBackup :: App -> Host -> IO ()
deleteAppBackup app localHost = do
  current <- getCurrentTime
  let localPath   = userHome localHost
      nameApp     = name (appConfig app)
      deleteF     = deleteFrequency (serviceConfig app)
      logFilePath = localPath <> "/cattleServer-Logs/" <> nameApp  <> ".log"
      timeDir     = timeToStringDir (subsNominalTime (times deleteF) (unit deleteF) current)
      currentS    = timeToStringDir current
      deleteDir   = localPath <> "/backup/" <> nameApp <> "/" <> recursiveStringDir currentS timeDir (unit deleteF) (times deleteF)
  delete <- doesDirectoryExist deleteDir
  case delete of
    False -> return ()
    True  -> do
      (delExit, _, delErr) <- readProcessWithExitCode "rm" ["-r", deleteDir] []
      case delExit of
        E.ExitSuccess -> do
          writeLog logFilePath "Success" (deleteDir <> " deleted successfully (obsolete backup)")
          writeLog ("./../cattleServer-Logs" <> logFile) "Success" ("The service cattleServer has successfully deleted " <> nameApp <> " obsolete backup")
        _             -> writeLog ("./../cattleServer-Logs" <> logFile) "Error" delErr

recursiveDeleteAppBackup :: [App] -> Host -> IO ()
recursiveDeleteAppBackup []         _         = return ()
recursiveDeleteAppBackup (app:apps) localHost = do
  deleteAppBackup app localHost
  recursiveDeleteAppBackup apps localHost

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
  loginResponse <- loginToServer (remoteHost config) (portNumber config) knownHost (keyDirectory config) logFilePath
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

loginToServer :: Host -> Integer -> String -> Route -> String -> IO (Either SimpleSSHError Session)
loginToServer remote port knownHost keys logFilePath = do
  sessionResponse <- runSimpleSSH (openSession (hostName remote) port knownHost)
  case sessionResponse of
    Left err      -> do
      writeLog logFilePath "Session Error" ("Fail to " <> show err)
      return sessionResponse
    Right session -> do
      let privateKey = (structure keys <> "/" <> name keys)
          publicKey = (privateKey <> ".pub")
      authResponse <- runSimpleSSH (authenticateWithKey session (userName remote) publicKey privateKey "")
      case authResponse of
        Left err           -> do
          writeLog logFilePath "Session Auth Error" ("Fail to " <> show err)
          return authResponse
        Right auth_session -> do
          return authResponse

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
