{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RoleAnnotations            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}

-- |
-- Copyright :  (c) Edward Kmett 2018-2019
-- License   :  BSD-2-Clause OR Apache-2.0
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable

module Signal
  ( Signal(..)
  , MonadSignal
  , newSignal
  , newSignal_
  , fire, scope
  , Signals
  , HasSignals(..)
  , ground
  , grounding
  , propagate
  , multiplicity -- report an externally indistinguishable result multiple times
  , infiniteMultiplicity
  , currentMultiplicity
  -- * implementation
  , HasSignalEnv(signalEnv)
  , SignalEnv
  , newSignalEnv
  ) where

import           Control.Lens
import           Control.Monad              (guard, unless)
import           Control.Monad.Primitive
import           Control.Monad.Reader.Class
import           Data.Foldable              as Foldable
import           Data.Function              (on)
import           Data.Hashable
import           Data.HashSet               as HashSet
import           Data.Kind
import           Data.Proxy
import           Ref
import           Unique

type Signals m = HashSet (Signal m)
type Propagators m = HashSet (Propagator m)

data Propagator m = Propagator
  { propagatorAction           :: m () -- TODO: return if we should self-delete, e.g. if all inputs are covered by contradiction
  , _propSources, _propTargets :: !(Signals m) -- TODO: added for future topological analysis
  , propagatorId               :: {-# unpack #-} !(UniqueM m)
  }

instance Eq (Propagator m) where
  (==) = (==) `on` propagatorId

instance Hashable (Propagator m) where
  hash = hash . propagatorId
  hashWithSalt d = hashWithSalt d . propagatorId

class HasSignals m t | t -> m where
  signals :: t -> Signals m

instance (m ~ n) => HasSignals m (Proxy n) where
  signals = mempty

instance (m ~ n) => HasSignals m (Signals n) where
  signals = id

data Signal (m :: Type -> Type) = Signal
  { signalId        :: UniqueM m
  , signalReference :: RefM m (Propagators m)
  }

instance Eq (Signal m) where
  (==) = (==) `on` signalId

instance Hashable (Signal m) where
  hash = hash . signalId
  hashWithSalt d = hashWithSalt d . signalId

data SignalEnv m = SignalEnv
  { _signalEnvSafety    :: !Bool
  , _signalEnvPending   :: !(RefM m (Propagators m)) -- pending propagators
  , _signalEnvGround    :: !(RefM m (m ())) -- final grounding action
  , _signalMultiplicity :: !(RefM m Integer) -- count of occurrences of a given solution
  }

makeClassy ''SignalEnv

type MonadSignal e m = (MonadRef m, MonadReader e m, HasSignalEnv e m)

newSignalEnv :: (PrimMonad n, Monad m, PrimState m ~ PrimState n) => n (SignalEnv m)
newSignalEnv = SignalEnv False <$> newRef mempty <*> newRef (pure ()) <*> newRef 1

instance (s ~ PrimState m) => Reference s (Propagators m) (Signal m) where
  reference = signalReference

instance HasSignals m (Signal m) where
  signals = HashSet.singleton

newSignal_ :: PrimMonad m => m (Signal m)
newSignal_ = Signal <$> newUnique <*> newRef mempty

infiniteMultiplicity :: MonadSignal e m => m ()
infiniteMultiplicity = do
  mult <- view signalMultiplicity
  writeRef mult 0 -- abuse 0 * anything = 0 = anything * 0 to use 0 as infinity

multiplicity :: MonadSignal e m => Integer -> m ()
multiplicity n = do
  guard (n /= 0) -- blow up now, we're _actually_ repeating 0 times
  mult <- view signalMultiplicity
  modifyRef mult (*n)

-- returns the current multiplicity as Nothing if the current solution is repeated an infinite number of times
-- and Just n if the current solution is going to be repeated n times.
currentMultiplicity :: MonadSignal e m => m (Maybe Integer)
currentMultiplicity = do
  mult <- view signalMultiplicity
  n <- readRef mult
  pure $ n <$ guard (n /= 0)

grounding :: MonadSignal e m => m () -> m ()
grounding strat = do
  g <- view signalEnvGround
  modifyRef' g (*> strat)

newSignal :: MonadSignal e m => (Signal m -> m ()) -> m (Signal m)
newSignal strat = do
  s <- newSignal_
  s <$ grounding (strat s)

scope :: MonadSignal e m => m a -> m a
scope m = do
    a <- local (signalEnvSafety .~ True) m
    SignalEnv s p _ _ <- view signalEnv
    a <$ unless s (go p)
  where
    go p = do
      hs <- updateRef p (,mempty)
      for_ hs propagatorAction
      unless (HashSet.null hs) (go p)

fire :: (MonadSignal e m, HasSignals m v) => v -> m ()
fire v = scope $ do
  p <- view signalEnvPending
  for_ (signals v) $ \i -> do
    ps <- readRef i
    unless (HashSet.null ps) $ modifyRef' p (<> ps) -- we could do this with a single write at the end of the scope

propagate
  :: (MonadSignal e m, HasSignals m x, HasSignals m y)
  => x -- ^ sources
  -> y -- ^ targets
  -> m () -- ^ propagator action
  -> m ()
propagate (signals -> cs) (signals -> ds) act = do
  p <- Propagator act cs ds <$> newUnique
  for_ (HashSet.toList cs) $ \c -> modifyRef' c (HashSet.insert p)

ground :: MonadSignal e m => m ()
ground = do
  g <- view signalEnvGround
  join readRef g
