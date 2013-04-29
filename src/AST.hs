{-# LANGUAGE ViewPatterns              #-}
module Src.AST where

import qualified Data.Map as M
import Control.DeepSeq

type Name = String

-------------
--- Terms ---
-------------
data Variable = DeBr Int 
              | Con Name 
              | Exi Int Name Type -- distance from the top, and type!
              deriving (Eq,Ord)

uncurriedExi ~(a,b,c) = Exi a b c

data P = P :+: N
       | Var Variable
       deriving (Eq, Ord)
                
data N = Abs Type N 
       | Pat P 
       deriving (Eq, Ord)
    
instance Show Variable where
  show (DeBr i) = show i
  show (Exi i n _) = n++"<"++show i++">" -- "("++n++"<"++show i++">:"++show ty++")"
  show (Con n) = n

instance Show P where
  show (viewForallP -> Just (ty,p)) = "( "++show ty ++" ) ~> ( "++ show p++" )"
  show (a :+: b) = show a ++" ( "++ show b++" ) "
  show (Var a) = show a
instance Show N where
  show (Abs ty a) = "λ:"++show ty ++" . ("++ show a++")"
  show (Pat p) = show p


type Term = N
type Type = N

viewForallN (Pat p) = viewForallP p
viewForallN _ = Nothing

viewForallP (Var (Con "#forall#") :+: _ :+: Abs ty n ) = Just (ty,n)
viewForallP _ = Nothing

data Fam = NoFam 
         | Poly 
         | Family Variable 
         deriving (Eq, Show)

getFamily :: N -> Fam
getFamily = getFamily' 0
  where getFamily' i (viewForallN -> Just (_,n)) = getFamily' (i + 1) n
        getFamily' _ Abs{} = NoFam
        getFamily' i (Pat p) = case viewHead p of
          DeBr j -> if j < i 
                    then Poly 
                    else Family $ DeBr $ j - i
          c -> Family c

viewN (viewForallN -> Just (ty,n)) = (ty:l,h)
  where (l,h) = viewN n
viewN (Pat p) = ([],p)
viewN Abs{} = error "can't view an abstraction as a forall"

viewHead (p :+: _) = viewHead p
viewHead (Var v) = v

vvar = Var . DeBr
var = Pat . vvar

evvar :: Int -> Name -> Type -> P
evvar i n t = Var $ Exi i n t

evar :: Int -> Name -> Type -> N
evar i n t = Pat $ Var $ Exi i n t

vcon = Var . Con
con = Pat . vcon

forall ty n = 
  Pat $ vcon "#forall#" :+: ty :+: Abs ty n

a ~> b = forall a b

tipeName = "type"
tipe = con tipeName

type Constants = M.Map Name ((Bool,Int),Type)

constant a = ((False,-1000),a)

constants :: Constants
constants = M.fromList [ (tipeName, constant tipe)
                       , ("#forall#", constant $ forall tipe $ (var 0 ~> tipe) ~> tipe)
                       ]
            
---------------
--- Formula ---
---------------
infixr 2 :&:
infix 3 :=:

data Form = Term :=: Term
          | Term :@: Term
          | Form :&: Form
          | Done
          | Bind Type Form
          deriving Eq
                   
                   

instance Show Form where
  show (t1 :=: t2) = show t1 ++ " ≐ "++ show t2
  show (t1 :&: t2) = " ( "++show t1 ++ " ) ∧ ( "++ show t2++" )"
  show (t1 :@: t2) = " ( "++show t1 ++ " ) ∈ ( "++ show t2++" )"
  show (Bind t1 t2) = " ∀: "++ show t1 ++ " . "++show t2
  show Done = " ⊤ "

instance NFData Form where
  rnf a = rnf $ show a



class TERM n where
  -- addAt (amount,thresh) r increases all variables referencing above the threshold down by amount
  addAt :: (Int,Int) -> n -> n
  
instance TERM Variable where  
  addAt (amount,thresh) (DeBr a) = DeBr $ if   a <= thresh 
                                          then a 
                                          else amount + a
  addAt i (Exi j nm ty) = Exi j nm $ addAt i ty
  addAt _ a = a
  
instance TERM P where  
  addAt i (Var a) = Var $ addAt i a
  addAt i (p :+: n) = addAt i p :+: addAt i n
instance TERM N where  
  addAt v@(amount,thresh) (Abs ty n) = Abs (addAt v ty) $ addAt (amount, thresh+1) n
  addAt i (Pat p) = Pat $ addAt i p

instance TERM Form where
  addAt v@(amount,thresh) (Bind ty n) = Bind (addAt v ty) $ addAt (amount, thresh+1) n
  addAt i (p :=: n) = addAt i p :=: addAt i n
  addAt i (p :&: n) = addAt i p :&: addAt i n
  addAt i (p :@: n) = addAt i p :@: addAt i n
  addAt _ Done = Done
  
liftV :: TERM n => Int -> n -> n
liftV v = addAt (v,-1) 
