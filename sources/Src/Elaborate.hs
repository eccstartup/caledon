{-# LANGUAGE  
 ViewPatterns
 #-}
module Src.Elaborate (typeConstraints) where

import Src.Variables
import Src.AST 
import Src.Context
import Src.FormulaSequence
import Src.Substitution
import Data.Functor
import Control.Monad.RWS.Lazy (RWS, ask, local, censor, runRWS, censor, tell, get, put, listen, lift)
import Control.Monad.State.Class (MonadState(), get, modify)
import Control.Spoon
import Data.Monoid

type TypeChecker = RWS Ctxt Form Int

typeConstraints cons tm ty = evalGen (do new <- Pat <$> getNewExists "@head" ty
                                         genConstraintN tm new ty
                                         return new
                                     ) cons

evalGen m cons = do
  s <- get 
  let ~(a,s',f) = runRWS m (emptyCon cons) s
  put s'
  return (a,f)

getNewExists :: String -> Type -> TypeChecker P
getNewExists s ty = do
  nm <- getNewWith s
  depth <- height <$> ask 
  return $ Var $ Exi depth nm ty

getNewExists' :: String -> Type -> TypeChecker P
getNewExists' s ty = do
  nm <- getNewWith s
  depth <- height <$> ask 
  return $ Var $ Exi (max 0 $ depth - 1) nm ty  
  
bindForall :: Type -> TypeChecker a -> TypeChecker a  
bindForall ty = censor (bind ty) . local (\a -> putTy a ty)

(.=.) a b  = tell $ a :=: b
(.<.) a b  = tell $ a :<: b
(.<=.) a b = tell $ a :<=: b
(.@.) a b  = tell $ a :@: b

getNewTyVar :: String -> TypeChecker P
getNewTyVar t = do
  v <- getNewWith "@tmake"
  getNewExists t (tipemake v)

genConstraintN :: N -> N -> Type -> TypeChecker ()
genConstraintN n n' ty = case n of
  Abs tyAorg sp -> do
    tyA <- getNewTyVar "@tyA"
    genConstraintTy tyAorg tyA

    case viewForallP ty of
      Just ~(tyA',tyF') -> do
        Pat tyA .=. Pat tyA'
        bindForall tyA $ 
          genConstraintN sp (appN' (liftV 1 n') $ var 0) tyF'
      _ -> do 
        v1 <- getNewWith "@tmake1"
        e <- getNewExists "@e" (forall (liftV 1 tyA) $ tipemake v1)
        let body = e :+: var 0
        Pat (forall tyA body) .<=. Pat ty
        bindForall tyA $ 
          genConstraintN sp (appN' (liftV 1 n') $ var 0) body
      
  Pat p -> do
    p' <- getNewExists "@spB" ty
    ty' <- genConstraintP p p'
    Pat p' .=. n'
    Pat ty' .<=. Pat ty

genConstraintTy :: Type -> Type -> TypeChecker ()
genConstraintTy p r = do
  ~b <- genConstraintP p r
  v1 <- getNewWith "@tmake0"
  Pat b .=. Pat (tipemake v1)
  
genConstraintP :: P -> P -> TypeChecker Type
genConstraintP p p' = case p of 

  (viewForallP -> Just ~(tyAorg,tyF)) -> do

    tyA <- getNewTyVar "@tyA"
    tyAty <- genConstraintP tyAorg tyA
    
    tyret <- tipemake <$> getNewWith "@maketipe"
    Pat tyAty .<=. Pat tyret
    
    tyFf' <- (getNewExists "@fbody" . forall tyA . tipemake) =<< getNewWith "@tmakeF"
    bindForall tyA $ do
      tyFty <- genConstraintP tyF (tyFf' :+: var 0)
      Pat tyFty .<=. Pat tyret
      
    Pat (forall tyA $ tyFf' :+: var 0) .=. Pat p'
    
    return tyret
  (tipeView -> Init v1) -> do
    v2 <- getNewWith "@tmakeA"
    Pat (tipemake v1) .<. Pat (tipemake v2)
    Pat (tipemake v1) .=. Pat p'
    return $ tipemake v2

  (tipeView -> Uninit) -> do
    v1 <- getNewWith "@tmakeB"
    v2 <- getNewWith "@tmakeC"
    Pat (tipemake v1) .<. Pat (tipemake v2)
    Pat (tipemake v1) .=. Pat p'
    return $ tipemake v2

  forg :+: vorg -> do
    tyArg <- getNewTyVar "@ftyArg"
    tyVal <- getNewWith "@ftyValmake"
    tyBody <- getNewExists "@ftyBody" (tyArg ~> tipemake tyVal)
    
    let tyF' = tyArg ~> (tyBody :+: var 0)
    f   <- getNewExists "@fex" tyF'
    
    tyF <- genConstraintP forg f
    Pat tyF .<=. Pat tyF' 
    
    v <- Pat <$> getNewExists "@tyV" tyArg
        
    genConstraintN vorg v tyArg
    Pat (f :+: v) .=. Pat p'
    return $ tyBody :+: v
    
  Var (Con "#hole#") -> do
    v <- getNewWith   "@tmakeF"
    ty <- getNewExists' "@xty" $ tipemake v
    e  <- getNewExists "@xinH" ty
    Pat e .=. Pat p'
    return ty

  Var a -> do
    ctxt <- ask
    getVal ctxt a .=. Pat p'
    
    -- what the ever loving FUCK???
    return $ liftV 1 $ getTy ctxt a 
    
    -- I just need to share the graph!!!!
    -- Then I only have to generate variable names once!
    -- unfortunately, this means that the graph might become GIANT!
    -- which is bad.
    -- Fortunately, it might be the case that the graph is either
    -- always highly disconnected or highly connected.
