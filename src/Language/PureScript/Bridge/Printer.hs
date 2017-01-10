{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}

module Language.PureScript.Bridge.Printer where

import           Control.Lens
import           Control.Monad
import           Data.Map.Strict                     (Map)
import qualified Data.Map.Strict                     as Map
import           Data.Monoid
import           Data.Set                            (Set)
import qualified Data.Set                            as Set
import           Data.Text                           (Text)
import qualified Data.Text                           as T
import qualified Data.Text.IO                        as T
import           System.Directory
import           System.FilePath


import           Language.PureScript.Bridge.SumType
import           Language.PureScript.Bridge.TypeInfo


data Module (lang :: Language) = PSModule {
  psModuleName  :: !Text
, psImportLines :: !(Map Text ImportLine)
, psTypes       :: ![SumType lang]
} deriving Show

type PSModule = Module 'PureScript

data ImportLine = ImportLine {
  importModule :: !Text
, importTypes  :: !(Set Text)
} deriving Show

type Modules = Map Text PSModule
type ImportLines = Map Text ImportLine

printModule :: FilePath -> PSModule -> IO ()
printModule root m = do
  unlessM (doesDirectoryExist mDir) $ createDirectoryIfMissing True mDir
  T.writeFile mPath . moduleToText $ m
  where
    mFile = (joinPath . map T.unpack . T.splitOn "." $ psModuleName m) <> ".purs"
    mPath = root </> mFile
    mDir = takeDirectory mPath

sumTypesToNeededPackages :: [SumType lang] -> Set Text
sumTypesToNeededPackages = Set.unions . map sumTypeToNeededPackages

sumTypeToNeededPackages :: SumType lang -> Set Text
sumTypeToNeededPackages st =
  Set.filter (not . T.null) . Set.map _typePackage $ getUsedTypes st

moduleToText :: Module 'PureScript -> Text
moduleToText m = T.unlines $
  "-- File auto generated by purescript-bridge! --"
  : "module " <> psModuleName m <> " where\n"
  : map importLineToText (Map.elems (psImportLines m))
  ++ [ ""
     , "import Prelude"
     , "import Data.Generic (class Generic)"
     , "import Data.Maybe"
     , "import Data.Lens"
     , ""
     ]
  ++ map sumTypeToText (psTypes m)
  where

_lensImports :: [ImportLine]
_lensImports = [
    ImportLine "Data.Maybe" mempty
  , ImportLine "Prelude" mempty
  , ImportLine "Data.Lens" mempty
  ]

importLineToText :: ImportLine -> Text
importLineToText l = "import " <> importModule l <> " (" <> typeList <> ")"
  where
    typeList = T.intercalate ", " (Set.toList (importTypes l))

sumTypeToText :: SumType 'PureScript -> Text
sumTypeToText st@(SumType t cs) = (T.unlines $
    "data " <> typeInfoToText True t <> " ="
  : "    " <> T.intercalate "\n  | " (map (constructorToText 4) cs)
  : [ "\nderive instance generic" <> _typeName t <> " :: " <> genericConstrains <> genericInstance t ])
  <> "\n" <> sep <> "\n" <> sumTypeToPrismsAndLenses st <> sep
  where
    sep = T.replicate 80 "-"
    genericInstance = ("Generic " <>) . typeInfoToText False
    genericConstrains
        | stpLength == 0 = mempty
        | otherwise = (<> " => ") $
            if stpLength == 1
                then genericConstrainsInner
                else bracketWrap genericConstrainsInner
    genericConstrainsInner = T.intercalate ", " $ map genericInstance sumTypeParameters
    stpLength = length sumTypeParameters
    bracketWrap x = "(" <> x <> ")"
    sumTypeParameters = filter isTypeParam . Set.toList $ getUsedTypes st
    isTypeParam typ = _typeName typ `elem` map _typeName (_typeParameters t)

sumTypeToPrismsAndLenses :: SumType 'PureScript -> Text
sumTypeToPrismsAndLenses st = sumTypeToPrisms st <> sumTypeToLenses st

sumTypeToPrisms :: SumType 'PureScript -> Text
sumTypeToPrisms (SumType tName cs) = T.unlines $ map (constructorToPrism moreThan1 typName) cs
  where
    moreThan1 = length cs > 1
    typName = typeInfoToText False tName


sumTypeToLenses :: SumType 'PureScript -> Text
sumTypeToLenses (SumType tName cs) = T.unlines $ recordEntryToLens typName <$> dcName <*> dcRecords
  where
    typName = typeInfoToText False tName
    dcName = lensableConstructor ^.. traversed.sigConstructor
    dcRecords = lensableConstructor ^.. traversed.sigValues._Right.traverse.filtered hasUnderscore
    hasUnderscore e = e ^. recLabel.to (T.isPrefixOf "_")
    lensableConstructor = filter singleRecordCons cs ^? _head
    singleRecordCons (DataConstructor _ (Right _)) = True
    singleRecordCons _                             = False

constructorToText :: Int -> DataConstructor 'PureScript -> Text
constructorToText _ (DataConstructor n (Left ts))  = n <> " " <> T.intercalate " " (map (typeInfoToText False) ts)
constructorToText indentation (DataConstructor n (Right rs)) =
       n <> " {\n"
    <> spaces (indentation + 2) <> T.intercalate intercalation (map recordEntryToText rs) <> "\n"
    <> spaces indentation <> "}"
  where
    intercalation = "\n" <> spaces indentation <> "," <> " "

spaces :: Int -> Text
spaces c = T.replicate c " "


fromEntries :: (RecordEntry a -> Text) -> [RecordEntry a] -> Text
fromEntries mkElem rs = "{ " <> inners <> " }"
  where
    inners = T.intercalate ", " $ map mkElem rs

mkFnArgs :: [RecordEntry 'PureScript] -> Text
mkFnArgs [r] = r ^. recLabel
mkFnArgs rs  = fromEntries (\recE -> recE ^. recLabel <> ": " <> recE ^. recLabel) rs

mkTypeSig :: [RecordEntry 'PureScript] -> Text
mkTypeSig [r] = typeInfoToText False $ r ^. recValue
mkTypeSig rs = fromEntries recordEntryToText rs

constructorToPrism :: Bool -> Text -> DataConstructor 'PureScript -> Text
constructorToPrism otherConstructors tName (DataConstructor n args) =
  case args of
    Left cs  -> pName <> " :: PrismP " <> tName <> " " <> mkTypeSig types <> "\n"
             <> pName <> " = prism' " <> getter cs <> " f\n"
             <> spaces 2 <> "where\n"
             <> spaces 4 <> "f " <> mkF cs
             <> otherConstructorFallThrough
      where
        mkF [] = "_ = Just " <> n
        mkF _  = "(" <> n <> " " <> T.unwords (map _recLabel types) <> ") = Just $ " <> mkFnArgs types <> "\n"
        getter [] = "(_ -> " <> n <> ")"
        getter _  = n
        types = [RecordEntry (T.singleton label) t | (label, t) <- zip ['a'..] cs]
    Right rs -> pName <> " :: PrismP " <> tName <> " { " <> recordSig <> "}\n"
             <> pName <> " = prism' " <> n <> " f\n"
             <> spaces 2 <> "where\n"
             <> spaces 4 <> "f (" <> n <> " r) = Just r\n"
             <> otherConstructorFallThrough
      where
        recordSig = T.intercalate ", " (map recordEntryToText rs)
  where
    pName = "_" <> n
    otherConstructorFallThrough | otherConstructors = spaces 4 <> "f _ = Nothing\n"
                                | otherwise = "\n"

recordEntryToLens :: Text -> Text -> RecordEntry 'PureScript -> Text
recordEntryToLens typName constructorName e =
  case hasUnderscore of
    False -> ""
    True ->
         lensName <> " :: LensP " <> typName <> " " <> recType <> "\n"
      <> lensName <> " = lens get set\n  where\n"
      <> spaces 4 <> "get (" <> constructorName <> " r) = r." <> recName <> "\n"
      <> spaces 4 <> "set (" <> constructorName <> " r) = " <> setter
  where
    setter = constructorName <>  " <<< { " <> recName <> ": _ }\n"
    recName = e ^. recLabel
    lensName = T.drop 1 recName
    recType = typeInfoToText False (e ^. recValue)
    hasUnderscore = e ^. recLabel.to (T.isPrefixOf "_")

recordEntryToText :: RecordEntry 'PureScript -> Text
recordEntryToText e = _recLabel e <> " :: " <> typeInfoToText True (e ^. recValue)


typeInfoToText :: Bool -> PSType -> Text
typeInfoToText topLevel t = if needParens then "(" <> inner <> ")" else inner
  where
    inner = _typeName t <>
      if pLength > 0
        then " " <> T.intercalate " " textParameters
        else ""
    params = _typeParameters t
    pLength = length params
    needParens = not topLevel && pLength > 0
    textParameters = map (typeInfoToText False) params

sumTypesToModules :: Modules -> [SumType 'PureScript] -> Modules
sumTypesToModules = foldr sumTypeToModule

sumTypeToModule :: SumType 'PureScript -> Modules -> Modules
sumTypeToModule st@(SumType t _) = Map.alter (Just . updateModule) (_typeModule t)
  where
    updateModule Nothing = PSModule {
          psModuleName = _typeModule t
        , psImportLines = dropSelf $ typesToImportLines Map.empty (getUsedTypes st)
        , psTypes = [st]
        }
    updateModule (Just m) = m {
        psImportLines = dropSelf $ typesToImportLines (psImportLines m) (getUsedTypes st)
      , psTypes = st : psTypes m
      }
    dropSelf = Map.delete (_typeModule t)

typesToImportLines :: ImportLines -> Set PSType -> ImportLines
typesToImportLines = foldr typeToImportLines

typeToImportLines :: PSType -> ImportLines -> ImportLines
typeToImportLines t ls = typesToImportLines (update ls) (Set.fromList (_typeParameters t))
  where
    update = if not (T.null (_typeModule t))
                then Map.alter (Just . updateLine) (_typeModule t)
                else id

    updateLine Nothing = ImportLine (_typeModule t) (Set.singleton (_typeName t))
    updateLine (Just (ImportLine m types)) = ImportLine m $ Set.insert (_typeName t) types

importsFromList :: [ImportLine] -> Map Text ImportLine
importsFromList ls = let
    pairs = zip (map importModule ls) ls
    merge a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)
  in
    Map.fromListWith merge pairs

mergeImportLines :: ImportLines -> ImportLines -> ImportLines
mergeImportLines = Map.unionWith mergeLines
  where
    mergeLines a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM mbool action = mbool >>= flip unless action
