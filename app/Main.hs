module Main where

import           Config
import           Control.Concurrent           (threadDelay)
import           Data.Char                    (isSpace)
import           Data.IORef                   (modifyIORef', newIORef,
                                               readIORef)
import           Data.Time.Clock
import           KnownHosts                   (Request (..), ensureKnownHost,
                                               mayProceed, outcomeDescription,
                                               outcomeTag)
import           Network.SSH.Client.SimpleSSH as SSH
import           Proc                         (runTool, runToolStreaming,
                                               shellQuote)
import           Progress                     (parseProgress, progressComplete,
                                               renderProgress, statsWorthKeeping,
                                               throttled)
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
      migrateApps (apps software) (localHost software) logDirPath
      recursiveSaveAppBackup (apps software) (knownHosts software) (localHost software) logDirPath (resolveHostKeyPolicy software) (resolveProgressEvery software)
      recursiveDeleteAppBackup (apps software) (localHost software) logDirPath
      recursiveBackup (resolveCheckEvery software)

-- | Bring every application's backups into the current layout.
--
-- Runs on every pass rather than only at startup: it is idempotent and cheap
-- once there is nothing left to move, so a migration interrupted halfway is
-- simply finished next time round, with no marker file to get out of step.
migrateApps :: [App] -> Host -> FilePath -> IO ()
migrateApps []         _         _          = return ()
migrateApps (app:rest) localHost logDirPath = do
  let nameApp     = name (appConfig app)
      appRoot     = userHome localHost <> "/backup/" <> nameApp
      logFilePath = appLogPath logDirPath nameApp
  moved <- migrateNestedBackups appRoot
  case null moved of
    True  -> return ()
    False -> do
      writeLog logFilePath "Success"
        (show (length moved) <> " backup(s) of " <> nameApp <> " renamed into the current layout")
      repointLatest logFilePath appRoot
  migrateApps rest localHost logDirPath

-- | Point @latest@ at the newest backup there is.
repointLatest :: FilePath -> FilePath -> IO ()
repointLatest logFilePath appRoot = do
  remaining <- listBackups appRoot
  case reverse remaining of
    []              -> return ()
    ((_, newest):_) -> do
      linked <- linkLatest appRoot newest
      case linked of
        Left err -> writeLog logFilePath "Error"
          ("Could not point " <> latestLinkName <> " at " <> newest <> ": " <> err)
        Right () -> return ()

saveAppBackup :: App -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO ()
saveAppBackup app knownHost localHost logDirPath policy progressSecs = do
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
    True  -> saveBackup current app knownHost localHost logDirPath policy progressSecs
    False -> return ()

recursiveSaveAppBackup :: [App] -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO ()
recursiveSaveAppBackup [] _ _ _ _ _ = return ()
recursiveSaveAppBackup (app:rest) knownHost localHost logDirPath policy progressSecs = do
  saveAppBackup app knownHost localHost logDirPath policy progressSecs
  recursiveSaveAppBackup rest knownHost localHost logDirPath policy progressSecs

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
saveBackup :: UTCTime -> App -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO ()
saveBackup utc theApp knownHost localHost logDirPath policy progressSecs = do
  let app         = appConfig theApp
      database    = databaseConfig theApp
      config      = serviceConfig theApp
      appName     = name app
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
          rsyncThere  <- runSimpleSSH $ remoteHasRsync session (remoteRsyncPath config)
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              writeLog logFilePath "Error" (show err)
            Right () -> do
              writeLog logFilePath "Success" "SSH connection closed"
              case rsyncThere of
                Right False -> writeLog logFilePath "Error"
                  ("rsync is not available on " <> hostName (remoteHost config)
                    <> "; install it there, or name where it lives with remoteRsyncPath")
                _           -> return ()
              case sshCommand (portNumber config) knownHost (keyDirectory config) of
                Left err  -> writeLog logFilePath "Error" err
                Right ssh -> do
                  let appRoot = localPath <> "/backup/" <> appName
                  dir       <- mkBackupDir localPath appName utc
                  linkDests <- linkDestinations appRoot dir
                  let xfer = Transfer { xferRemote    = remoteHost config
                                      , xferSsh       = ssh
                                      , xferRsyncPath = remoteRsyncPath config
                                      , xferLinkDests = linkDests
                                      , xferInto      = dir
                                      }
                  (sqlExit, sqlErr) <- transferWith logFilePath progressSecs xfer True (remotePath <> "/backup/" <> sqlFile)
                  case rsyncSucceeded sqlExit of
                    True  -> writeLog logFilePath "Success" (sqlFile <> " downloaded successfully")
                    False -> writeLog logFilePath "Error" (rsyncDiagnosis sqlExit sqlErr)
                  (uploadExit, uploadErr) <- transferWith logFilePath progressSecs xfer False (structure app)
                  case rsyncSucceeded uploadExit of
                    True  -> do
                      writeLog logFilePath "Success" (uploadDirName (structure app) <> " downloaded successfully")
                      linked <- linkLatest appRoot dir
                      case linked of
                        Left err -> writeLog logFilePath "Error" ("Could not point " <> latestLinkName <> " at " <> dir <> ": " <> err)
                        Right () -> writeLog logFilePath "Success" (latestLinkName <> " now points at " <> dir)
                      writeLog (serviceLogPath logDirPath) "Success" ("The service cattleServer has successfully backed up " <> appName)
                    False -> writeLog logFilePath "Error" (rsyncDiagnosis uploadExit uploadErr)

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

-- | Whether the remote can be pulled from with rsync, asked over the session
-- that is already open.
--
-- @command -v@ is a shell builtin, so this needs nothing installed in order
-- to report that nothing is installed. A configured 'remoteRsyncPath' is
-- tested as a path instead, since naming one is how an operator says where it
-- really is.
remoteHasRsync :: Session -> Maybe String -> SimpleSSH Bool
remoteHasRsync session m_path = do
  let probe = case m_path of
        Just path -> "test -x " <> shellQuote path
        Nothing   -> "command -v rsync >/dev/null 2>&1"
  result <- execCommand session probe
  return (resultExit result == SSH.ExitSuccess)

-- | Whether an rsync run counts as having produced a backup.
--
-- 24 means files disappeared on the remote while it was copying. That is
-- ordinary for an uploads directory belonging to a live application, and does
-- not make what was copied wrong.
rsyncSucceeded :: ExitCode -> Bool
rsyncSucceeded E.ExitSuccess      = True
rsyncSucceeded (E.ExitFailure 24) = True
rsyncSucceeded _                  = False

-- | What an rsync exit code means, in words rather than as a number.
rsyncDiagnosis :: ExitCode -> String -> String
rsyncDiagnosis code err = case code of
  E.ExitFailure 127 ->
    "rsync is not on PATH here; the Nix wrapper and the unit's path are what "
      <> "put it there. " <> err
  E.ExitFailure 12  ->
    "the remote end did not speak rsync -- usually it is not installed there, "
      <> "or not on the short PATH a non-interactive ssh gets, which "
      <> "remoteRsyncPath exists to fix. " <> err
  E.ExitFailure 23  -> "some files could not be transferred: " <> err
  E.ExitFailure 30  -> "the transfer timed out: " <> err
  _                 -> err

-- | Run one transfer, saying how it is going while it goes.
--
-- The throttle is made fresh for each transfer, so the two a backup makes do
-- not share a clock and the second one still reports its first line promptly.
-- Anything rsync prints that is not progress is checked for the few @--stats@
-- lines worth keeping, and those are logged once the transfer is over.
transferWith :: FilePath -> Int -> Transfer -> Bool -> String -> IO (ExitCode, String)
transferWith logFilePath progressSecs xfer compress remotePath = do
  started  <- getCurrentTime
  emit     <- throttled (fromIntegral progressSecs) (writeLog logFilePath "Progress")
  statsRef <- newIORef []
  result   <- rsyncDown xfer compress remotePath $ \record ->
    case parseProgress record of
      Just p  -> do
        now <- getCurrentTime
        emit (progressComplete p) (renderProgress (diffUTCTime now started) p)
      Nothing -> case statsWorthKeeping record of
        True  -> modifyIORef' statsRef (record :)
        False -> return ()
  stats <- reverse <$> readIORef statsRef
  mapM_ (writeLog logFilePath "Success") stats
  return result

-- | Everything a transfer needs that does not change between the two copies
-- one backup makes.
data Transfer = Transfer
  { xferRemote    :: Host
  , xferSsh       :: String
  , xferRsyncPath :: Maybe String
  , xferLinkDests :: [FilePath]
  , xferInto      :: FilePath
  }

-- | The @ssh@ command line rsync is told to use.
--
-- rsync splits this on whitespace and gives no way to quote, where @scp@ took
-- the same values as separate arguments. Refuse rather than emit a command
-- line that means something other than what the configuration says. Every
-- option value here is free of whitespace by construction, so only the two
-- paths need checking.
sshCommand :: Integer -> FilePath -> Route -> Either String String
sshCommand port knownHost keys
  | any hasSpace [privateKey, knownHost] =
      Left ("rsync cannot be given a path containing whitespace: "
             <> unwords (filter hasSpace [privateKey, knownHost]))
  | otherwise = Right (unwords
      [ "ssh", "-i", privateKey, "-p", show port
      , "-o", "IdentitiesOnly=yes"
      , "-o", "BatchMode=yes"
      , "-o", "StrictHostKeyChecking=yes"
      , "-o", "UserKnownHostsFile=" <> knownHost
      , "-o", "ConnectTimeout=30"
      ])
  where
    privateKey = structure keys <> "/" <> name keys
    hasSpace   = any isSpace

-- | Pull a remote path into the backup directory with rsync.
--
-- Unchanged files are hardlinked against the previous backups rather than
-- copied, so each backup reads as a complete tree while costing only what
-- changed since the last one.
--
-- Deliberately not @-a@: that pulls in @-o@ and @-g@, which need @chown@,
-- which the unit's system call filter denies -- rsync would exit 23 on every
-- run while appearing to have copied everything. Not @-p@ either: @scp@
-- applied the local umask, so backups are private, and preserving the
-- remote's modes would quietly make them world readable.
--
-- @-t@ is not optional. Without it mtimes are not preserved, every file looks
-- changed on the next run, and @--link-dest@ never links anything -- which
-- shows up only as the disk filling faster than it should.
rsyncDown :: Transfer -> Bool -> String -> (String -> IO ()) -> IO (ExitCode, String)
rsyncDown xfer compress remotePath onRecord =
  runToolStreaming "rsync" (rsyncArgs xfer compress remotePath) onRecord

rsyncArgs :: Transfer -> Bool -> String -> [String]
rsyncArgs xfer compress remotePath =
  [ "--recursive", "--links", "--times"
  , "--delete"
  , "--no-inc-recursive"
  , "--info=progress2", "--outbuf=N", "--no-human-readable"
  , "--stats"
  , "--timeout=1800"
  ]
  ++ concat [ ["--link-dest", d] | d <- xferLinkDests xfer ]
  ++ [ "--compress" | compress ]
  ++ concat [ ["--rsync-path", p] | Just p <- [xferRsyncPath xfer] ]
  ++ [ "-e", xferSsh xfer
     , userName (xferRemote xfer) <> "@" <> hostName (xferRemote xfer) <> ":" <> remotePath
     , xferInto xfer <> "/"
     ]
