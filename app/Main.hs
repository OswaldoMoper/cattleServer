module Main where

-- import           Data.Text
import           Network.SSH.Client.SimpleSSH
import           System.Exit                  hiding (ExitFailure)
import           System.IO
import           System.Process

path :: String
path = "/home/<remote-user>"

main :: IO ()
main = do
  loginResponse <- runSimpleSSH loginToServer
  case loginResponse of
    Left err      -> do
      hPutStrLn stderr $ "Error: " ++ show err
      exitFailure
    Right session -> do
      putStrLn "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session
      case commandResponse of
        Left err     -> do
          hPutStrLn stderr $ "Error: " ++ show err
          exitFailure
        Right result -> do
          printResponse result "yesod-project.sql created successfully"
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              hPutStrLn stderr $ "Error: " ++ show err
              exitFailure
            Right () -> do
              putStrLn "SSH connection closed"

loginToServer :: SimpleSSH Session
loginToServer = do
  session <- openSession "0.0.0.0" 22 "/home/<user>/.ssh/known_hosts"
  auth_session <- authenticateWithKey session "<remote-user>" "/home/<user>/.ssh/exampleKey-ed25519.pub" "/home/<user>/.ssh/exampleKey-ed25519" ""
  return auth_session

databaseBackupInServer :: Session -> SimpleSSH Result
databaseBackupInServer session = do
  response <- execCommand session $ "pg_dump -U postgres yesod-project > " <> path <> "/backup/yesod-project.sql"
  return response

printResponse :: Result -> String -> IO ()
printResponse res success = do
  case resultExit res of
    ExitFailure 1 -> putStrLn $ show (resultErr res)
    _               -> do
      putStrLn $ show (resultExit res) <> ": " <> success -- resultExit must not print an error
