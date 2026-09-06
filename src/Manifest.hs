{-# LANGUAGE ScopedTypeVariables #-}

-- | Recording what a backup contained, so it can be checked later.
--
-- Writing a backup proves it arrived. It does not prove it is still there a
-- month on: a disk can return a different byte than the one it was given, and
-- nothing notices until someone tries to restore. A manifest turns that into
-- something answerable.
--
-- The format is the one @sha256sum@ writes and reads, so a manifest can be
-- checked with @sha256sum -c@ by hand, without this program.
module Manifest
  ( manifestName
  , writeManifest
  , verifyManifest
  , filesUnder
  ) where

import           Control.Exception     (IOException, try)
import qualified Crypto.Hash.SHA256    as SHA256
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Lazy  as BL
import           Data.List             (sort)
import           System.Directory      (doesDirectoryExist, listDirectory)
import           System.Posix.Files    (getSymbolicLinkStatus, isDirectory,
                                        isRegularFile)
import           Text.Printf           (printf)

-- | Name of the manifest inside a backup directory.
manifestName :: String
manifestName = "manifest.sha256"

-- | Every regular file under a directory, as paths relative to it, sorted.
--
-- Sorted so that two manifests of the same tree are byte-identical, which is
-- what makes them comparable by eye as well as by machine. Symlinks are
-- skipped: they carry no content of their own to check.
filesUnder :: FilePath -> IO [FilePath]
filesUnder root = sort <$> go ""
  where
    go relative = do
      let here = case relative of
            "" -> root
            _  -> root <> "/" <> relative
      entries <- listDirectory here
      concat <$> mapM (classify relative) entries

    classify relative entry = do
      let rel  = case relative of
            "" -> entry
            _  -> relative <> "/" <> entry
          full = root <> "/" <> rel
      attempt <- try (getSymbolicLinkStatus full)
      case attempt of
        Left (_ :: IOException) -> return []
        Right status
          | isRegularFile status -> return [rel]
          | isDirectory status   -> go rel
          | otherwise            -> return []

-- | Hash one file. Lazily, so a 70 MB dump is not held in memory at once.
hashFile :: FilePath -> IO (Either String String)
hashFile path = do
  attempt <- try (SHA256.hashlazy <$> BL.readFile path)
  return $ case attempt of
    Right digest            -> Right (toHex digest)
    Left (e :: IOException) -> Left (show e)

toHex :: BS.ByteString -> String
toHex = concatMap (printf "%02x") . BS.unpack

-- | Write a manifest of everything in a backup directory.
--
-- Returns how many files it covers. The manifest excludes itself, so it can
-- be rewritten without the count drifting.
writeManifest :: FilePath -> IO (Either String Int)
writeManifest dir = do
  present <- doesDirectoryExist dir
  case present of
    False -> return (Left (dir <> " is not there"))
    True  -> do
      paths  <- filter (/= manifestName) <$> filesUnder dir
      hashed <- mapM (\rel -> fmap ((,) rel) (hashFile (dir <> "/" <> rel))) paths
      case [ (rel, err) | (rel, Left err) <- hashed ] of
        ((rel, err):_) -> return (Left ("could not read " <> rel <> ": " <> err))
        []             -> do
          let body = unlines [ digest <> "  " <> rel | (rel, Right digest) <- hashed ]
          written <- try (writeFile (dir <> "/" <> manifestName) body)
          return $ case written of
            Right ()                -> Right (length hashed)
            Left (e :: IOException) -> Left (show e)

-- | Check a backup against its own manifest.
--
-- Returns how many files were checked and which ones no longer match. A file
-- that has gone missing counts as a mismatch, since the manifest says it
-- should be there.
verifyManifest :: FilePath -> IO (Either String (Int, [FilePath]))
verifyManifest dir = do
  loaded <- try (readFile (dir <> "/" <> manifestName))
  case loaded of
    Left (e :: IOException) -> return (Left (show e))
    Right body -> do
      let entries = [ (rel, digest)
                    | line <- lines body
                    , Just (digest, rel) <- [splitEntry line] ]
      results <- mapM check entries
      return (Right (length entries, concat results))
  where
    check (rel, expected) = do
      actual <- hashFile (dir <> "/" <> rel)
      return $ case actual of
        Right d | d == expected -> []
        _                       -> [rel]

-- | One @sha256sum@ line: the digest, two spaces, then the path.
splitEntry :: String -> Maybe (String, String)
splitEntry line = case splitAt 64 line of
  (digest, ' ' : ' ' : rel) | length digest == 64 && not (null rel) -> Just (digest, rel)
  _                                                                -> Nothing
