{-|
Copyright   : (c) 2007, Commonwealth Scientific and Industrial Research Organisation
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.Socket (
    ConnectConfig(..)
  , Connect(..)
  , connect
  , AcceptConfig(..)
  , Accept(..)
  , accept
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (forever, void)

import Control.Monad.Trans (MonadIO(..))

import Network.Socket hiding (connect, accept)
import qualified Network.Socket as NS

import Reflex

data ConnectConfig =
  ConnectConfig {
    _ccHostname :: Maybe String
  , _ccPort     :: Maybe String
  }

data Connect t =
  Connect {
    _cSocket :: Event t Socket
  , _cError  :: Event t String
  }

connect ::
  ( Reflex t
  , PerformEvent t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  ) =>
  ConnectConfig ->
  m (Connect t)
connect (ConnectConfig mHost mPort) = do
  (eSocket, onSocket) <- newTriggerEvent
  (eError, onError)   <- newTriggerEvent

  -- TODO go through and catch all of the relevant exceptions
  addrInfos <- liftIO $ getAddrInfo Nothing mHost mPort
  case addrInfos of
    [] -> liftIO $ onError "no address found"
    h : _ -> liftIO $ do
      sock <- socket (addrFamily h) Stream defaultProtocol
      NS.connect sock (addrAddress h)
      onSocket sock

  pure $ Connect eSocket eError

data AcceptConfig t =
  AcceptConfig {
    _acHostname    :: Maybe String
  , _acPort        :: Maybe String
  , _acListenQueue :: Int
  , _acClose       :: Event t ()
  }

data Accept t =
  Accept {
    _aListenSocket :: Event t Socket
  , _aListenClosed :: Event t ()
  , _aAcceptSocket :: Event t (Socket, SockAddr)
  , _aError        :: Event t String
  }

accept ::
  ( Reflex t
  , PerformEvent t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  ) =>
  AcceptConfig t ->
  m (Accept t)
accept (AcceptConfig mHost mPort listenQueue _) = do
  (eListenSocket, onListenSocket) <- newTriggerEvent
  (eAcceptSocket, onAcceptSocket) <- newTriggerEvent
  (eError, onError)   <- newTriggerEvent

  -- TODO add support for closing / detecting the close of the listen socket

  -- TODO go through and catch all of the relevant exceptions
  addrinfos <- liftIO $ getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) mHost mPort
  case addrinfos of
    [] -> liftIO $ onError "no address found"
    h : _ -> liftIO $ do
      sock <- socket (addrFamily h) Stream defaultProtocol
      bind sock (addrAddress h)
      listen sock listenQueue
      onListenSocket sock
      void . forkIO . forever $ do
        conn <- NS.accept sock
        onAcceptSocket conn

  pure $ Accept eListenSocket never eAcceptSocket eError