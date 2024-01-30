module Main where

import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Control.Monad.IO.Class
import           System.Process
import           Yesod.Core.Types

main :: IO ()
main = putStrLn "Hello, Haskell!"

writeLocally :: String -> String -> FileInfo -> Handler FilePath
writeLocally path name file = do
  let filename = path ++ "/" ++ name
  liftIO $ callCommand $ "mkdir" ++ path
  liftIO $ fileMove file filename
  return filename
