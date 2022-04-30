{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (getNumCapabilities)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BSB
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Char8 as Char8
import Data.ByteString (ByteString)
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import Snap.Core hiding (path, method)
import Snap.Http.Server
import System.IO
import qualified Text.JSON as JSON

import PlayHaskellTypes (Message(..), RunRequest(..), RunResponse(..))
import PlayHaskellTypes.Sign (PublicKey)
import qualified PlayHaskellTypes.Sign as Sign
import Snap.Server.Utils
import Snap.Server.Utils.ExitEarly
import Snap.Server.Utils.Hex
import qualified Snap.Server.Utils.Options as Opt
import Snap.Server.Utils.Shim

import GHCPool


data Context = Context
  { ctxPool :: Pool
  , ctxKnownServers :: [PublicKey] }

data WhatRequest
  = SubmitJob
  deriving (Show)

parseRequest :: Method -> [ByteString] -> Maybe WhatRequest
parseRequest method comps = case (method, comps) of
  (POST, ["job"]) -> Just SubmitJob
  _ -> Nothing

handleRequest :: Context -> WhatRequest -> Snap ()
handleRequest ctx = \case
  SubmitJob -> execExitEarlyT $ do
    -- TODO: check signing keys here

    msg <- getRequestBodyEarlyExitJSON 1000_000 "Program too large"
    let runreq = sesmsgContent msg

    result <- liftIO $ runInPool (ctxPool ctx)
                (runreqCommand runreq)
                (runreqVersion runreq)
                (runreqOpt runreq)
                (runreqSource runreq)
    let response = case result of
          Left err -> RunResponseErr err
          Right res -> RunResponseOk
                         { runresExitCode = resExitCode res
                         , runresStdout = resStdout res
                         , runresStderr = resStderr res
                         , runresTimeTakenSecs = resTimeTaken res }
    
    lift $ modifyResponse (setContentType (Char8.pack "text/json"))
    lift $ writeLBS . BSB.toLazyByteString . BSB.stringUtf8 $ JSON.encode response

splitPath :: ByteString -> Maybe [ByteString]
splitPath path
  | BS.null path || BS.head path /= fromIntegral (ord '/')
  = Nothing
splitPath path = Just (BS.split (fromIntegral (ord '/')) (trimSlashes path))
  where
    trimSlashes :: ByteString -> ByteString
    trimSlashes = let slash = fromIntegral (ord '/')
                  in BS.dropWhile (== slash) . BS.dropWhileEnd (== slash)

server :: Options -> Context -> Snap ()
server options ctx = do
  -- If we're proxied, set the source IP from the X-Forwarded-For header.
  when (oProxied options) ipHeaderFilterSupportingIPv6

  req <- getRequest
  let path = rqContextPath req `BS.append` rqPathInfo req
      method = rqMethod req

  case splitPath path of
    Just components
      | Just what <- parseRequest method components ->
          handleRequest ctx what
      | otherwise ->
          httpError 404 "Path not found"
    Nothing -> httpError 400 "Invalid URL"

config :: Config Snap a
config =
  let stderrlogger = ConfigIoLog (Char8.hPutStrLn stderr)
  in setAccessLog stderrlogger
     . setErrorLog stderrlogger
     . setPort 8124
     $ defaultConfig

data Options = Options { oProxied :: Bool
                       , oSecKeyFile :: FilePath
                       , oServerKeyFile :: FilePath }
  deriving (Show)

defaultOptions :: Options
defaultOptions = Options False "" ""

main :: IO ()
main = do
  options <- Opt.parseOptions $ Opt.Interface defaultOptions $ Map.fromList
    [("--proxied", Opt.Flag
        "Assumes the server is running behind a proxy that sets \
        \X-Forwarded-For, instead of using the source IP of a \
        \request for rate limiting."
        (\o -> o { oProxied = True }))
    ,("--secretkey", Opt.Setter
        "Required. Path to file that contains the secret key \
        \of this worker. The file should contain 32 random bytes \
        \in hexadecimal notation."
        (\o s -> o { oSecKeyFile = s }))
    ,("--serverkeys", Opt.Setter
        "Required. Path to file that contains the public keys of \
        \play-haskell servers that this worker trusts. The \
        \file should contain a number of hexadecimal strings, \
        \each encoding a public key of length 32 bytes."
        (\o s -> o { oServerKeyFile = s }))
    ,("--help", Opt.Help)
    ,("-h", Opt.Help)]

  skey <- Sign.readSecretKey <$> BS.readFile (oSecKeyFile options) >>= \case
            Nothing -> die $ "Cannot open secret key file '" ++ oSecKeyFile options ++ "'"

  nprocs <- getNumCapabilities
  pool <- makePool nprocs
  let ctx = Context pool _

  httpServe config (server options ctx)
