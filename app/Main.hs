{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Config
import           Control.Concurrent           (threadDelay)
import           Control.Exception            (IOException, try)
import           Data.Char                    (isSpace)
import           Data.IORef                   (modifyIORef', newIORef,
                                               readIORef, writeIORef)
import           Data.List                    (intercalate, isInfixOf, sortOn)
import           Data.Time.Clock
import           KnownHosts                   (Request (..), ensureKnownHost,
                                               mayProceed, outcomeDescription,
                                               outcomeTag)
import           Manifest                     (manifestName, verifyManifest,
                                               writeManifest)
import           Network.SSH.Client.SimpleSSH as SSH
import           Proc                         (runTool, runToolStreaming,
                                               shellQuote)
import           Progress                     (parseProgress,
                                               progressWorthReporting,
                                               renderFinished, renderRunning,
                                               statsWorthKeeping, throttled)
import           System.Exit                  as E
import           System.Directory             (getModificationTime, removeFile,
                                               setModificationTime)
import           System.IO                    (BufferMode (LineBuffering),
                                               hPutStrLn, hSetBuffering,
                                               hSetEncoding, stderr, stdout,
                                               utf8)
import           Time

-- | Log directory used before any configuration has been read: the sibling
-- directory the service has always fallen back to.
fallbackLogDir :: FilePath
fallbackLogDir = "./../" <> defaultLogDirName

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetEncoding  stdout utf8
  parsed <- resolveInvocation
  case parsed of

    Left err -> do
      hPutStrLn stderr ("cattleServer: " <> err)
      hPutStrLn stderr "usage: cattleServer [--once <application>] [<config>]"
      E.exitWith (E.ExitFailure 2)
    Right invocation -> do
      configPath <- resolveConfigPathFor invocation
      e_service  <- readJSONconfigFrom configPath
      case invocationMode invocation of
        Once appName -> runOnce appName e_service >>= E.exitWith
        Daemon       -> do
          let logDirPath = either (const fallbackLogDir) resolveLogDir e_service
          logDirExisted <- ensureLogDir logDirPath
          case logDirExisted of
            True  -> writeLog (serviceLogPath logDirPath) "Started" "The cattleServer service has been started correctly"
            False -> writeLog (serviceLogPath logDirPath) "Started" "The cattleServer service log folder has been created"
          case e_service of
            Left err -> writeLog (serviceLogPath logDirPath) "Config error" err
            Right _  -> return ()
          recursiveBackup configPath (either (const defaultStartupDelay) resolveStartupDelay e_service)

-- | Back up one named application now, whether or not its window has passed.
--
-- Three outcomes, and they are three exit codes on purpose: a caller that
-- gates something else on a fresh backup has to tell "it worked" from "it
-- failed" from "I never got as far as trying".
--
-- The backup is recorded in the same log as any other, which also moves the
-- application's window: a copy is a copy, whoever asked for it.
runOnce :: String -> Either String Service -> IO E.ExitCode
runOnce _ (Left err) = do
  hPutStrLn stderr ("cattleServer: " <> err)
  return (E.ExitFailure 2)
runOnce appName (Right service) =
  case filter ((== appName) . name . appConfig) (apps service) of
    []        -> do
      hPutStrLn stderr ("cattleServer: no application named " <> appName)
      hPutStrLn stderr ("  configured: " <> intercalate ", " (map (name . appConfig) (apps service)))
      return (E.ExitFailure 2)
    (app : _) -> do
      let logDirPath = resolveLogDir service
      _ <- ensureLogDir logDirPath

      migrateApps [app] (localHost service) logDirPath
      current <- getCurrentTime
      outcome <- saveBackup current app (knownHosts service) (localHost service)
                   logDirPath (resolveHostKeyPolicy service) (resolveProgressEvery service)
      case outcome of
        BackupRecorded dir -> do
          putStrLn (appName <> " backed up into " <> dir)
          return E.ExitSuccess
        BackupFailed err   -> do
          hPutStrLn stderr ("cattleServer: " <> appName <> " was not backed up: " <> err)
          return (E.ExitFailure 1)

-- | Wait, then make one pass over every application, forever.
--
-- The wait comes first, so the argument is the startup delay on the way in
-- and the configured interval on the way round. The configuration is re-read
-- on each pass, which is what lets an edit take effect without a restart --
-- including an edit to the interval itself.
recursiveBackup :: FilePath -> Int -> IO ()
recursiveBackup configPath waitMinutes = do
  threadDelay (minutesToMicros waitMinutes)
  e_config   <- readJSONconfigFrom configPath
  case e_config of
    Left err   -> do
      writeLog (serviceLogPath fallbackLogDir) "Config error" err
      recursiveBackup configPath defaultCheckEvery
    Right software -> do
      let logDirPath = resolveLogDir software
      _ <- ensureLogDir logDirPath
      migrateApps (apps software) (localHost software) logDirPath
      recursiveSaveAppBackup (apps software) (knownHosts software) (localHost software) logDirPath (resolveHostKeyPolicy software) (resolveProgressEvery software)
      recursiveDeleteAppBackup (apps software) (localHost software) logDirPath
      verifyApps (apps software) (localHost software) logDirPath (verifyEvery software)
      alertApps  (apps software) logDirPath (alertCommand software)
      recursiveBackup configPath (resolveCheckEvery software)

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

-- | Run a command when an application has gone too long without a backup.
--
-- Logging is not warning. A service that has been failing for a month has
-- been saying so all along, in a file nobody reads. This is the part that
-- goes and tells someone: the command gets the detail on its standard input,
-- so it can be a mail, a webhook, or anything a shell can express.
--
-- One alert per window rather than one per pass, tracked by a marker file
-- beside the logs. A backup that succeeds clears the marker, so the next time
-- things go wrong it is reported promptly instead of after another window.
--
-- Note what happens on a machine that has never backed up: 'getLastBackup'
-- reports the last one as very long ago, so it alerts. That is deliberate --
-- a deployment that has never worked is exactly what you want to hear about.
alertApps :: [App] -> FilePath -> Maybe String -> IO ()
alertApps _       _          Nothing        = return ()
alertApps theApps logDirPath (Just command) = mapM_ one theApps
  where
    one theApp = do
      let nameApp = name (appConfig theApp)
      case alertAfter (serviceConfig theApp) of
        Nothing    -> return ()
        Just hours -> do
          now      <- getCurrentTime
          lastGood <- getLastBackup logDirPath nameApp
          let age = hoursDiff now lastGood
          case age >= hours of
            False -> clearMarker (alertMarkerPath logDirPath nameApp)
            True  -> do
              due <- markerOlderThan (alertMarkerPath logDirPath nameApp) now hours
              case due of
                False -> return ()
                True  -> raise nameApp hours age

    raise nameApp hours age = do
      let logFilePath = appLogPath logDirPath nameApp
          body = "cattleServer: " <> nameApp <> " has not been backed up for "
                   <> show age <> " hours, and the limit is " <> show hours <> ".\n"
      (code, _, err) <- runTool "sh" ["-c", command] body
      case code of
        E.ExitSuccess -> do
          writeLog logFilePath "Alert"
            (nameApp <> " has not been backed up for " <> show age
              <> " hours; the alert command was run")
          touched <- try' (getCurrentTime >>= setModificationTime (alertMarkerPath logDirPath nameApp))
          case touched of
            Right () -> return ()
            Left _   -> writeFile (alertMarkerPath logDirPath nameApp) ""
        _ -> writeLog logFilePath "Error" ("the alert command failed: " <> err)

alertMarkerPath :: FilePath -> String -> FilePath
alertMarkerPath logDirPath nameApp = logDirPath <> "/" <> nameApp <> ".alerted"

-- | Whether the marker is missing, or older than the window.
markerOlderThan :: FilePath -> UTCTime -> Int -> IO Bool
markerOlderThan path now hours = do
  stamped <- try' (getModificationTime path)
  return $ case stamped of
    Left _  -> True
    Right t -> hoursDiff now t >= hours

clearMarker :: FilePath -> IO ()
clearMarker path = do
  _ <- try' (removeFile path)
  return ()

-- | Check one backup per application against its manifest, when one is due.
--
-- Which backup is chosen by its manifest's own modification time, and
-- verifying touches that file, so the least recently checked one is always
-- next. The rotation keeps no state of its own: the filesystem already
-- records everything it needs.
--
-- This is the only thing that turns "it was written correctly" into "it is
-- still correct". A disk can hand back a byte other than the one it was
-- given, and nothing else here would ever notice.
verifyApps :: [App] -> Host -> FilePath -> Maybe Int -> IO ()
verifyApps _       _         _          Nothing      = return ()
verifyApps theApps localHost logDirPath (Just hours) = mapM_ one theApps
  where
    one theApp = do
      let nameApp     = name (appConfig theApp)
          appRoot     = userHome localHost <> "/backup/" <> nameApp
          logFilePath = appLogPath logDirPath nameApp
      backups <- listBackups appRoot
      stalest <- leastRecentlyChecked [ p | (_, p) <- backups ]
      now     <- getCurrentTime
      case stalest of
        Nothing -> return ()
        Just (checkedAt, dir)
          | hoursDiff now checkedAt < hours -> return ()
          | otherwise                       -> verifyOne logFilePath dir

    verifyOne logFilePath dir = do
      outcome <- verifyManifest dir
      touched <- try' (getCurrentTime >>= setModificationTime (dir <> "/" <> manifestName))
      case touched of
        Left err -> writeLog logFilePath "Error" ("could not touch the manifest in " <> dir <> ": " <> err)
        Right () -> return ()
      case outcome of
        Left err -> writeLog logFilePath "Error" ("could not verify " <> dir <> ": " <> err)
        Right (checked, []) -> writeLog logFilePath "Success"
          (show checked <> " file(s) in " <> dir <> " still match their manifest")
        Right (checked, bad) -> writeLog logFilePath "Error"
          (show (length bad) <> " of " <> show checked <> " file(s) in " <> dir
            <> " no longer match their manifest: " <> intercalate ", " (take 5 bad))

-- | The backup whose manifest was checked longest ago, if any has one.
leastRecentlyChecked :: [FilePath] -> IO (Maybe (UTCTime, FilePath))
leastRecentlyChecked dirs = do
  stamped <- mapM stamp dirs
  return $ case sortOn fst [ (t, d) | Just (t, d) <- stamped ] of
    []      -> Nothing
    (oldest:_) -> Just oldest
  where
    stamp dir = do
      attempt <- try' (getModificationTime (dir <> "/" <> manifestName))
      return $ case attempt of
        Right t -> Just (t, dir)
        Left _  -> Nothing

try' :: IO a -> IO (Either String a)
try' action = do
  attempt <- try action
  return $ case attempt of
    Right a                 -> Right a
    Left (e :: IOException) -> Left (show e)

-- | Back up one application if its window has passed.
--
-- 'Nothing' means it was not due yet, which is a different answer from a
-- backup that was attempted and failed.
saveAppBackup :: App -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO (Maybe BackupOutcome)
saveAppBackup app knownHost localHost logDirPath policy progressSecs = do
  current <- getCurrentTime
  let localPath = userHome localHost
      nameApp   = name (appConfig app)
  doBackup <- case backupFrequency (serviceConfig app) of
    Nothing      -> return False
    Just backupF -> do
      _ <- ensureLogDir logDirPath
      lastBackup <- getLastBackup logDirPath nameApp
      case unit backupF of
        "Hours"  -> return $ (hoursDiff  current lastBackup) > (times backupF)
        "Days"   -> return $ (daysDiff   current lastBackup) > (times backupF)
        "Weeks"  -> return $ (weeksDiff  current lastBackup) > (times backupF)
        "Months" -> return $ (monthsDiff current lastBackup) > (times backupF)
        _        -> return $ (hoursDiff  current lastBackup) > 8
  case doBackup of
    True  -> Just <$> saveBackup current app knownHost localHost logDirPath policy progressSecs
    False -> return Nothing

recursiveSaveAppBackup :: [App] -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO ()
recursiveSaveAppBackup [] _ _ _ _ _ = return ()
recursiveSaveAppBackup (app:rest) knownHost localHost logDirPath policy progressSecs = do
  _ <- saveAppBackup app knownHost localHost logDirPath policy progressSecs
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

-- | What one attempt at a backup ended up doing.
--
-- The daemon only has to log, so it can drop this; a caller that has to exit
-- with a status -- or decide whether something else may proceed -- cannot, and
-- a line in a log file is not a return value. The text of a failure is the
-- same one written to the log, so the two can never drift apart.
data BackupOutcome
  = BackupRecorded FilePath
  -- ^ The dump arrived complete, the uploads came with it, and the @latest@
  -- link points at this directory.
  | BackupFailed String
  -- ^ Nothing was recorded, and the previous backup is still the newest one.
  deriving (Eq, Show)

-- | Login to the server via SSH, backs up the database and downloads the full backup locally via SCP.
-- Write to the log file during the process.
saveBackup :: UTCTime -> App -> String -> Host -> FilePath -> HostKeyPolicy -> Int -> IO BackupOutcome
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
  loginResponse <- loginToServer (remoteHost config) (portNumber config) knownHost (keyDirectory config) policy (resolveHostKeys config) (hostKeyFingerprint config) (resolveConnectTimeout config) logFilePath
  case loginResponse of
    Left err      -> do
      failWith logFilePath "Error" ("Fail to " <> show err)
    Right session -> do
      writeLog logFilePath "Success" "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session database (remoteHost config)
      case commandResponse of
        Left err     -> do
          failWith logFilePath "Error" (show err)
        Right result -> do
          case resultExit result of
            SSH.ExitSuccess -> writeLog logFilePath "Success" (sqlFile <> " created successfully")
            _           -> writeLog logFilePath "Error" (show (resultErr result))
          rsyncThere  <- runSimpleSSH $ remoteHasRsync session (remoteRsyncPath config)
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              failWith logFilePath "Error" (show err)
            Right () -> do
              writeLog logFilePath "Success" "SSH connection closed"
              case rsyncThere of
                Right False -> writeLog logFilePath "Error"
                  ("rsync is not available on " <> hostName (remoteHost config)
                    <> "; install it there, or name where it lives with remoteRsyncPath")
                _           -> return ()
              case sshCommand (portNumber config) knownHost (keyDirectory config) (resolveConnectTimeout config) of
                Left err  -> failWith logFilePath "Error" err
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
                  dumpOk <- case rsyncSucceeded sqlExit of
                    False -> do
                      writeLog logFilePath "Error" (rsyncDiagnosis sqlExit sqlErr)
                      return False
                    True  -> do
                      complete <- dumpLooksComplete (dir <> "/" <> sqlFile)
                      case complete of
                        Right () -> do
                          writeLog logFilePath "Success" (sqlFile <> " downloaded successfully")
                          return True
                        Left err -> do
                          writeLog logFilePath "Error" (sqlFile <> " arrived incomplete: " <> err)
                          return False
                  (uploadExit, uploadErr) <- transferWith logFilePath progressSecs xfer False (structure app)
                  case rsyncSucceeded uploadExit of
                    False -> failWith logFilePath "Error" (rsyncDiagnosis uploadExit uploadErr)
                    True  -> do
                      writeLog logFilePath "Success" (uploadDirName (structure app) <> " downloaded successfully")
                      case dumpOk of
                        False -> failWith logFilePath "Skipped"
                          ("not recording a backup of " <> appName
                            <> ": the database dump did not arrive complete, so "
                            <> latestLinkName <> " still points at the previous one")
                        True  -> do
                          manifested <- writeManifest dir
                          case manifested of
                            Left err -> writeLog logFilePath "Error" ("could not record a manifest for " <> dir <> ": " <> err)
                            Right n  -> writeLog logFilePath "Success" (show n <> " file(s) recorded in " <> dir <> "/" <> manifestName)
                          linked <- linkLatest appRoot dir
                          case linked of
                            Left err -> writeLog logFilePath "Error" ("Could not point " <> latestLinkName <> " at " <> dir <> ": " <> err)
                            Right () -> writeLog logFilePath "Success" (latestLinkName <> " now points at " <> dir)
                          writeLog (serviceLogPath logDirPath) "Success" ("The service cattleServer has successfully backed up " <> appName)
                          return (BackupRecorded dir)

-- | Write the line the log would have got either way, and hand the same text
-- back as the failure. One call site, so the two cannot say different things.
failWith :: FilePath -> String -> String -> IO BackupOutcome
failWith logFilePath level message = do
  writeLog logFilePath level message
  return (BackupFailed message)

-- | Establish that the remote host is trusted, then open a session to it.
--
-- libssh2 refuses a host that is not in the @known_hosts@ file, which used to
-- mean somebody had to log in by hand once per machine before the service
-- could work. That step happens here now.
loginToServer :: Host -> Integer -> String -> Route
              -> HostKeyPolicy -> [String] -> Maybe String
              -> Int -> String -> IO (Either SimpleSSHError Session)
loginToServer remote port knownHost keys policy declared m_pinned connectSecs logFilePath = do
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
    else do
      reach <- reachableOverSsh remote port knownHost keys connectSecs
      case reach of
        Left err -> do
          writeLog logFilePath "Error"
            ("cannot reach " <> userName remote <> "@" <> hostName remote
              <> ":" <> show port <> " within " <> show connectSecs <> "s: " <> err)
          return (Left Connect)
        Right () -> loginToTrustedServer remote port knownHost keys logFilePath

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
-- Written to a temporary name and moved into place only once pg_dump has
-- succeeded: a redirection onto the final name truncates it before the first
-- row is written, so a dump that failed halfway used to destroy the copy that
-- was already there. The local ones survive that through --link-dest; the
-- remote one had nothing to survive it with.
databaseBackupInServer :: Session -> Route -> Host -> SimpleSSH Result
databaseBackupInServer session database remote = do
  let dbStruct  = structure database
      remoteDir = userHome remote <> "/backup"
      final     = remoteDir <> "/" <> dbStruct <> ".sql"
      partial   = final <> ".partial"
  response <- execCommand session $
    "mkdir -p "     <> shellQuote remoteDir
      <> " && pg_dump -U " <> shellQuote (name database)
      <> " "               <> shellQuote dbStruct
      <> " > "             <> shellQuote partial
      <> " && mv "         <> shellQuote partial <> " " <> shellQuote final
      <> " || { rm -f "    <> shellQuote partial <> "; false; }"
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
--
-- The closing line is written here rather than from inside the stream,
-- because no single update announces itself as the last: @to-chk=0/1@ holds
-- from start to finish of a single file transfer, which every dump is. Once
-- rsync has exited, though, the update kept in 'lastRef' is the last one by
-- definition -- and it is the one that says what the transfer cost.
transferWith :: FilePath -> Int -> Transfer -> Bool -> String -> IO (ExitCode, String)
transferWith logFilePath progressSecs xfer compress remotePath = do
  started  <- getCurrentTime
  emit     <- throttled (fromIntegral progressSecs) (writeLog logFilePath "Progress")
  statsRef <- newIORef []
  lastRef  <- newIORef Nothing
  result   <- rsyncDown xfer compress remotePath $ \record ->
    case parseProgress record of
      Just p -> do
        writeIORef lastRef (Just p)
        case progressWorthReporting p of
          True  -> do
            now <- getCurrentTime
            emit (renderRunning (diffUTCTime now started) p)
          False -> return ()
      Nothing -> case statsWorthKeeping record of
        True  -> modifyIORef' statsRef (record :)
        False -> return ()
  finished <- readIORef lastRef
  ended    <- getCurrentTime
  mapM_ (writeLog logFilePath "Progress" . renderFinished (diffUTCTime ended started))
        finished
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

-- | The arguments that identify this connection to @ssh@, without the host.
sshArgs :: Integer -> FilePath -> Route -> Int -> [String]
sshArgs port knownHost keys connectSecs =
  [ "-i", structure keys <> "/" <> name keys, "-p", show port
  , "-o", "IdentitiesOnly=yes"
  , "-o", "BatchMode=yes"
  , "-o", "StrictHostKeyChecking=yes"
  , "-o", "UserKnownHostsFile=" <> knownHost
  , "-o", "ConnectTimeout=" <> show connectSecs
  ]

-- | The @ssh@ command line rsync is told to use.
--
-- rsync splits this on whitespace and gives no way to quote, where @scp@ took
-- the same values as separate arguments. Refuse rather than emit a command
-- line that means something other than what the configuration says. Every
-- option value here is free of whitespace by construction, so only the two
-- paths need checking.
sshCommand :: Integer -> FilePath -> Route -> Int -> Either String String
sshCommand port knownHost keys connectSecs
  | any hasSpace [privateKey, knownHost] =
      Left ("rsync cannot be given a path containing whitespace: "
             <> unwords (filter hasSpace [privateKey, knownHost]))
  | otherwise = Right (unwords ("ssh" : sshArgs port knownHost keys connectSecs))
  where
    privateKey = structure keys <> "/" <> name keys
    hasSpace   = any isSpace

-- | Whether the remote answered at all, within @connectSecs@.
--
-- 'Left' only for the answers that mean nobody was there. Everything else --
-- a refused key, a host key that changed -- is 'Right', because the host did
-- answer and libssh2 is the one that should name what is wrong with it.
reachableOverSsh :: Host -> Integer -> FilePath -> Route -> Int -> IO (Either String ())
reachableOverSsh remote port knownHost keys connectSecs = do
  (_, _, err) <- runTool "ssh"
    (sshArgs port knownHost keys connectSecs
      ++ [ userName remote <> "@" <> hostName remote, "true" ]) ""
  let diagnosis = lastLine err
  return $ if any (`isInfixOf` diagnosis) unreachable
    then Left diagnosis
    else Right ()
  where
    unreachable =
      [ "timed out", "Connection refused", "No route to host"
      , "Network is unreachable", "Name or service not known"
      , "Temporary failure in name resolution"
      ]
    lastLine s = case reverse (filter (not . null) (lines s)) of
      (l:_) -> l
      []    -> ""

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
