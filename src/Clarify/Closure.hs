module Clarify.Closure
  ( makeClosure
  , callClosure
  , chainTermPlus
  , chainTermPlus''
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.List

import Clarify.Linearize
import Clarify.Sigma
import Clarify.Utility
import Data.Basic
import Data.Code
import Data.Env
import Data.Term

import qualified Data.Map.Strict as Map

makeClosure ::
     Maybe Identifier -- the name of newly created closure
  -> [(Identifier, CodePlus)] -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  -> Meta -- meta of lambda
  -> [(Identifier, CodePlus)] -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  -> CodePlus -- the `e` in `lam (x1, ..., xn). e`
  -> WithEnv CodePlus
makeClosure mName xts2 m xts1 e = do
  expName <- newNameWith "exp"
  envExp <- cartesianSigma expName m $ map Right xts2
  (envVarName, envVar) <- newDataUpsilonWith "env"
  e' <- linearize (xts2 ++ xts1) e
  cenv <- gets codeEnv
  name <- nameFromMaybe mName
  let args = envVarName : map fst xts1
  let body = (m, CodeSigmaElim xts2 envVar e')
  when (name `notElem` map fst cenv) $ insCodeEnv name args body
  let fvEnv = (m, DataSigmaIntro $ map (toDataUpsilon' . fst) xts2)
  let cls = (m, DataSigmaIntro [envExp, fvEnv, (m, DataTheta name)])
  return (m, CodeUpIntro cls)

callClosure ::
     Meta -> CodePlus -> [(Identifier, CodePlus, DataPlus)] -> WithEnv CodePlus
callClosure m e zexes = do
  let (zs, es', xs) = unzip3 zexes
  (clsVarName, clsVar) <- newDataUpsilonWith "closure"
  (typeVarName, typeVar) <- newDataUpsilonWith "exp"
  (envVarName, envVar) <- newDataUpsilonWith "env"
  (lamVarName, lamVar) <- newDataUpsilonWith "thunk"
  affVarName <- newNameWith "aff"
  relVarName <- newNameWith "rel"
  retUnivType <- returnCartesianUniv
  retImmType <- returnCartesianImmediate
  return $
    bindLet
      ((clsVarName, e) : zip zs es')
      ( m
      , CodeSigmaElim
          [ (typeVarName, retUnivType)
          , (envVarName, returnUpsilon typeVarName)
          , (lamVarName, retImmType)
          ]
          clsVar
          ( m
          , CodeSigmaElim
              [(affVarName, retImmType), (relVarName, retImmType)]
              typeVar
              (m, CodePiElimDownElim lamVar (envVar : xs))))

nameFromMaybe :: Maybe Identifier -> WithEnv Identifier
nameFromMaybe mName =
  case mName of
    Just lamThetaName -> return lamThetaName
    Nothing -> newNameWith "thunk"

chainTermPlus :: TermPlus -> WithEnv [(Identifier, TermPlus)]
chainTermPlus e = do
  tmp <- chainTermPlus' e
  return $ nubBy (\(x, _) (y, _) -> x == y) tmp

chainTermPlus' :: TermPlus -> WithEnv [(Identifier, TermPlus)]
chainTermPlus' (_, TermTau) = return []
chainTermPlus' (_, TermUpsilon x) = do
  t <- lookupTypeEnv x
  xts <- chainWithName x t
  return $ xts ++ [(x, t)]
chainTermPlus' (_, TermPi xts t) = chainTermPlus'' xts [t]
chainTermPlus' (_, TermPiIntro xts e) = chainTermPlus'' xts [e]
chainTermPlus' (_, TermPiElim e es) = do
  xs1 <- chainTermPlus' e
  xs2 <- concat <$> mapM (chainTermPlus') es
  return $ xs1 ++ xs2
chainTermPlus' (_, TermMu xt e) = chainTermPlus'' [xt] [e]
chainTermPlus' (_, TermConst x) = do
  t <- lookupTypeEnv x
  chainWithName x t
chainTermPlus' (_, TermConstDecl xt e) = chainTermPlus'' [xt] [e]
chainTermPlus' (_, TermIntS _ _) = return []
chainTermPlus' (_, TermIntU _ _) = return []
chainTermPlus' (_, TermFloat16 _) = return []
chainTermPlus' (_, TermFloat32 _) = return []
chainTermPlus' (_, TermFloat64 _) = return []
chainTermPlus' (_, TermEnum _) = return []
chainTermPlus' (_, TermEnumIntro _) = return []
chainTermPlus' (_, TermEnumElim e les) = do
  xs1 <- chainTermPlus' e
  let es = map snd les
  xs2 <- concat <$> mapM (chainTermPlus') es
  return $ xs1 ++ xs2
chainTermPlus' (_, TermArray _ indexType) = chainTermPlus' indexType
chainTermPlus' (_, TermArrayIntro _ les) = do
  let es = map snd les
  concat <$> mapM (chainTermPlus') es
chainTermPlus' (_, TermArrayElim _ e1 e2) = do
  xs1 <- chainTermPlus' e1
  xs2 <- chainTermPlus' e2
  return $ xs1 ++ xs2

chainTermPlus'' ::
     [(Identifier, TermPlus)] -> [TermPlus] -> WithEnv [(Identifier, TermPlus)]
chainTermPlus'' [] es = concat <$> mapM (chainTermPlus') es
chainTermPlus'' ((x, t):xts) es = do
  xs1 <- chainTermPlus' t
  insTypeEnv x t
  xs2 <- chainTermPlus'' xts es
  return $ xs1 ++ filter (\(y, _) -> y /= x) xs2

-- assuming the type of `x` is `t`, obtain the closed chain of the type of `x`.
-- if the chain is computed for the first time, this function caches the computed result.
-- if not, use the cached result.
chainWithName :: Identifier -> TermPlus -> WithEnv [(Identifier, TermPlus)]
chainWithName x t = do
  cenv <- gets chainEnv
  case Map.lookup x cenv of
    Just xts -> return xts -- use cached result
    Nothing -> do
      xts <- chainTermPlus' t
      modify (\env -> env {chainEnv = Map.insert x xts cenv})
      return xts