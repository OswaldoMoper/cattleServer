{-# LANGUAGE ScopedTypeVariables #-}

-- | Maintenance of the @known_hosts@ file that libssh2 and @scp@ both read.
--
-- The pinned @simplessh@ fork can only /read/ that file, so this module drives
-- the OpenSSH command line tools instead. In particular the lookup goes
-- through @ssh-keygen -F@, which is the only thing that understands hashed
-- (@|1|@) entries; searching the file textually would miss them and add a
-- duplicate on every cycle.
module KnownHosts
  ( Request (..)
  , Outcome (..)
  , ensureKnownHost
  , hostSpec
  , mayProceed
  , outcomeTag
  , outcomeDescription
  ) where

import           Config             (HostKeyPolicy (..))
import           Control.Exception  (IOException, try)
import           Control.Monad      (unless)
import           Data.Char          (isSpace)
import           Data.List          (dropWhileEnd, intercalate, isPrefixOf)
import           Proc               (runTool)
import           System.Directory   (createDirectoryIfMissing, doesFileExist)
import           System.Exit        (ExitCode (..))
import           System.FilePath    (takeDirectory)
import           System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode,
                                     unionFileModes)

-- | What to ensure, and how much trust may be extended to do it.
data Request = Request
  { reqFile        :: FilePath
  , reqHost        :: String
  , reqPort        :: Integer
  , reqPolicy      :: HostKeyPolicy
  , reqDeclared    :: [String]
    -- ^ Host keys from the configuration. Used before any scan.
  , reqFingerprint :: Maybe String
    -- ^ A @SHA256:@ pin that a scanned key must match.
  } deriving (Eq, Show)

-- | What happened.
--
-- Every failure is a value rather than an exception: one unreachable host
-- must not stop the other applications from being backed up.
data Outcome
  = AlreadyKnown
  | Added String [String]
    -- ^ Where the keys came from, and the lines that were appended.
  | RefusedUnknown
  | DeclaredUnparseable [String]
  | FingerprintMismatch [String]
    -- ^ The fingerprints the host actually offered.
  | ScanFailed String
  | WriteFailed String
  deriving (Eq, Show)

-- | How a host is spelled in @known_hosts@: bare on the default port,
-- bracketed with the port otherwise. @ssh-keygen -F@ and @ssh-keyscan@ agree
-- on this, so one spelling serves both the lookup and what gets written.
hostSpec :: String -> Integer -> String
hostSpec host port
  | port == 22 = host
  | otherwise  = "[" <> host <> "]:" <> show port

-- | Make sure the remote host is in the @known_hosts@ file.
--
-- Precedence: an entry already present is never touched, then keys declared
-- in the configuration, then -- only under 'AcceptNewHostKey' -- whatever
-- @ssh-keyscan@ answers.
ensureKnownHost :: Request -> IO Outcome
ensureKnownHost req = do
  known <- isKnownHost (reqFile req) (reqHost req) (reqPort req)
  if known
    then return AlreadyKnown
    else case reqDeclared req of
      (_:_) -> installDeclared req
      []    -> case reqPolicy req of
        StrictHostKey    -> return RefusedUnknown
        AcceptNewHostKey -> installScanned req

-- | Whether the host already has an entry.
--
-- Both the exit code and the output are checked: some older OpenSSH releases
-- exit zero even when they found nothing.
isKnownHost :: FilePath -> String -> Integer -> IO Bool
isKnownHost khFile host port = do
  exists <- doesFileExist khFile
  if not exists
    then return False
    else do
      (code, out, _) <- runTool "ssh-keygen" ["-F", hostSpec host port, "-f", khFile] ""
      return (code == ExitSuccess && any (not . isCommentOrBlank) (lines out))

isCommentOrBlank :: String -> Bool
isCommentOrBlank line = let t = dropWhile isSpace line in null t || "#" `isPrefixOf` t

-- | Install the keys the operator declared, without asking the network what
-- the host claims to be.
installDeclared :: Request -> IO Outcome
installDeclared req =
  case traverse (normalise (reqHost req) (reqPort req)) (reqDeclared req) of
    Nothing      -> return (DeclaredUnparseable (reqDeclared req))
    Just entries -> do
      written <- appendKnownHosts (reqFile req) entries
      return $ case written of
        Left err -> WriteFailed err
        Right () -> Added "the configuration" entries

-- | Turn a declared key into a @known_hosts@ line for this host and port.
--
-- Accepts a full line, whose host field is replaced, or a bare
-- @\<type\> \<base64\>@ pair, which is the shape a Nix or agenix recipients
-- file already holds.
normalise :: String -> Integer -> String -> Maybe String
normalise host port line = case words line of
  (keyType : key : _)     | isKeyType keyType -> Just (render keyType key)
  (_ : keyType : key : _) | isKeyType keyType -> Just (render keyType key)
  _                                           -> Nothing
  where
    render keyType key = hostSpec host port <> " " <> keyType <> " " <> key
    isKeyType t = any (`isPrefixOf` t) ["ssh-", "ecdsa-", "sk-"]

installScanned :: Request -> IO Outcome
installScanned req = do
  scanned <- scanHostKeys (reqHost req) (reqPort req)
  case scanned of
    Left err       -> return (ScanFailed err)
    Right keyLines -> do
      selected <- selectPinned (reqFingerprint req) keyLines
      case selected of
        Left offered   -> return (FingerprintMismatch offered)
        Right accepted -> do
          written <- appendKnownHosts (reqFile req) accepted
          return $ case written of
            Left err -> WriteFailed err
            Right () -> Added "ssh-keyscan" accepted

scanHostKeys :: String -> Integer -> IO (Either String [String])
scanHostKeys host port = do
  (code, out, err) <- runTool "ssh-keyscan"
    [ "-T", "10", "-p", show port, "-t", "ed25519,rsa,ecdsa", host ] ""
  let keyLines = filter isKeyLine (lines out)
  return $ case (code, keyLines) of
    (ExitSuccess, (_:_)) -> Right keyLines
    _ | null (trim err)  -> Left "ssh-keyscan returned no host key"
      | otherwise        -> Left (trim err)
  where
    isKeyLine line = case words line of
      (h:_:_:_) -> not ("#" `isPrefixOf` h)
      _         -> False

-- | Keep the scanned keys whose fingerprint matches the pin.
--
-- Three key types are scanned but only one fingerprint is pinned, so this
-- filters rather than refusing outright: two of the three were never going
-- to match. A mismatch is reported only when nothing matched, and 'Left'
-- carries every fingerprint the host offered so the log can show them.
selectPinned :: Maybe String -> [String] -> IO (Either [String] [String])
selectPinned Nothing       keyLines = return (Right keyLines)
selectPinned (Just pinned) keyLines = do
  pairs <- mapM (\line -> (,) line <$> fingerprintOf line) keyLines
  let wanted   = trim pinned
      matching = [ line | (line, Just fp) <- pairs, fp == wanted ]
      offered  = [ fp   | (_,    Just fp) <- pairs ]
  return (if null matching then Left offered else Right matching)

-- | @ssh-keygen -l -f -@ reads one key from standard input and prints
-- @\<bits\> SHA256:\<base64\> \<comment\> (\<TYPE\>)@. One key at a time, so
-- the fingerprint is unambiguously the one for that line.
fingerprintOf :: String -> IO (Maybe String)
fingerprintOf keyLine = do
  (code, out, _) <- runTool "ssh-keygen" ["-l", "-f", "-"] (keyLine <> "\n")
  return $ case (code, words out) of
    (ExitSuccess, _bits : fp : _) -> Just fp
    _                             -> Nothing

-- | Append entries, creating the file 0600 if it is missing.
--
-- Never truncates. That is what keeps accept-new from replacing a host whose
-- key changed: the existing entry stays, and the connection fails as it
-- should. 'setFileMode' rather than 'System.Directory.setPermissions', which
-- on POSIX leaves the group and other bits alone.
appendKnownHosts :: FilePath -> [String] -> IO (Either String ())
appendKnownHosts khFile entries = do
  attempt <- try $ do
    createDirectoryIfMissing True (takeDirectory khFile)
    exists <- doesFileExist khFile
    unless exists $ do
      writeFile khFile ""
      setFileMode khFile (unionFileModes ownerReadMode ownerWriteMode)
    appendFile khFile (unlines entries)
  return $ case attempt of
    Right ()                -> Right ()
    Left (e :: IOException) -> Left (show e)

-- | Whether the host is now in the file, which is the only state in which the
-- connection can succeed.
--
-- A constructor added later is refused until it says otherwise.
mayProceed :: Outcome -> Bool
mayProceed AlreadyKnown = True
mayProceed (Added _ _)  = True
mayProceed _            = False

-- | Short tag for the log's message column.
outcomeTag :: Outcome -> String
outcomeTag AlreadyKnown            = "Known host"
outcomeTag (Added _ _)             = "Known host added"
outcomeTag RefusedUnknown          = "Known host error"
outcomeTag (DeclaredUnparseable _) = "Known host error"
outcomeTag (FingerprintMismatch _) = "Known host mismatch"
outcomeTag (ScanFailed _)          = "Known host error"
outcomeTag (WriteFailed _)         = "Known host error"

outcomeDescription :: String -> Integer -> FilePath -> Outcome -> String
outcomeDescription host port khFile outcome = case outcome of
  AlreadyKnown ->
    target <> " is already in " <> khFile
  Added source entries ->
    show (length entries) <> " key(s) for " <> target <> " added to "
      <> khFile <> " from " <> source
  RefusedUnknown ->
    target <> " is not in " <> khFile <> " and hostKeyPolicy is strict; "
      <> "declare hostKeys or allow accept-new"
  DeclaredUnparseable entries ->
    "hostKeys for " <> target <> " could not be read as host keys: "
      <> intercalate ", " entries
  FingerprintMismatch offered ->
    "no key offered by " <> target <> " matched hostKeyFingerprint; offered: "
      <> (if null offered then "nothing" else intercalate ", " offered)
  ScanFailed err ->
    "could not read a host key from " <> target <> ": " <> err
  WriteFailed err ->
    "could not write " <> khFile <> ": " <> err
  where
    target = hostSpec host port

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
