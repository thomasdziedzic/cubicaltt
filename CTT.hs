module CTT where

import Control.Applicative
import Data.List
import Data.Maybe
import Text.PrettyPrint as PP

import Connections

--------------------------------------------------------------------------------
-- | Terms

data Loc = Loc { locFile :: String
               , locPos  :: (Int,Int) }
  deriving Eq

type Binder = (String,Loc)
type Ident  = String
type Label  = String

noLoc :: String -> Binder
noLoc x = (x, Loc "" (0,0))

-- Branch of the form: c x1 .. xn -> e
type Branch = (Label,([Binder],Ter))

-- Telescope (x1 : A1) .. (xn : An)
type Tele   = [(Binder,Ter)]

-- Labelled sum: c (x1 : A1) .. (xn : An)
type LblSum = [(Binder,Tele)]

type Decl   = (Binder,(Ter,Ter))
    
-- Mutual recursive definitions: (x1 : A1) .. (xn : An) and x1 = e1 .. xn = en
type Decls  = [Decl]

declBinders :: Decls -> [Binder]
declBinders decls = [ x | (x,_) <- decls ]

declTers :: Decls -> [Ter]
declTers decls = [ d | (_,(_,d)) <- decls ]

declTele :: Decls -> Tele
declTele decls = [ (x,t) | (x,(t,_)) <- decls ]

declDefs :: Decls -> [(Binder,Ter)]
declDefs decls = [ (x,d) | (x,(_,d)) <- decls ]

-- Terms
data Ter = App Ter Ter
         | Pi Ter
         | Lam Binder Ter Ter
         | Where Ter Decls
         | Var String
         | U
           -- Sigma types:
         | Sigma Ter
         | SPair Ter Ter
         | Fst Ter
         | Snd Ter
           -- constructor c Ms
         | Con Label [Ter]
           -- branches c1 xs1  -> M1,..., cn xsn -> Mn
         | Split Loc Ter [Branch]
           -- labelled sum c1 A1s,..., cn Ans (assumes terms are constructors)
         | Sum Binder LblSum
           -- undefined
         | Undef Loc

           -- Id type
         | IdP Ter Ter Ter
         | Path Name Ter
         | AppFormula Ter Formula
           -- Kan Composition
         | Comp Name Ter Ter (System Ter)
  deriving Eq

-- For an expression t, returns (u,ts) where u is no application and t = u ts
unApps :: Ter -> (Ter,[Ter])
unApps = aux []
  where aux :: [Ter] -> Ter -> (Ter,[Ter])
        aux acc (App r s) = aux (s:acc) r
        aux acc t         = (t,acc)

mkApps :: Ter -> [Ter] -> Ter
mkApps (Con l us) vs = Con l (us ++ vs)
mkApps t ts          = foldl App t ts

mkWheres :: [Decls] -> Ter -> Ter
mkWheres []     e = e
mkWheres (d:ds) e = Where (mkWheres ds e) d

--------------------------------------------------------------------------------
-- | Values

data Val = VU
         | Ter Ter Env
         | VPi Val Val
         | VSigma Val Val
         | VSPair Val Val
         | VCon String [Val]

           -- Id values
         | VIdP Val Val Val
         | VPath Name Val
         | VComp Name Val Val (System Val)
           
           -- Neutral values:
         | VVar String Val
         | VFst Val
         | VSnd Val
         | VSplit Val Val
         | VApp Val Val
         | VAppFormula Val Formula
  deriving Eq

isNeutral :: Val -> Bool
isNeutral v = case v of
  VVar _ _        -> True
  VFst v          -> isNeutral v
  VSnd v          -> isNeutral v
  VSplit _ v      -> isNeutral v
  VApp v _        -> isNeutral v
  VAppFormula v _ -> isNeutral v
  _               -> False

mkVar :: Int -> Val -> Val
mkVar k = VVar ('X' : show k)

--------------------------------------------------------------------------------
-- | Environments

data Env = Empty
         | Pair Env (Binder,Val)
         | PDef Decls Env
  deriving Eq

pairs :: Env -> [(Binder,Val)] -> Env
pairs = foldl Pair

lookupIdent :: Ident -> [(Binder,a)] -> Maybe a
lookupIdent x defs = listToMaybe [ t | ((y,l),t) <- defs, x == y ]

mapEnv :: (Val -> Val) -> Env -> Env
mapEnv _ Empty          = Empty
mapEnv f (Pair e (x,v)) = Pair (mapEnv f e) (x,f v)
mapEnv f (PDef ts e)    = PDef ts (mapEnv f e)

valOfEnv :: Env -> [Val]
valOfEnv Empty            = []
valOfEnv (Pair env (_,v)) = v : valOfEnv env
valOfEnv (PDef _ env)     = valOfEnv env

--------------------------------------------------------------------------------
-- | Pretty printing

instance Show Env where
  show = render . showEnv

showEnv :: Env -> Doc
showEnv e = case e of
  Empty          -> PP.empty
  PDef _ env     -> showEnv env
  Pair env (x,u) -> parens (showEnv1 env <> showVal u)
    where
      showEnv1 (Pair env (x,u)) = showEnv1 env <> showVal u <> text ", "
      showEnv1 e                = showEnv e

instance Show Loc where
  show = render . showLoc

showLoc :: Loc -> Doc
showLoc (Loc name (i,j)) = hcat [text name,text "_L",int i,text "_C",int j]

instance Show Ter where
  show = render . showTer

showTer :: Ter -> Doc
showTer v = case v of
  U                -> char 'U'
  App e0 e1        -> showTer e0 <+> showTer1 e1
  Pi e0            -> text "Pi" <+> showTer e0
  Lam (x,_) t e    -> char '\\' <> text x <+> text "->" <+> showTer e
  Fst e            -> showTer e <> text ".1"
  Snd e            -> showTer e <> text ".2"
  Sigma e0         -> text "Sigma" <+> showTer e0
  SPair e0 e1      -> parens (showTer1 e0 <> comma <> showTer1 e1)
  Where e d        -> showTer e <+> text "where" <+> showDecls d
  Var x            -> text x
  Con c es         -> text c <+> showTers es
  Split l _ _      -> text "split" <+> showLoc l
  Sum (n,l) _      -> text "sum" <+> text n
  Undef _          -> text "undefined"
  IdP e0 e1 e2     -> text "IdP" <+> showTers [e0,e1,e2]
  Path i e         -> char '<' <> text (show i) <> char '>' <+> showTer e
  AppFormula e phi -> showTer1 e <> char '@' <> text (show phi)
  Comp i e0 e1 es  -> text "comp" <+> text (show i) <+> showTers [e0,e1] <+>
                      text (showSystem es)

showTers :: [Ter] -> Doc
showTers = hsep . map showTer1

showTer1 :: Ter -> Doc
showTer1 t = case t of
  U        -> char 'U'
  Con c [] -> text c
  Var x    -> text x
  Split{}  -> showTer t
  Sum{}    -> showTer t
  _        -> parens (showTer t)

showDecls :: Decls -> Doc
showDecls defs = hsep $ punctuate comma
                      [ text x <+> equals <+> showTer d | ((x,_),(_,d)) <- defs ]

instance Show Val where
  show = render . showVal

showVal, showVal1 :: Val -> Doc
showVal v = case v of
  VU                -> char 'U'
  Ter t env         -> showTer t <+> showEnv env
  VCon c us         -> text c <+> showVals us
  VPi a b           -> text "Pi" <+> showVals [a,b]
  VSPair u v        -> parens (showVal1 u <> comma <> showVal1 v)
  VSigma u v        -> text "Sigma" <+> showVals [u,v]
  VApp u v          -> showVal u <+> showVal1 v
  VSplit u v        -> showVal u <+> showVal1 v
  VVar x t          -> text x
  VFst u            -> showVal u <> text ".1"
  VSnd u            -> showVal u <> text ".2"
  VIdP v0 v1 v2     -> text "IdP" <+> showVals [v0,v1,v2]
  VPath i v         -> char '<' <> text (show i) <> char '>' <+> showVal v
  VAppFormula v phi -> showVal1 v <> char '@' <> text (show phi)
  VComp i v0 v1 vs  -> text "comp" <+> text (show i) <+> showVals [v0,v1] <+>
                       text (showSystem vs)
showVal1 v = case v of
  VU        -> char 'U'
  VCon c [] -> text c
  VVar{}    -> showVal v
  _         -> parens (showVal v)

showVals :: [Val] -> Doc
showVals = hsep . map showVal1

