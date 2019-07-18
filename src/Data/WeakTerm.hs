{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}

module Data.WeakTerm where

import           Control.Comonad.Cofree
import           Control.Monad          (forM)
import           Data.Maybe             (fromMaybe)
import           Text.Show.Deriving

import           Data.Basic

type IdentifierPlus = (Identifier, WeakTerm)

data WeakLevel
  = WeakLevelInt Int
  | WeakLevelHole Identifier
  deriving (Show, Eq)

data WeakTermF a
  = WeakTermUniv WeakLevel
  | WeakTermUpsilon Identifier
  | WeakTermEpsilon Identifier
  | WeakTermEpsilonIntro Literal
  | WeakTermEpsilonElim (Identifier, a)
                        a
                        [(Case, a)]
  | WeakTermPi [(Identifier, a)]
  | WeakTermPiIntro [(Identifier, a)]
                    a
  | WeakTermPiElim a
                   [a]
  | WeakTermSigma [(Identifier, a)]
  | WeakTermSigmaIntro [a]
  | WeakTermSigmaElim [(Identifier, a)]
                      a
                      a
  | WeakTermTau a
  | WeakTermTauIntro a
  | WeakTermTauElim a
  | WeakTermTheta a
  | WeakTermThetaIntro a
  | WeakTermThetaElim a
  | WeakTermMu (Identifier, a)
               a
  | WeakTermIota a
                 WeakLevel
  | WeakTermConst Identifier
  | WeakTermHole Identifier

type WeakTerm = Cofree WeakTermF Identifier

$(deriveShow1 ''WeakTermF)

type SubstWeakTerm = [(Identifier, WeakTerm)]

varWeakTerm :: WeakTerm -> [Identifier]
varWeakTerm e = fst $ varAndHole e

varAndHole :: WeakTerm -> ([Identifier], [Identifier])
varAndHole (_ :< WeakTermUniv _) = ([], [])
varAndHole (_ :< WeakTermUpsilon x) = ([x], [])
varAndHole (_ :< WeakTermEpsilon _) = ([], [])
varAndHole (_ :< WeakTermEpsilonIntro _) = ([], [])
varAndHole (_ :< WeakTermEpsilonElim (x, t) e branchList) = do
  let xhs1 = varAndHole t
  let xhs2 = varAndHole e
  xhss <-
    forM branchList $ \(_, body) -> do
      let (xs, hs) = varAndHole body
      return (filter (/= x) xs, hs)
  pairwiseConcat (xhs1 : xhs2 : xhss)
varAndHole (_ :< WeakTermPi txs) = varAndHoleBindings txs []
varAndHole (_ :< WeakTermPiIntro txs e) = varAndHoleBindings txs [e]
varAndHole (_ :< WeakTermPiElim e es) =
  pairwiseConcat $ varAndHole e : map varAndHole es
varAndHole (_ :< WeakTermSigma txs) = varAndHoleBindings txs []
varAndHole (_ :< WeakTermSigmaIntro es) = pairwiseConcat $ map varAndHole es
varAndHole (_ :< WeakTermSigmaElim us e1 e2) =
  pairwiseConcat [varAndHole e1, varAndHoleBindings us [e2]]
varAndHole (_ :< WeakTermMu ut e) = varAndHoleBindings [ut] [e]
varAndHole (_ :< WeakTermConst _) = ([], [])
varAndHole (_ :< WeakTermHole x) = ([], [x])

varAndHoleBindings ::
     [IdentifierPlus] -> [WeakTerm] -> ([Identifier], [Identifier])
varAndHoleBindings [] es = pairwiseConcat $ map varAndHole es
varAndHoleBindings ((x, t):txs) es = do
  let (xs1, hs1) = varAndHole t
  let (xs2, hs2) = varAndHoleBindings txs es
  (xs1 ++ filter (/= x) xs2, hs1 ++ hs2)

pairwiseConcat :: [([a], [b])] -> ([a], [b])
pairwiseConcat [] = ([], [])
pairwiseConcat ((xs, ys):rest) = do
  let (xs', ys') = pairwiseConcat rest
  (xs ++ xs', ys ++ ys')

substWeakTerm :: SubstWeakTerm -> WeakTerm -> WeakTerm
substWeakTerm _ (j :< WeakTermUniv i) = j :< WeakTermUniv i
substWeakTerm sub (j :< WeakTermUpsilon x) =
  fromMaybe (j :< WeakTermUpsilon x) (lookup x sub)
substWeakTerm _ (j :< WeakTermEpsilon x) = j :< WeakTermEpsilon x
substWeakTerm _ (j :< WeakTermEpsilonIntro l) = j :< WeakTermEpsilonIntro l
substWeakTerm sub (j :< WeakTermEpsilonElim (x, t) e branchList) = do
  let t' = substWeakTerm sub t
  let e' = substWeakTerm sub e
  let (caseList, es) = unzip branchList
  let sub' = filter (\(k, _) -> k /= x) sub
  let es' = map (substWeakTerm sub') es
  j :< WeakTermEpsilonElim (x, t') e' (zip caseList es')
substWeakTerm sub (j :< WeakTermPi txs) = do
  let txs' = substWeakTermBindings sub txs
  j :< WeakTermPi txs'
substWeakTerm sub (j :< WeakTermPiIntro txs body) = do
  let (txs', body') = substWeakTermBindingsWithBody sub txs body
  j :< WeakTermPiIntro txs' body'
substWeakTerm sub (j :< WeakTermPiElim e es) = do
  let e' = substWeakTerm sub e
  let es' = map (substWeakTerm sub) es
  j :< WeakTermPiElim e' es'
substWeakTerm sub (j :< WeakTermSigma txs) = do
  let txs' = substWeakTermBindings sub txs
  j :< WeakTermSigma txs'
substWeakTerm sub (j :< WeakTermSigmaIntro es) = do
  let es' = map (substWeakTerm sub) es
  j :< WeakTermSigmaIntro es'
substWeakTerm sub (j :< WeakTermSigmaElim txs e1 e2) = do
  let e1' = substWeakTerm sub e1
  let (txs', e2') = substWeakTermBindingsWithBody sub txs e2
  j :< WeakTermSigmaElim txs' e1' e2'
substWeakTerm sub (j :< WeakTermMu (x, t) e) = do
  let t' = substWeakTerm sub t
  let e' = substWeakTerm (filter (\(k, _) -> k /= x) sub) e
  j :< WeakTermMu (x, t') e'
substWeakTerm _ (j :< WeakTermConst t) = j :< WeakTermConst t
substWeakTerm sub (j :< WeakTermHole s) =
  fromMaybe (j :< WeakTermHole s) (lookup s sub)

substWeakTermBindings :: SubstWeakTerm -> [IdentifierPlus] -> [IdentifierPlus]
substWeakTermBindings _ [] = []
substWeakTermBindings sub ((x, t):txs) = do
  let sub' = filter (\(k, _) -> k /= x) sub
  let txs' = substWeakTermBindings sub' txs
  (x, substWeakTerm sub t) : txs'

substWeakTermBindingsWithBody ::
     SubstWeakTerm
  -> [IdentifierPlus]
  -> WeakTerm
  -> ([IdentifierPlus], WeakTerm)
substWeakTermBindingsWithBody sub [] e = ([], substWeakTerm sub e)
substWeakTermBindingsWithBody sub ((x, t):txs) e = do
  let sub' = filter (\(k, _) -> k /= x) sub
  let (txs', e') = substWeakTermBindingsWithBody sub' txs e
  ((x, substWeakTerm sub t) : txs', e')

isReducible :: WeakTerm -> Bool
isReducible (_ :< WeakTermUniv _) = False
isReducible (_ :< WeakTermUpsilon _) = False
isReducible (_ :< WeakTermEpsilon _) = False
isReducible (_ :< WeakTermEpsilonIntro _) = False
isReducible (_ :< WeakTermEpsilonElim _ (_ :< WeakTermEpsilonIntro l) branchList) = do
  let (caseList, _) = unzip branchList
  CaseLiteral l `elem` caseList || CaseDefault `elem` caseList
isReducible (_ :< WeakTermEpsilonElim (_, _) e _) = isReducible e
isReducible (_ :< WeakTermPi _) = False
isReducible (_ :< WeakTermPiIntro _ _) = False
isReducible (_ :< WeakTermPiElim (_ :< WeakTermPiIntro txs _) es)
  | length txs == length es = True
isReducible (_ :< WeakTermPiElim (_ :< WeakTermMu _ _) _) = True -- CBV recursion
isReducible (_ :< WeakTermPiElim (_ :< WeakTermConst c) [_ :< WeakTermEpsilonIntro (LiteralInteger _), _ :< WeakTermEpsilonIntro (LiteralInteger _)]) -- constant application
  | c `elem` intArithConstantList = True
isReducible (_ :< WeakTermPiElim e es) = isReducible e || any isReducible es
isReducible (_ :< WeakTermSigma _) = False
isReducible (_ :< WeakTermSigmaIntro es) = any isReducible es
isReducible (_ :< WeakTermSigmaElim txs (_ :< WeakTermSigmaIntro es) _)
  | length txs == length es = True
isReducible (_ :< WeakTermSigmaElim _ e1 _) = isReducible e1
isReducible (_ :< WeakTermMu _ _) = False
isReducible (_ :< WeakTermConst _) = False
isReducible (_ :< WeakTermHole _) = False

toWeakTermPiElimSeq :: WeakTerm -> (WeakTerm, [(Identifier, [WeakTerm])])
toWeakTermPiElimSeq (i :< WeakTermPiElim e es) = do
  let (fun, xs) = toWeakTermPiElimSeq e
  (fun, xs ++ [(i, es)])
toWeakTermPiElimSeq c = (c, [])

isValue :: WeakTerm -> Bool
isValue (_ :< WeakTermUniv _)         = True
isValue (_ :< WeakTermUpsilon _)      = True
isValue (_ :< WeakTermEpsilon _)      = True
isValue (_ :< WeakTermEpsilonIntro _) = True
isValue (_ :< WeakTermPi {})          = True
isValue (_ :< WeakTermPiIntro _ _)    = True
isValue (_ :< WeakTermSigma {})       = True
isValue (_ :< WeakTermSigmaIntro es)  = all isValue es
isValue _                             = False
