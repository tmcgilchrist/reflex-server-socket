{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
module Reflex.Server.Socket (
    SocketConfig(..)
  , scInitSocket
  , scMaxRx
  , scSend
  , scClose
  , Socket(..)
  , sRecieve
  , sOpen
  , sError
  , sClosed
  , socket
  , module Reflex.Server.Socket.Connect
  , module Reflex.Server.Socket.Accept
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (when, void)
import Data.Foldable (forM_)

import Control.Exception (IOException, catch, displayException)

import Control.Monad.Trans (MonadIO(..))

import Control.Monad.STM
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM.TQueue

import Control.Lens

import qualified Data.ByteString as B

import Network.Socket hiding (Socket, socket, send, sendTo, recv, recvFrom)
import qualified Network.Socket as NS
import Network.Socket.ByteString

import Reflex

import Reflex.Binary

import Reflex.Server.Socket.Connect
import Reflex.Server.Socket.Accept

data SocketConfig t a =
  SocketConfig {
    _scInitSocket :: NS.Socket
  , _scMaxRx      :: Int
  , _scSend       :: Event t [a]
  , _scClose      :: Event t ()
  }

makeLenses ''SocketConfig

data Socket t b =
  Socket {
    _sRecieve :: Event t b
  , _sOpen    :: Event t ()
  , _sError   :: Event t String
  , _sClosed  :: Event t ()
  }

makeLenses ''Socket

socket ::
  forall t m a b.
  ( Reflex t
  , PerformEvent t m
  , PostBuild t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  , CanEncode a
  , CanDecode b
  ) =>
  SocketConfig t a ->
  m (Socket t b)
socket (SocketConfig initSock mxRx eTx eClose) = mdo
  (eRx, onRx) <- newTriggerEvent
  (eOpen, onOpen) <- newTriggerEvent
  (eError, onError) <- newTriggerEvent
  (eClosed, onClosed) <- newTriggerEvent

  payloadQueue <- liftIO newTQueueIO
  closeQueue <- liftIO . atomically $ newEmptyTMVar
  isOpenRead <- liftIO . atomically $ newEmptyTMVar
  isOpenWrite <- liftIO . atomically $ newEmptyTMVar

  ePostBuild <- getPostBuild

  let
    exHandlerClose :: IOException -> IO ()
    exHandlerClose =
      onError . displayException

    exHandlerTx :: IOException -> IO Bool
    exHandlerTx e = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \_ -> onError (displayException e)
      pure False

    txLoop = do
      let
        stmTx = do
          mSock <- tryReadTMVar isOpenWrite
          case mSock of
            Nothing -> pure (Left Nothing)
            Just sock -> do
              bs <- readTQueue payloadQueue
              pure $ Right (sock, bs)
        stmClose = do
          mSock <- tryReadTMVar isOpenWrite
          case mSock of
            Nothing -> pure (Left Nothing)
            Just sock -> do
              _ <- takeTMVar closeQueue
              pure (Left (Just sock))
      e <- atomically $ stmClose `orElse` stmTx
      case e of
        Right (sock, bs) -> do
          success <- (sendAll sock (doEncode bs) >> pure True) `catch` exHandlerTx
          when success txLoop
        Left (Just sock) -> do
          void . atomically . tryTakeTMVar $ isOpenWrite
          void . atomically . tryTakeTMVar $ isOpenRead
          close sock `catch` exHandlerClose
          onClosed ()
        Left Nothing ->
          txLoop

    startTxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpenWrite
      forM_ mSock $ \_ -> void . forkIO $ txLoop


  let
    exHandlerRx :: IOException -> IO B.ByteString
    exHandlerRx e = do
      mSock <- atomically . tryReadTMVar $ isOpenRead
      forM_ mSock $ \_ -> onError (displayException e)
      pure B.empty

    shutdownRx = do
      void . atomically $ tryTakeTMVar isOpenRead
      onClosed ()

    rxLoop decoder = do
      mSock <- atomically $ tryReadTMVar isOpenRead
      forM_ mSock $ \sock -> do
        bs <- recv sock mxRx `catch` exHandlerRx

        if B.null bs
        then shutdownRx
        else runIncrementalDecoder onError onRx (const shutdownRx) rxLoop decoder bs

    startRxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpenRead
      forM_ mSock $ const . void . forkIO . rxLoop $ getDecoder

  performEvent_ $ ffor eTx $ \payloads -> liftIO $ forM_ payloads $
    atomically . writeTQueue payloadQueue

  performEvent_ $ ffor eClose $ \_ ->
    liftIO . atomically . putTMVar closeQueue $ ()

  let
    start = liftIO $ do
      void . atomically . tryPutTMVar isOpenRead $ initSock
      void . atomically . tryPutTMVar isOpenWrite $ initSock
      startTxLoop
      startRxLoop
      onOpen ()
      pure ()

  performEvent_ $ start <$ ePostBuild

  pure $ Socket eRx eOpen eError eClosed
