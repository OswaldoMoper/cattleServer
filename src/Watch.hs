{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Asking whether a site is up, in a way that says which part of it is not.
--
-- A name and the machine behind it fail separately, and only comparing them
-- says which. Everything here answers that question and nothing else: it takes
-- no backups and reads no configuration.
module Watch
  ( Verdict (..)
  , verdictTag
  , verdictDescription
  , isTrouble
  , checkSite
  ) where

import           Control.Exception     (IOException, try)
import qualified Data.ByteString.Char8 as C8
import           Data.List             (intercalate, nub)
import           Data.Maybe            (catMaybes)
import           Network.HTTP.Client   (HttpException (..), Manager, Request,
                                        httpNoBody, parseRequest, redirectCount,
                                        requestHeaders, responseStatus)
import           Network.HTTP.Types    (statusCode)
import           Network.Socket        (AddrInfo (..), NameInfoFlag (..),
                                        SockAddr, SocketType (Stream),
                                        defaultHints, getAddrInfo, getNameInfo)
import           System.IO.Error       (ioeGetErrorString)

-- | What the site turned out to be doing. One constructor per person who
-- would have to act on it.
data Verdict
  = NameDoesNotResolve String
  -- ^ The name is out of its zone: expired, suspended, or the zone is gone.
  -- Whoever holds the registrar account.
  | ResolvesElsewhere [String] [String]
  -- ^ Expected addresses, then the ones it actually answers with. The zone
  -- changed, or something was put in front. Whoever holds the DNS.
  | NameDoesNotAnswer String
  -- ^ It resolves and the machine answers, but the name does not. The edge:
  -- a proxy, a certificate, a firewall.
  | AddressDoesNotAnswer String
  -- ^ Not the machine either. Whoever operates it.
  | SiteIsUp Int
  -- ^ The status the name returned.
  deriving (Eq, Show)

-- | Whether a verdict is one somebody has to do something about.
isTrouble :: Verdict -> Bool
isTrouble (SiteIsUp code) = code >= 400
isTrouble _               = True

verdictTag :: Verdict -> String
verdictTag (SiteIsUp code) | code < 400 = "Site up"
verdictTag _                            = "Site error"

verdictDescription :: String -> String -> Verdict -> String
verdictDescription url addr verdict = case verdict of
  NameDoesNotResolve err ->
    url <> " does not resolve: " <> err
      <> " -- the name is out of its zone, which is the registrar's to fix"
  ResolvesElsewhere want got ->
    url <> " resolves to " <> list got <> ", not to " <> list want
      <> " -- the zone changed, or something was put in front of it"
  NameDoesNotAnswer err ->
    url <> " resolves but does not answer: " <> err
      <> " -- the machine does, so this is the edge"
  AddressDoesNotAnswer err ->
    addr <> " does not answer either: " <> err <> " -- this one is the machine"
  SiteIsUp code ->
    url <> " answered " <> show code
  where
    list [] = "nothing"
    list xs = intercalate ", " xs

-- | Ask the name, then ask the address, and say which of the two failed.
--
-- The address has to be the machine that serves this URL, or the half of the
-- verdict that talks about the machine is about a different one.
checkSite :: Manager -> String -> String -> Maybe [String] -> IO Verdict
checkSite manager url addr expected = do
  resolved <- addressesOf (hostOf url)
  case resolved of
    Left err -> return (NameDoesNotResolve err)
    Right [] -> return (NameDoesNotResolve "no addresses")
    Right got -> case expected of
      Just want | not (any (`elem` want) got) -> return (ResolvesElsewhere want got)
      _ -> do
        byName <- getStatus manager url id
        case byName of
          Right code -> return (SiteIsUp code)
          Left nameErr -> do
            byAddr <- machineAnswers manager addr (hostOf url)
            return $ case byAddr of
              Right _      -> NameDoesNotAnswer nameErr
              Left addrErr -> AddressDoesNotAnswer addrErr

-- | Whether the machine itself answers, asked without TLS.
--
-- A certificate is issued to the name and never to the address, so asking the
-- address over HTTPS fails however healthy the machine is, and would blame it
-- for whatever the edge is doing. Plain HTTP asks the one thing this needs to
-- know. Redirects are not followed: a 301 to the name is the machine
-- answering, and following it would put the name back under test.
--
-- Its limit: a machine that serves only 443 is reported as not answering.
machineAnswers :: Manager -> String -> String -> IO (Either String Int)
machineAnswers manager addr host =
  getStatus manager ("http://" <> addr <> "/") (noRedirects . withHost host)

-- | The addresses a name answers with, or why it answers with none.
addressesOf :: String -> IO (Either String [String])
addressesOf host = do
  let hints = defaultHints { addrSocketType = Stream }
  attempt <- try (getAddrInfo (Just hints) (Just host) Nothing)
  case attempt of
    Left e      -> return (Left (ioeGetErrorString (e :: IOException)))
    Right infos -> Right . nub . catMaybes <$> mapM (numeric . addrAddress) infos

-- | One socket address written the way people write addresses.
numeric :: SockAddr -> IO (Maybe String)
numeric sockAddr = do
  named <- try (getNameInfo [NI_NUMERICHOST] True False sockAddr)
  return $ case named of
    Right (host, _)         -> host
    Left (_ :: IOException) -> Nothing

-- | The status a request comes back with, or why it did not come back.
getStatus :: Manager -> String -> (Request -> Request) -> IO (Either String Int)
getStatus manager url adjust = do
  attempt <- try (parseRequest url >>= \req -> httpNoBody (adjust req) manager)
  return $ case attempt of
    Left e         -> Left (describeHttp e)
    Right response -> Right (statusCode (responseStatus response))

-- | Ask the address for a named site, rather than for whichever it serves by
-- default.
withHost :: String -> Request -> Request
withHost host req =
  req { requestHeaders = ("Host", C8.pack host) : requestHeaders req }

noRedirects :: Request -> Request
noRedirects req = req { redirectCount = 0 }

-- | The part of an HTTP failure worth putting in an alert: the exception's own
-- rendering carries the whole request with it, which buries the reason.
describeHttp :: HttpException -> String
describeHttp (HttpExceptionRequest _ content) = firstLine (show content)
describeHttp (InvalidUrlException url why)    = url <> ": " <> why

hostOf :: String -> String
hostOf = takeWhile (\c -> c /= '/' && c /= ':') . dropScheme
  where
    dropScheme s
      | take 8 s == "https://" = drop 8 s
      | take 7 s == "http://"  = drop 7 s
      | otherwise              = s

firstLine :: String -> String
firstLine s = case filter (not . null) (lines s) of
  (l:_) -> take 200 l
  []    -> "no message"
