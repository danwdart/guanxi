-- TODO: replace this with auto-discovery
module Main where

import qualified Spec.Cover.DLX
import qualified Spec.Domain.Interval
import qualified Spec.FD.Monad
import qualified Spec.Logic.Reflection
import qualified Spec.Prompt.Iterator
import qualified Spec.Unaligned.Base
import           Test.Hspec.Formatters
import           Test.Hspec.Runner

main :: IO ()
main = hspecWith defaultConfig {configFormatter = Just progress} $ do
  Spec.Cover.DLX.spec
  Spec.Domain.Interval.spec
  Spec.FD.Monad.spec
  Spec.Logic.Reflection.spec
  Spec.Prompt.Iterator.spec
  Spec.Unaligned.Base.spec
