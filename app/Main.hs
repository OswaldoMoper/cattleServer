module Main where

import           Config
import           Control.Concurrent           (threadDelay)
import           Data.List                    (isPrefixOf)
import           Data.Time.Clock
import           KnownHosts                   (Request (..), ensureKnownHost,
                                               mayProceed, outcomeDescription,
                                               outcomeTag)
import           Network.SSH.Client.SimpleSSH as SSH
import           Proc                         (runTool, shellQuote)
import           System.Directory             (doesDirectoryExist)
import           System.Exit                  as E
import           System.IO                    (BufferMode (LineBuffering),
                                               hSetBuffering, hSetEncoding,
                                               stdout, utf8)
import           System.Process
import           Time

-- | Log directory used before any configuration has been read: the sibling
-- directory the service has always fallen back to.
fallbackLogDir :: FilePath
fallbackLogDir = "./../" <> defaultLogDirName

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetEncoding  stdout utf8
  configPath <- resolveConfigPath
  m_service  <- readJSONconfigFrom configPath
  let logDirPath = maybe fallbackLogDir resolveLogDir m_service
  logDirExisted <- ensureLogDir logDirPath
  case logDirExisted of
    True  -> writeLog (serviceLogPath logDirPath) "Started" "The cattleServer service has been started correctly"
    False -> writeLog (serviceLogPath logDirPath) "Started" "The cattleServer service log folder has been created"
  recursiveBackup (maybe defaultStartupDelay resolveStartupDelay m_service)

-- | Wait, then make one pass over every application, forever.
--
-- The wait comes first, so the argument is the startup delay on the way in
-- and the configured interval on the way round. The configuration is re-read
-- on each pass, which is what lets an edit take effect without a restart --
-- including an edit to the interval itself.
recursiveBackup :: Int -> IO ()
recursiveBackup waitMinutes = do
  threadDelay (minutesToMicros waitMinutes)
  configPath <- resolveConfigPath
  m_config   <- readJSONconfigFrom configPath
  case m_config of
    Nothing   -> do
      writeLog (serviceLogPath fallbackLogDir) "Config error" ("The cattleServer service hasn't been configurated correctly: " <> configPath)
      recursiveBackup defaultCheckEvery
    Just software -> do
      let logDirPath = resolveLogDir software
      _ <- ensureLogDir logDirPath
      recursiveSaveAppBackup (apps software) (knownHosts software) (localHost software) logDirPath (resolveHostKeyPolicy software)
      recursiveDeleteAppBackup (apps software) (localHost software) logDirPath
      recursiveBackup (resolveCheckEvery software)

saveAppBackup :: App -> String -> Host -> FilePath -> HostKeyPolicy -> IO ()
saveAppBackup app knownHost localHost logDirPath policy = do
  current <- getCurrentTime
  let localPath = userHome localHost
      nameApp   = name (appConfig app)
      backupF   = backupFrequency (serviceConfig app)
  doBackup <- do
    _ <- ensureLogDir logDirPath
    lastBackup <- getLastBackup logDirPath nameApp
    case unit backupF of
      "Hours"  -> return $ (hoursDiff  current lastBackup) > (times backupF)
      "Days"   -> return $ (daysDiff   current lastBackup) > (times backupF)
      "Weeks"  -> return $ (weeksDiff  current lastBackup) > (times backupF)
      "Months" -> return $ (monthsDiff current lastBackup) > (times backupF)
      _        -> return $ (hoursDiff  current lastBackup) > 8
  case doBackup of
    True  -> saveBackup current (appConfig app) (databaseConfig app) (serviceConfig app) knownHost localHost logDirPath policy
    False -> return ()

recursiveSaveAppBackup :: [App] -> String -> Host -> FilePath -> HostKeyPolicy -> IO ()
recursiveSaveAppBackup [] _ _ _ _                                       = return ()
recursiveSaveAppBackup (app:apps) knownHost localHost logDirPath policy = do
  saveAppBackup app knownHost localHost logDirPath policy
  recursiveSaveAppBackup apps knownHost localHost logDirPath policy

-- | Delete the backups that are older than 'deleteFrequency', oldest first,
-- while leaving at least 'keepAtLeast' of them.
--
-- The layout this replaced could only name the one directory that fell exactly
-- on the cutoff, so a day the service happened to be down was never revisited
-- and its backups stayed forever. Sorting and taking a prefix reaches all of
-- them, which also means the first pass after this lands clears whatever
-- backlog that left behind.
deleteAppBackup :: App -> Host -> FilePath -> IO ()
deleteAppBackup app localHost logDirPath = do
  current <- getCurrentTime
  let nameApp     = name (appConfig app)
      deleteF     = deleteFrequency (serviceConfig app)
      logFilePath = appLogPath logDirPath nameApp
      appRoot     = userHome localHost <> "/backup/" <> nameApp
      cutoff      = subsNominalTime (times deleteF) (unit deleteF) current
      floor'      = resolveKeepAtLeast (serviceConfig app)
  existing <- listBackups appRoot
  let expired  = takeWhile ((< cutoff) . fst) existing
      spare    = length existing - floor'
      doomed   = take (max 0 spare) expired
      withheld = length expired - length doomed
  mapM_ (removeBackup logFilePath (serviceLogPath logDirPath) nameApp) doomed
  case withheld > 0 of
    True  -> writeLog logFilePath "Skipped"
      (show withheld <> " backup(s) of " <> nameApp <> " older than the cutoff kept: "
        <> "deleting them would leave fewer than the " <> show floor' <> " to keep")
    False -> return ()

-- | Delete one backup, through 'runTool' so a missing @rm@ fails this deletion
-- rather than the daemon.
removeBackup :: FilePath -> FilePath -> String -> (UTCTime, FilePath) -> IO ()
removeBackup logFilePath serviceLog nameApp (_, dir) = do
  (delExit, _, delErr) <- runTool "rm" ["-r", dir] []
  case delExit of
    E.ExitSuccess -> do
      writeLog logFilePath "Success" (dir <> " deleted successfully (obsolete backup)")
      writeLog serviceLog  "Success" ("The service cattleServer has successfully deleted " <> nameApp <> " obsolete backup")
    _             -> writeLog serviceLog "Error" delErr

recursiveDeleteAppBackup :: [App] -> Host -> FilePath -> IO ()
recursiveDeleteAppBackup []         _         _          = return ()
recursiveDeleteAppBackup (app:apps) localHost logDirPath = do
  deleteAppBackup app localHost logDirPath
  recursiveDeleteAppBackup apps localHost logDirPath

-- | Login to the server via SSH, backs up the database and downloads the full backup locally via SCP.
-- Write to the log file during the process.
saveBackup :: UTCTime -> Route -> Route -> Config -> String -> Host -> FilePath -> HostKeyPolicy -> IO ()
saveBackup utc app database config knownHost localHost logDirPath policy = do
  let appName     = name app
      sqlFile     = structure database <> ".sql"
      localPath   = userHome localHost
      remotePath  = userHome (remoteHost config)
      logFilePath = appLogPath logDirPath appName
  writeLog (serviceLogPath logDirPath) "Backup in process" ("The cattleServer service is backing up " <> appName)
  loginResponse <- loginToServer (remoteHost config) (portNumber config) knownHost (keyDirectory config) policy (resolveHostKeys config) (hostKeyFingerprint config) logFilePath
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
              dir <- mkBackupDir localPath appName utc
              (sqlExit', _, sqlErr') <- databaseBackupLocally (remoteHost config) (portNumber config) knownHost (keyDirectory config) (remotePath <> "/backup/" <> sqlFile) (dir <> "/" <> sqlFile)
              case sqlExit' of
                E.ExitSuccess -> writeLog logFilePath "Success" (sqlFile <> " downloaded successfully")
                _             -> writeLog logFilePath "Error" sqlErr'
              (uploadExit', _, uploadErr') <- databaseBackupLocally (remoteHost config) (portNumber config) knownHost (keyDirectory config) (structure app) (dir <> "/" <> uploadDirName (structure app))
              case uploadExit' of
                E.ExitSuccess -> do
                  writeLog logFilePath "Success" ("Uploads directory downloaded successfully")
                  linked <- linkLatest (localPath <> "/backup/" <> appName) dir
                  case linked of
                    Left err -> writeLog logFilePath "Error" ("Could not point " <> latestLinkName <> " at " <> dir <> ": " <> err)
                    Right () -> writeLog logFilePath "Success" (latestLinkName <> " now points at " <> dir)
                  writeLog (serviceLogPath logDirPath) "Success" ("The service cattleServer has successfully backed up " <> appName)
                _             -> writeLog logFilePath "Error" uploadErr'

-- | Establish that the remote host is trusted, then open a session to it.
--
-- libssh2 refuses a host that is not in the @known_hosts@ file, which used to
-- mean somebody had to log in by hand once per machine before the service
-- could work. That step happens here now.
loginToServer :: Host -> Integer -> String -> Route
              -> HostKeyPolicy -> [String] -> Maybe String
              -> String -> IO (Either SimpleSSHError Session)
loginToServer remote port knownHost keys policy declared m_pinned logFilePath = do
  outcome <- ensureKnownHost Request
    { reqFile        = knownHost
    , reqHost        = hostName remote
    , reqPort        = port
    , reqPolicy      = policy
    , reqDeclared    = declared
    , reqFingerprint = m_pinned
    }
  writeLog logFilePath (outcomeTag outcome)
           (outcomeDescription (hostName remote) port knownHost outcome)
  if not (mayProceed outcome)
    then return (Left KnownhostsCheck)
    else loginToTrustedServer remote port knownHost keys logFilePath

loginToTrustedServer :: Host -> Integer -> String -> Route -> String -> IO (Either SimpleSSHError Session)
loginToTrustedServer remote port knownHost keys logFilePath = do
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
        Left err -> do
          writeLog logFilePath "Session Auth Error" ("Fail to " <> show err)
          closeResponse <- runSimpleSSH (closeSession session)
          case closeResponse of
            Left closeErr -> writeLog logFilePath "Error" (show closeErr)
            Right ()      -> return ()
        Right _  -> return ()
      return authResponse

-- | Dump the database on the remote host.
--
-- The destination directory is created first: the redirection cannot create
-- it, so without this the first backup against a remote fails and the fix is
-- a manual mkdir over ssh. It is the one thing the service could not set up
-- for itself.
--
-- The command runs through a remote shell, so every value taken from the
-- configuration is quoted rather than interpolated bare.
databaseBackupInServer :: Session -> Route -> Host -> SimpleSSH Result
databaseBackupInServer session database remote = do
  let dbStruct  = structure database
      remoteDir = userHome remote <> "/backup"
  response <- execCommand session $
    "mkdir -p "     <> shellQuote remoteDir
      <> " && pg_dump -U " <> shellQuote (name database)
      <> " "               <> shellQuote dbStruct
      <> " > "             <> shellQuote (remoteDir <> "/" <> dbStruct <> ".sql")
  return response

-- | Copy a remote path to a local one with @scp@.
--
-- @scp@ is resolved on @PATH@, which the Nix wrapper and the systemd unit are
-- responsible for populating. It uses the remote user and the port from the
-- configuration, and the same @known_hosts@ file as libssh2 -- otherwise it
-- would consult the invoking user's @~/.ssh@ and disagree about which hosts
-- are trusted.
databaseBackupLocally :: Host -> Integer -> FilePath -> Route -> String -> String
                      -> IO (ExitCode, String, String)
databaseBackupLocally remote port knownHost keys remotePath localPath =
  runTool "scp"
    [ "-i", structure keys <> "/" <> name keys
    , "-P", show port
    , "-o", "IdentitiesOnly=yes"
    , "-o", "BatchMode=yes"
    , "-o", "StrictHostKeyChecking=yes"
    , "-o", "UserKnownHostsFile=" <> knownHost
    , "-r"
    , userName remote <> "@" <> hostName remote <> ":" <> remotePath
    , localPath
    ] []
