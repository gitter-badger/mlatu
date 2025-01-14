module Test.InstanceCheck
  ( spec,
  )
where

import Mlatu.Informer (errorCheckpoint)
import Mlatu.InstanceCheck (instanceCheck)
import Mlatu.Kind (Kind (..))
import Mlatu.Monad (runMlatuExceptT)
import Mlatu.Name (Qualified (..))
import Mlatu.Origin qualified as Origin
import Mlatu.Pretty (printType)
import Mlatu.Type (Type (..), TypeId (..), Var (..))
import Mlatu.Type qualified as Type
import Mlatu.Vocabulary qualified as Vocabulary
import Prettyprinter (hsep)
import Relude hiding (Type)
import Test.Common (Sign (..))
import Test.HUnit (assertBool)
import Test.Hspec (Spec, it)

spec :: Spec
spec = do
  it "with concrete types" $ do
    --    Int
    -- <: Int
    testInstanceCheck Positive int int

    --    <T> (T)
    -- <: Int
    testInstanceCheck Positive (fx x) int

    --    [R..., T, +P] (R... -> R..., T +P)
    -- <: [R..., +P]    (R... -> R..., Int +P)
    testInstanceCheck
      Positive
      (fr $ fe $ fx $ Type.fun o r (Type.prod o r x) e)
      (fr $ fe $ Type.fun o r (Type.prod o r int) e)

  it "with parameterized types" $ do
    --    [A, B] (Pair[A, B])
    -- <: [A]    (Pair[A, A])
    testInstanceCheck
      Positive
      (fx $ fy $ pair :@ x :@ y)
      (fx $ pair :@ x :@ x)

    --     <A, B> (Pair<A, B> -> Pair<B, A>)
    -- </: <A, B> (Pair<A, B> -> Pair<A, B>)
    testInstanceCheck
      Negative
      ( fr $
          fx $
            fy $
              fe $
                Type.fun
                  o
                  (Type.prod o r (pair :@ x :@ y))
                  (Type.prod o r (pair :@ y :@ x))
                  e
      )
      ( fr $
          fx $
            fy $
              fe $
                Type.fun
                  o
                  (Type.prod o r (pair :@ x :@ y))
                  (Type.prod o r (pair :@ x :@ y))
                  e
      )
  where
    o = Origin.point "" 0 0
    r = TypeVar o rv
    x = TypeVar o xv
    y = TypeVar o yv
    e = TypeVar o ev
    rv = Var "R" (TypeId 0) Stack
    xv = Var "X" (TypeId 2) Value
    yv = Var "Y" (TypeId 3) Value
    ev = Var "P" (TypeId 4) Permission
    fr = Type.Forall o rv
    fx = Type.Forall o xv
    fy = Type.Forall o yv
    fe = Type.Forall o ev
    ctor =
      TypeConstructor o . Type.Constructor
        . Qualified Vocabulary.global
    int = ctor "Int"
    pair = ctor "Pair"

testInstanceCheck :: Sign -> Type -> Type -> IO ()
testInstanceCheck sign a b = do
  result <- runMlatuExceptT $ do
    instanceCheck "polymorphic" a "concrete" b
    errorCheckpoint
  case sign of
    Positive ->
      assertBool (show $ hsep [printType a, "<:", printType b]) $
        isRight result
    Negative ->
      assertBool (show $ hsep [printType a, "</:", printType b]) $
        isLeft result
