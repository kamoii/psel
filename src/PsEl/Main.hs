{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module PsEl.Main where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Language.PureScript (ModuleName (ModuleName))
import Language.PureScript.CoreFn qualified as P
import Language.PureScript.CoreFn.FromJSON (moduleFromJSON)
import PsEl.PselEl (pselEl)
import PsEl.SExp (Feature (..), featureFileName)
import PsEl.SExpPrinter (displayFeature, displayString)
import PsEl.Transpile (ffiFeatureSuffix, pselFeature, transpile)
import RIO
import RIO.Directory qualified as Dir
import RIO.FilePath ((</>))
import RIO.FilePath qualified as FP
import RIO.List (intersperse, sort)
import RIO.Text (justifyLeft, pack, unpack)
import RIO.Text qualified as T
import System.Exit qualified as Sys
import System.IO (hPutStrLn, putStrLn)
import Text.Pretty.Simple (pPrint, pShow)

defaultMain :: IO ()
defaultMain = do
    let workdir = "."
    let moduleRoot = workdir </> "output"
    let elispRoot = workdir </> "output.el"
    whenM (Dir.doesDirectoryExist elispRoot) $ Dir.removeDirectoryRecursive elispRoot
    Dir.createDirectory elispRoot
    writeFileUtf8 (elispRoot </> featureFileName pselFeature) (pselEl pselFeature)
    moduleDirs <- filter (/= "cache-db.json") <$> Dir.listDirectory moduleRoot
    warngings <- forM moduleDirs $ \rel -> do
        let coreFnPath = moduleRoot </> rel </> "corefn.json"
        value <- Aeson.eitherDecodeFileStrict coreFnPath >>= either Sys.die pure
        (_version, module') <- either Sys.die pure $ parseEither moduleFromJSON value
        handleModule elispRoot module'
    handleWarnings $ mconcat warngings

-- (1) ForeignFileが(provide)を行なっている場合警告を出す必要があるかも。
handleModule :: FilePath -> P.Module P.Ann -> IO [Warning]
handleModule elispRoot module'@P.Module{P.moduleName, P.modulePath} = do
    let feature = transpile module'
    let Feature{name, requireFFI} = feature
    let targetPath = elispRoot </> featureFileName name
    let foreignSourcePath = FP.replaceExtension modulePath "el"
    writeFileUtf8Builder targetPath (displayFeature feature)
    hasForeignSource <- Dir.doesFileExist foreignSourcePath
    case (hasForeignSource, requireFFI) of
        (True, Just ffiName) -> do
            let foreignTargetPath = elispRoot </> featureFileName ffiName
            Dir.copyFile foreignSourcePath foreignTargetPath -- (1)
            pure []
        (True, Nothing) ->
            pure [Left UnneededFFIFileWarning{moduleName, modulePath}]
        (False, Just ffiName) -> do
            let foreignTargetPath = elispRoot </> featureFileName ffiName
            pure
                [ Right
                    MissingFFIFileWarning
                        { moduleName
                        , modulePath
                        , foreignSourcePath
                        , foreignTargetPath
                        }
                ]
        (False, Nothing) ->
            pure []

-- PSコンパイラはpackage-awareではない。そのため当然corefnにはモジュールがどのパッ
-- ケージのどのバージョンのものかの情報は含まれていない。ただspago使っている場合,
-- PSのソースコードのパスでパッケージ名は推測できる。
--
-- 例えばspagoでpreludeをコンパイルした場合,Data.Eqモジュールは次のmodulePathを持つ。
--
-- e.g. "modulePath":".spago/prelude/master/src/Data/Eq.purs"
--
guessPackageByModulePath :: FilePath -> Maybe Text
guessPackageByModulePath path = do
    path' <- T.stripPrefix ".spago/" (pack path)
    let pkg = T.takeWhile (/= '/') path'
    guard $ not (T.null pkg)
    pure pkg

handleWarnings :: [Warning] -> IO ()
handleWarnings warnings = do
    let (unneeds, missings) = partitionEithers warnings
    when (not (null unneeds)) $ putStderrLn $ displayUnneedWarngins unneeds
    when (not (null missings)) $ putStderrLn $ displayMissingWarngins missings

displayUnneedWarngins :: [UnneededFFIFileWarning] -> Utf8Builder
displayUnneedWarngins [] =
    mempty
displayUnneedWarngins warnings =
    mconcat
        . intersperse "\n"
        $ mconcat [header, [""], modules, [""]]
  where
    header =
        [ "!!! WARNING !!!"
        , "These modules contains FFI file but does not use any FFI."
        , "These FFI files are ignored, so no worry, but this could be smell of a bug."
        ]

    modules = map display' warnings

    display' UnneededFFIFileWarning{moduleName = ModuleName mn} =
        display mn

displayMissingWarngins :: [MissingFFIFileWarning] -> Utf8Builder
displayMissingWarngins [] =
    mempty
displayMissingWarngins warnings =
    mconcat
        . intersperse "\n"
        $ mconcat [header, [""], modules, [""]]
  where
    header =
        [ "!!! WARNING !!!"
        , "These modules uses FFI but missing corresponding FFI file."
        , "If you require these module it will fail try requrieing its FFI file."
        , "You can write missing FFI files yourself and place it under emacs's load-path."
        , "For example, for module `Data.Eq`, FFI file should be `Data.Eq" <> display ffiFeatureSuffix <> ".el`"
        ]

    modules =
        map display $ sort $ map displayText' warnings

    displayText' MissingFFIFileWarning{moduleName = ModuleName mn, modulePath, foreignTargetPath} =
        displayColumns
            24
            [ "Package: " <> fromMaybe "--" (guessPackageByModulePath modulePath)
            , "Module: " <> mn
            ]

putStderrLn :: Utf8Builder -> IO ()
putStderrLn ub = hPutBuilder stderr . getUtf8Builder $ ub <> "\n"

displayColumns :: Int -> [Text] -> Text
displayColumns _ [] = mempty
displayColumns width vs =
    mconcat $ mapBut1 (justifyLeft width ' ' . (<> ",")) vs
  where
    mapBut1 :: (a -> a) -> [a] -> [a]
    mapBut1 f [] = []
    mapBut1 f [x] = [x]
    mapBut1 f (x : xs) = f x : mapBut1 f xs

type Warning =
    Either UnneededFFIFileWarning MissingFFIFileWarning

data UnneededFFIFileWarning = UnneededFFIFileWarning
    { moduleName :: ModuleName
    , modulePath :: FilePath
    }

data MissingFFIFileWarning = MissingFFIFileWarning
    { moduleName :: ModuleName
    , modulePath :: FilePath
    , foreignSourcePath :: FilePath
    , foreignTargetPath :: FilePath
    }
