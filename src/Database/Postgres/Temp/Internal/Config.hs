{-# OPTIONS_HADDOCK prune #-}
{-| This module provides types and functions for combining partial
    configs into a complete configs to ultimately make a 'CompletePlan'.

    This module has two classes of types.

    Types like 'ProcessConfig' that could be used by any
    library that  needs to combine process options.

    Finally it has types and functions for creating 'CompletePlan's that
    use temporary resources. This is used to create the default
    behavior of 'Database.Postgres.Temp.startConfig' and related
    functions.
|-}
module Database.Postgres.Temp.Internal.Config where

import Database.Postgres.Temp.Internal.Core

import           Control.Applicative.Lift
import           Control.DeepSeq
import           Control.Exception
import           Control.Monad (join)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Maybe
import           Data.Monoid
import           Data.Monoid.Generic
import qualified Database.PostgreSQL.Simple.Options as Client
import           GHC.Generics (Generic)
import           Network.Socket.Free (getFreePort)
import           System.Directory
import           System.Environment
import           System.IO
import           System.IO.Error
import           System.IO.Temp (createTempDirectory)
import           System.IO.Unsafe (unsafePerformIO)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

prettyMap :: (Pretty a, Pretty b) => Map a b -> Doc
prettyMap theMap =
  let xs = Map.toList theMap
  in vsep $ map (uncurry prettyKeyPair) xs

-- | The environment variables can be declared to
--   inherit from the running process or they
--   can be specifically added.
--
--   @since 1.12.0.0
data EnvironmentVariables = EnvironmentVariables
  { inherit  :: Last Bool
  , specific :: Map String String
  }
  deriving stock (Generic, Show, Eq)

instance Semigroup EnvironmentVariables where
  x <> y = EnvironmentVariables
    { inherit  =
        inherit x <> inherit y
    , specific =
        specific y <> specific x
    }

instance Monoid EnvironmentVariables where
  mempty = EnvironmentVariables mempty mempty

instance Pretty EnvironmentVariables where
  pretty EnvironmentVariables {..}
    = text "inherit:"
        <+> pretty (getLast inherit)
    <> hardline
    <> text "specific:"
    <> softline
    <> indent 2 (prettyMap specific)

-- | Combine the current environment
--   (if indicated by 'inherit')
--   with 'specific'.
--
--   @since 1.12.0.0
completeEnvironmentVariables
  :: [(String, String)]
  -> EnvironmentVariables
  -> Either [String] [(String, String)]
completeEnvironmentVariables envs EnvironmentVariables {..} = case getLast inherit of
  Nothing -> Left ["Inherit not specified"]
  Just x -> Right $ (if x then envs else [])
    <> Map.toList specific

-- | A type to help combine command line Args.
--
--   @since 1.12.0.0
data CommandLineArgs = CommandLineArgs
  { keyBased   :: Map String (Maybe String)
  -- ^ Args of the form @-h foo@, @--host=foo@ and @--switch@.
  --   The key is `mappend`ed with value so the key should include
  --   the space or equals (as shown in the first two examples
  --   respectively).
  --   The 'Dual' monoid is used so the last key wins.
  , indexBased :: Map Int String
  -- ^ Args that appear at the end of the key based
  --   Args.
  --   The 'Dual' monoid is used so the last key wins.
  }
  deriving stock (Generic, Show, Eq)
  deriving Monoid via GenericMonoid CommandLineArgs

instance Semigroup CommandLineArgs where
  x <> y = CommandLineArgs
    { keyBased   =
        keyBased y <> keyBased x
    , indexBased =
        indexBased y <> indexBased x
    }

instance Pretty CommandLineArgs where
  pretty p@CommandLineArgs {..}
    = text "keyBased:"
    <> softline
    <> indent 2 (prettyMap keyBased)
    <> hardline
    <> text "indexBased:"
    <> softline
    <> indent 2 (prettyMap indexBased)
    <> hardline
    <> text "completed:" <+> text (unwords (completeCommandLineArgs p))

-- Take values as long as the index is the successor of the
-- last index.
takeWhileInSequence :: [(Int, a)] -> [a]
takeWhileInSequence ((0, x):xs) = x : go 0 xs where
  go _ [] = []
  go prev ((next, a):rest)
    | prev + 1 == next = a : go next rest
    | otherwise = []
takeWhileInSequence _ = []

-- | This convert the 'CommandLineArgs' to '[String]'.
--
--   @since 1.12.0.0
completeCommandLineArgs :: CommandLineArgs -> [String]
completeCommandLineArgs CommandLineArgs {..}
  =  map (\(name, mvalue) -> maybe name (name <>) mvalue)
       (Map.toList keyBased)
  <> takeWhileInSequence (Map.toList indexBased)

-- | Process configuration
--
--   @since 1.12.0.0
data ProcessConfig = ProcessConfig
  { environmentVariables :: EnvironmentVariables
  -- ^ A monoid for combine environment variables or replacing them.
  --   for the maps the 'Dual' monoid is used. So the last key wins.
  , commandLine :: CommandLineArgs
  -- ^ A monoid for combine command line Args or replacing them.
  , stdIn :: Last Handle
  -- ^ A monoid for configuring the standard input 'Handle'.
  , stdOut :: Last Handle
  -- ^ A monoid for configuring the standard output 'Handle'.
  , stdErr :: Last Handle
  -- ^ A monoid for configuring the standard error 'Handle'.
  }
  deriving stock (Generic, Eq, Show)
  deriving Semigroup via GenericSemigroup ProcessConfig
  deriving Monoid    via GenericMonoid ProcessConfig

prettyHandle :: Handle -> Doc
prettyHandle _ = text "[HANDLE]"

instance Pretty ProcessConfig where
  pretty ProcessConfig {..}
    = text "environmentVariables:"
    <> softline
    <> indent 2 (pretty environmentVariables)
    <> hardline
    <> text "commandLine:"
    <> softline
    <> indent 2 (pretty environmentVariables)
    <> hardline
    <> text "stdIn:" <+>
        pretty (prettyHandle <$> getLast stdIn)
    <> hardline
    <> text "stdOut:" <+>
        pretty (prettyHandle <$> getLast stdOut)
    <> hardline
    <> text "stdErr:" <+>
        pretty (prettyHandle <$> getLast stdErr)


-- | The 'standardProcessConfig' sets the handles to 'stdin', 'stdout' and
--   'stderr' and inherits the environment variables from the calling
--   process.
--
--   @since 1.12.0.0
standardProcessConfig :: ProcessConfig
standardProcessConfig = mempty
  { environmentVariables = mempty
      { inherit = pure True
      }
  , stdIn  = pure stdin
  , stdOut = pure stdout
  , stdErr = pure stderr
  }

-- | A global reference to @/dev/null@ 'Handle'.
--
--   @since 1.12.0.0
devNull :: Handle
devNull = unsafePerformIO (openFile "/dev/null" WriteMode)
{-# NOINLINE devNull #-}

-- | 'silentProcessConfig' sets the handles to @/dev/null@ and
--   inherits the environment variables from the calling process.
--
--   @since 1.12.0.0
silentProcessConfig :: ProcessConfig
silentProcessConfig = mempty
  { environmentVariables = mempty
      { inherit = pure True
      }
  , stdIn  = pure devNull
  , stdOut = pure devNull
  , stdErr = pure devNull
  }

-- A helper to add more info to all the error messages.
addErrorContext :: String -> Either [String] a -> Either [String] a
addErrorContext cxt = either (Left . map (cxt <>)) Right

-- A helper for creating an error if a 'Last' is not defined.
getOption :: String -> Last a -> Errors [String] a
getOption optionName = \case
    Last (Just x) -> pure x
    Last Nothing  -> failure ["Missing " ++ optionName ++ " option"]

-- | Turn a 'ProcessConfig' into a 'ProcessConfig'. Fails if
--   any values are missing.
--
--   @since 1.12.0.0
completeProcessConfig
  :: [(String, String)] -> ProcessConfig -> Either [String] CompleteProcessConfig
completeProcessConfig envs ProcessConfig {..} = runErrors $ do
  let completeProcessConfigCmdLine = completeCommandLineArgs commandLine
  completeProcessConfigEnvVars <- eitherToErrors $
    completeEnvironmentVariables envs environmentVariables
  completeProcessConfigStdIn  <-
    getOption "stdIn" stdIn
  completeProcessConfigStdOut <-
    getOption "stdOut" stdOut
  completeProcessConfigStdErr <-
    getOption "stdErr" stdErr

  pure CompleteProcessConfig {..}

-- | A type to track whether a file is temporary and needs to be cleaned up.
--
--   @since 1.12.0.0
data CompleteDirectoryType = CPermanent FilePath | CTemporary FilePath
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NFData)

-- | Get the file path of a 'CompleteDirectoryType', regardless if it is a
-- 'CPermanent' or 'CTemporary' type.
--
--   @since 1.12.0.0
toFilePath :: CompleteDirectoryType -> FilePath
toFilePath = \case
  CPermanent x -> x
  CTemporary x -> x

instance Pretty CompleteDirectoryType where
  pretty = \case
    CPermanent x -> text "CPermanent" <+> pretty x
    CTemporary x -> text "CTemporary" <+> pretty x

makePermanent :: CompleteDirectoryType -> CompleteDirectoryType
makePermanent = \case
  CTemporary x -> CPermanent x
  x -> x

-- | Used to specify a 'Temporary' folder that is automatically
--   cleaned up or a 'Permanent' folder which is not
--   automatically cleaned up.
--
--   @since 1.12.0.0
data DirectoryType
  = Permanent FilePath
  -- ^ A permanent file that should not be generated.
  | Temporary
  -- ^ A temporary file that needs to generated.
  deriving(Show, Eq, Ord)

instance Pretty DirectoryType where
  pretty = \case
    Permanent x -> text "Permanent" <+> pretty x
    Temporary   -> text "Temporary"

-- | Takes the last 'Permanent' value.
instance Semigroup DirectoryType where
  x <> y = case (x, y) of
    (a, Temporary     ) -> a
    (_, a@Permanent {}) -> a

-- | 'Temporary' as 'mempty'
instance Monoid DirectoryType where
  mempty = Temporary

-- | Either create a'CTemporary' directory or do nothing to a 'CPermanent'
--   one.
--
--   @since 1.12.0.0
setupDirectoryType
  :: String
  -- ^ Temporary directory configuration
  -> String
  -- ^ Directory pattern
  -> DirectoryType
  -> IO CompleteDirectoryType
setupDirectoryType tempDir pat = \case
  Temporary -> CTemporary <$> createTempDirectory tempDir pat
  Permanent x  -> CPermanent <$> case x of
    '~':rest -> do
      homeDir <- getHomeDirectory
      pure $ homeDir <> "/" <> rest
    xs -> pure xs

-- Remove a temporary directory and ignore errors
-- about it not being there.
rmDirIgnoreErrors :: FilePath -> IO ()
rmDirIgnoreErrors mainDir = do
  let ignoreDirIsMissing e
        | isDoesNotExistError e = return ()
        | otherwise = throwIO e
  -- I'm trying to prevent new files getting added
  -- to the dir as I am deleting the files.
  let newName = mainDir <> "_removing"
  handle ignoreDirIsMissing $ uninterruptibleMask_ $ do
    renameDirectory mainDir newName
    removeDirectoryRecursive newName

-- | Either remove a 'CTemporary' directory or do nothing to a 'CPermanent'
-- one.
cleanupDirectoryType :: CompleteDirectoryType -> IO ()
cleanupDirectoryType = \case
  CPermanent _ -> pure ()
  CTemporary filePath -> rmDirIgnoreErrors filePath

-- | @postgres@ process config and corresponding client connection
--   'Client.Options'.
--
--   @since 1.12.0.0
data PostgresPlan = PostgresPlan
  { postgresConfig :: ProcessConfig
  -- ^ Monoid for the @postgres@ ProcessConfig.
  , connectionOptions :: Client.Options
  -- ^ Monoid for the @postgres@ client connection options.
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup PostgresPlan
  deriving Monoid    via GenericMonoid PostgresPlan

instance Pretty PostgresPlan where
  pretty PostgresPlan {..}
    = text "postgresConfig:"
    <> softline
    <> indent 2 (pretty postgresConfig)
    <> hardline
    <> text "connectionOptions:"
    <> softline
    <> indent 2 (prettyOptions connectionOptions)

-- | Turn a 'PostgresPlan' into a 'CompletePostgresPlan'. Fails if any
--   values are missing.
completePostgresPlan :: [(String, String)] -> PostgresPlan -> Either [String] CompletePostgresPlan
completePostgresPlan envs PostgresPlan {..} = runErrors $ do
  let completePostgresPlanClientOptions = connectionOptions
  completePostgresPlanProcessConfig <-
    eitherToErrors $ addErrorContext "postgresConfig: " $
      completeProcessConfig envs postgresConfig

  pure CompletePostgresPlan {..}
-------------------------------------------------------------------------------
-- Plan
-------------------------------------------------------------------------------
-- | Describe how to run @initdb@, @createdb@ and @postgres@
--
--   @since 1.12.0.0
data Plan = Plan
  { logger :: Last Logger
  , initDbConfig :: Maybe ProcessConfig
  , createDbConfig :: Maybe ProcessConfig
  , postgresPlan :: PostgresPlan
  , postgresConfigFile :: [String]
  , dataDirectoryString :: Last String
  , connectionTimeout :: Last Int
  -- ^ Max time to spend attempting to connection to @postgres@.
  --   Time is in microseconds.
  , initDbCache :: Last (Maybe (Bool, FilePath))
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup Plan
  deriving Monoid    via GenericMonoid Plan

instance Pretty Plan where
  pretty Plan {..}
    =  text "initDbConfig:"
    <> softline
    <> indent 2 (pretty initDbConfig)
    <> hardline
    <> text "initDbConfig:"
    <> softline
    <> indent 2 (pretty createDbConfig)
    <> hardline
    <> text "postgresPlan:"
    <> softline
    <> indent 2 (pretty postgresPlan)
    <> hardline
    <> text "postgresConfigFile:"
    <> softline
    <> indent 2 (vsep $ map text postgresConfigFile)
    <> hardline
    <> text "dataDirectoryString:" <+> pretty (getLast dataDirectoryString)
    <> hardline
    <> text "connectionTimeout:" <+> pretty (getLast connectionTimeout)
    <> hardline
    <> text "initDbCache:" <+> pretty (getLast initDbCache)

-- | Turn a 'Plan' into a 'CompletePlan'. Fails if any values are missing.
completePlan :: [(String, String)] -> Plan -> Either [String] CompletePlan
completePlan envs Plan {..} = runErrors $ do
  completePlanLogger   <- getOption "logger" logger
  completePlanInitDb   <- eitherToErrors $ addErrorContext "initDbConfig: " $
    traverse (completeProcessConfig envs) initDbConfig
  completePlanCreateDb <- eitherToErrors $ addErrorContext "createDbConfig: " $
    traverse (completeProcessConfig envs) createDbConfig
  completePlanPostgres <- eitherToErrors $ addErrorContext "postgresPlan: " $
    completePostgresPlan envs postgresPlan
  let completePlanConfig = unlines postgresConfigFile
  completePlanDataDirectory <- getOption "dataDirectoryString"
    dataDirectoryString
  completePlanConnectionTimeout <- getOption "connectionTimeout"
    connectionTimeout
  completePlanCacheDirectory <- getOption "initDbCache"
    initDbCache

  pure CompletePlan {..}

-- Returns 'True' if the 'Plan' has a
-- 'Just' 'initDbConfig'.
hasInitDb :: Plan -> Bool
hasInitDb Plan {..} = isJust initDbConfig

-- Returns 'True' if the 'Plan' has a
-- 'Just' 'createDbConfig'.
hasCreateDb :: Plan -> Bool
hasCreateDb Plan {..} = isJust createDbConfig

-- | The high level options for overriding default behavior.
--
--   @since 1.15.0.0
data Config = Config
  { plan    :: Plan
  -- ^ Extend or replace any of the configuration used to create a final
  --   'CompletePlan'.
  , socketDirectory  :: DirectoryType
  -- ^ Override the default temporary UNIX socket directory by setting this.
  , dataDirectory :: DirectoryType
  -- ^ Override the default temporary data directory by passing in
  -- 'Permanent' @DIRECTORY@.
  , port    :: Last (Maybe Int)
  -- ^ A monoid for using an existing port (via 'Just' @PORT_NUMBER@) or
  -- requesting a free port (via a 'Nothing').
  , temporaryDirectory :: Last FilePath
  -- ^ The directory used to create other temporary directories. Defaults
  --   to @/tmp@.
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup Config
  deriving Monoid    via GenericMonoid Config

instance Pretty Config where
  pretty Config {..}
    =  text "plan:"
    <> softline
    <> pretty plan
    <> hardline
    <> text "socketDirectory:"
    <> softline
    <> pretty socketDirectory
    <> hardline
    <> text "dataDirectory:"
    <> softline
    <> pretty dataDirectory
    <> hardline
    <> text "port:" <+> pretty (getLast port)
    <> hardline
    <> text "temporaryDirectory:"
    <> softline
    <> pretty (getLast temporaryDirectory)

socketDirectoryToConfig :: FilePath -> [String]
socketDirectoryToConfig dir =
    [ "listen_addresses = '127.0.0.1, ::1'"
    , "unix_socket_directories = '" <> dir <> "'"
    ]

-- | Create a 'Plan' that sets the command line options of all processes
--   (@initdb@, @postgres@ and @createdb@). This the @generated@ plan
--   that is combined with the @extra@ plan from
--   'Database.Postgres.Temp.startConfig'.
toPlan
  :: Bool
  -- ^ Make @initdb@ options.
  -> Bool
  -- ^ Make @createdb@ options.
  -> Int
  -- ^ The port.
  -> FilePath
  -- ^ Socket directory.
  -> FilePath
  -- ^ The @postgres@ data directory.
  -> Plan
toPlan makeInitDb makeCreateDb port socketDirectory dataDirectoryString = mempty
  { postgresConfigFile = socketDirectoryToConfig socketDirectory
  , dataDirectoryString = pure dataDirectoryString
  , connectionTimeout = pure (60 * 1000000) -- 1 minute
  , logger = pure print
  , initDbCache = pure Nothing
  , postgresPlan = mempty
      { postgresConfig = standardProcessConfig
          { commandLine = mempty
              { keyBased = Map.fromList
                  [ ("-p", Just $ show port)
                  , ("-D", Just dataDirectoryString)
                  ]
              }
          }
      , connectionOptions = mempty
          { Client.host   = pure socketDirectory
          , Client.port   = pure port
          , Client.dbname = pure "postgres"
          }
      }
  , createDbConfig = if makeCreateDb
      then pure $ standardProcessConfig
        { commandLine = mempty
            { keyBased = Map.fromList $
                [ ("-h", Just socketDirectory)
                , ("-p ", Just $ show port)
                ]
            }
        }
      else Nothing
  , initDbConfig = if makeInitDb
      then pure $ standardProcessConfig
        { commandLine = mempty
            { keyBased = Map.fromList
                [("--pgdata=", Just dataDirectoryString)]
            }
        }
      else Nothing
  }


-- | Create all the temporary resources from a 'Config'. This also combines the
-- 'Plan' from 'toPlan' with the @extra@ 'Config' passed in.
setupConfig
  :: Config
  -- ^ @extra@ 'Config' to 'mappend' after the @generated@ 'Config'.
  -> IO Resources
setupConfig Config {..} = evalContT $ do
  envs <- lift getEnvironment
  thePort <- lift $ maybe getFreePort pure $ join $ getLast port
  let resourcesTemporaryDir = fromMaybe "/tmp" $ getLast temporaryDirectory
  resourcesSocketDirectory <- ContT $ bracketOnError
    (setupDirectoryType resourcesTemporaryDir "tmp-postgres-socket" socketDirectory) cleanupDirectoryType
  resourcesDataDir <- ContT $ bracketOnError
    (setupDirectoryType resourcesTemporaryDir "tmp-postgres-data" dataDirectory) cleanupDirectoryType
  let hostAndDir = toPlan
        (hasInitDb plan)
        (hasCreateDb plan)
        thePort
        (toFilePath resourcesSocketDirectory)
        (toFilePath resourcesDataDir)
      finalPlan = hostAndDir <> plan
  resourcesPlan <- lift $
    either (throwIO . CompletePlanFailed (show $ pretty finalPlan)) pure $
      completePlan envs finalPlan
  pure Resources {..}

-- | Free the temporary resources created by 'setupConfig'.
cleanupConfig :: Resources -> IO ()
cleanupConfig Resources {..} = do
  cleanupDirectoryType resourcesSocketDirectory
  cleanupDirectoryType resourcesDataDir

-- | Display a 'Config'.
--
--   @since 1.12.0.0
prettyPrintConfig :: Config -> String
prettyPrintConfig = show . pretty

-- | 'Resources' holds a description of the temporary folders (if there are any)
--   and includes the final 'CompletePlan' that can be used with 'startPlan'.
--   See 'setupConfig' for an example of how to create a 'Resources'.
--
--   @since 1.12.0.0
data Resources = Resources
  { resourcesPlan    :: CompletePlan
  -- ^ Final 'CompletePlan'. See 'startPlan' for information on 'CompletePlan's.
  , resourcesSocketDirectory :: CompleteDirectoryType
  -- ^ The used to potentially cleanup the temporary unix socket directory.
  , resourcesDataDir :: CompleteDirectoryType
  -- ^ The data directory. Used to track if a temporary directory was used.
  , resourcesTemporaryDir :: FilePath
  -- ^ The directory where other temporary directories are created.
  --   Usually @/tmp.
  }

instance Pretty Resources where
  pretty Resources {..}
    =   text "resourcePlan:"
    <>  softline
    <>  indent 2 (pretty resourcesPlan)
    <>  hardline
    <>  text "resourcesSocket:"
    <+> pretty resourcesSocketDirectory
    <>  hardline
    <>  text "resourcesDataDir:"
    <+> pretty resourcesDataDir

-- | Make the 'resourcesDataDir' 'CPermanent' so it will not
--   get cleaned up.
--
--   @since 1.12.0.0
makeResourcesDataDirPermanent :: Resources -> Resources
makeResourcesDataDirPermanent r = r
  { resourcesDataDir = makePermanent $ resourcesDataDir r
  }
-------------------------------------------------------------------------------
-- Config Generation
-------------------------------------------------------------------------------
-- | Attempt to create a config from a 'Client.Options'. This is useful if
--   want to create a database owned by a specific user you will also log in as
--   among other use cases. It is possible some 'Client.Options' are not
--   supported so don't hesitate to open an issue on github if you find one.
optionsToConfig :: Client.Options -> Config
optionsToConfig opts@Client.Options {..}
  =  ( mempty
       { plan = optionsToPlan opts
       , port = maybe (Last Nothing) (pure . pure) $ getLast port
       , socketDirectory = maybe mempty hostToSocketClass $ getLast host
       }
     )
-- Convert the 'Client.Options' to a 'Plan' that can
-- be connected to with the 'Client.Options'.
optionsToPlan :: Client.Options -> Plan
optionsToPlan opts@Client.Options {..}
  =  maybe mempty (dbnameToPlan (getLast user) (getLast password)) (getLast dbname)
  <> maybe mempty userToPlan (getLast user)
  <> maybe mempty passwordToPlan (getLast password)
  <> clientOptionsToPlan opts

-- Wrap the 'Client.Options' in an appropiate
-- 'PostgresPlan'.
clientOptionsToPlan :: Client.Options -> Plan
clientOptionsToPlan opts = mempty
  { postgresPlan = mempty
    { connectionOptions = opts
    }
  }

-- Create a 'Plan' given a user.
userToPlan :: String -> Plan
userToPlan user = mempty
  { initDbConfig = pure $ mempty
    { commandLine = mempty
        { keyBased = Map.singleton "--username=" $ Just user
        }
    }
  }

-- Adds a @createdb@ ProcessPlan with the argument
-- as the database name.
-- It does nothing if the db names are "template1" or
-- "postgres"
dbnameToPlan :: Maybe String -> Maybe String -> String -> Plan
dbnameToPlan muser mpassword dbName
  | dbName == "template1" || dbName == "postgres" = mempty
  | otherwise = mempty
    { createDbConfig = pure $ mempty
      { commandLine = mempty
        { indexBased = Map.singleton 0 dbName
        , keyBased = maybe mempty (Map.singleton "--username=" . Just) muser
        }
      , environmentVariables = mempty
        { specific = maybe mempty (Map.singleton "PGPASSWORD") mpassword
        }
      }
    }

-- Adds the 'PGPASSWORD' to both @initdb@ and @createdb@
passwordToPlan :: String -> Plan
passwordToPlan password = mempty
  { initDbConfig = pure mempty
    { environmentVariables = mempty
      { specific = Map.singleton "PGPASSWORD" password
      }
    }
  }

-- Parse a host string as either an UNIX domain socket directory
-- or a domain or IP.
hostToSocketClass :: String -> DirectoryType
hostToSocketClass hostOrSocketPath = case hostOrSocketPath of
  '/' : _ -> Permanent hostOrSocketPath
  _ -> Temporary

-------------------------------------------------------------------------------
-- Lenses
-- Most this code was generated with microlens-th
-------------------------------------------------------------------------------
-- | Local Lens alias.
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t
-- | Local Lens' alias.
type Lens' s a = Lens s s a a

-- | Lens for 'inherit'
--
--   @since 1.12.0.0
inheritL :: Lens' EnvironmentVariables (Last Bool)
inheritL f_aj5e (EnvironmentVariables x_aj5f x_aj5g)
  = fmap (`EnvironmentVariables` x_aj5g)
      (f_aj5e x_aj5f)
{-# INLINE inheritL #-}

-- | Lens for 'specific'.
--
--   @since 1.12.0.0
specificL :: Lens' EnvironmentVariables (Map String String)
specificL f_aj5i (EnvironmentVariables x_aj5j x_aj5k)
  = fmap (EnvironmentVariables x_aj5j)
      (f_aj5i x_aj5k)
{-# INLINE specificL #-}

-- | Lens for 'commandLine'.
--
--   @since 1.12.0.0
commandLineL ::
  Lens' ProcessConfig CommandLineArgs
commandLineL
  f_allv
  (ProcessConfig x_allw x_allx x_ally x_allz x_allA)
  = fmap
       (\ y_allB
          -> ProcessConfig x_allw y_allB x_ally x_allz
               x_allA)
      (f_allv x_allx)
{-# INLINE commandLineL #-}

-- | Lens for 'environmentVariables'.
--
--   @since 1.12.0.0
environmentVariablesL ::
  Lens' ProcessConfig EnvironmentVariables
environmentVariablesL
  f_allC
  (ProcessConfig x_allD x_allE x_allF x_allG x_allH)
  = fmap
       (\ y_allI
          -> ProcessConfig y_allI x_allE x_allF x_allG
               x_allH)
      (f_allC x_allD)
{-# INLINE environmentVariablesL #-}

-- | Lens for 'stdErr'
--
--   @since 1.12.0.0
stdErrL ::
  Lens' ProcessConfig (Last Handle)
stdErrL
  f_allJ
  (ProcessConfig x_allK x_allL x_allM x_allN x_allO)
  = fmap
       (ProcessConfig x_allK x_allL x_allM x_allN)
      (f_allJ x_allO)
{-# INLINE stdErrL #-}

-- | Lens for 'stdIn'.
--
--   @since 1.12.0.0
stdInL ::
  Lens' ProcessConfig (Last Handle)
stdInL
  f_allQ
  (ProcessConfig x_allR x_allS x_allT x_allU x_allV)
  = fmap
       (\ y_allW
          -> ProcessConfig x_allR x_allS y_allW x_allU
               x_allV)
      (f_allQ x_allT)
{-# INLINE stdInL #-}

-- | Lens for 'stdOut'.
--
--   @since 1.12.0.0
stdOutL ::
  Lens' ProcessConfig (Last Handle)
stdOutL
  f_allX
  (ProcessConfig x_allY x_allZ x_alm0 x_alm1 x_alm2)
  = fmap
       (\ y_alm3
          -> ProcessConfig x_allY x_allZ x_alm0 y_alm3
               x_alm2)
      (f_allX x_alm1)
{-# INLINE stdOutL #-}

-- | Lens for 'connectionOptions'.
--
--   @since 1.12.0.0
connectionOptionsL ::
  Lens' PostgresPlan Client.Options
connectionOptionsL
  f_am1y
  (PostgresPlan x_am1z x_am1A)
  = fmap (PostgresPlan x_am1z)
      (f_am1y x_am1A)
{-# INLINE connectionOptionsL #-}

-- | Lens for 'postgresConfig'.
--
--   @since 1.12.0.0
postgresConfigL ::
  Lens' PostgresPlan ProcessConfig
postgresConfigL
  f_am1C
  (PostgresPlan x_am1D x_am1E)
  = fmap (`PostgresPlan` x_am1E)
      (f_am1C x_am1D)
{-# INLINE postgresConfigL #-}

-- | Lens for 'postgresConfigFile'.
--
--   @since 1.12.0.0
postgresConfigFileL :: Lens' Plan [String]
postgresConfigFileL f (plan@Plan{..})
  = fmap (\x -> plan { postgresConfigFile = x })
      (f postgresConfigFile)
{-# INLINE postgresConfigFileL #-}

-- | Lens for 'createDbConfig'.
--
--   @since 1.12.0.0
createDbConfigL ::
  Lens' Plan (Maybe ProcessConfig)
createDbConfigL f (plan@Plan{..})
  = fmap (\x -> plan { createDbConfig = x })
      (f createDbConfig)
{-# INLINE createDbConfigL #-}

-- | Lens for 'dataDirectoryString'.
--
--   @since 1.12.0.0
dataDirectoryStringL :: Lens' Plan (Last String)
dataDirectoryStringL f (plan@Plan{..})
  = fmap (\x -> plan { dataDirectoryString = x })
      (f dataDirectoryString)
{-# INLINE dataDirectoryStringL #-}

-- | Lens for 'initDbConfig'.
--
--   @since 1.12.0.0
initDbConfigL :: Lens' Plan (Maybe ProcessConfig)
initDbConfigL f (plan@Plan{..})
  = fmap (\x -> plan { initDbConfig = x })
      (f initDbConfig)
{-# INLINE initDbConfigL #-}

-- | Lens for 'logger'.
--
--   @since 1.12.0.0
loggerL :: Lens' Plan (Last Logger)
loggerL f (plan@Plan{..})
  = fmap (\x -> plan { logger = x })
      (f logger)
{-# INLINE loggerL #-}

-- | Lens for 'postgresPlan'.
--
--   @since 1.12.0.0
postgresPlanL :: Lens' Plan PostgresPlan
postgresPlanL f (plan@Plan{..})
  = fmap (\x -> plan { postgresPlan = x })
      (f postgresPlan)
{-# INLINE postgresPlanL #-}

-- | Lens for 'connectionTimeout'.
--
--   @since 1.12.0.0
connectionTimeoutL :: Lens' Plan (Last Int)
connectionTimeoutL f (plan@Plan{..})
  = fmap (\x -> plan { connectionTimeout = x })
      (f connectionTimeout)
{-# INLINE connectionTimeoutL #-}

-- | Lens for 'resourcesDataDir'.
--
--   @since 1.12.0.0
resourcesDataDirL :: Lens' Resources CompleteDirectoryType
resourcesDataDirL f (resources@Resources {..})
  = fmap (\x -> resources { resourcesDataDir = x })
      (f resourcesDataDir)
{-# INLINE resourcesDataDirL #-}

-- | Lens for 'resourcesPlan'.
--
--   @since 1.12.0.0
resourcesPlanL :: Lens' Resources CompletePlan
resourcesPlanL f (resources@Resources {..})
  = fmap (\x -> resources { resourcesPlan = x })
      (f resourcesPlan)
{-# INLINE resourcesPlanL #-}

-- | Lens for 'resourcesSocketDirectory'.
--
--   @since 1.15.0.0
resourcesSocketDirectoryL :: Lens' Resources CompleteDirectoryType
resourcesSocketDirectoryL f (resources@Resources {..})
  = fmap (\x -> resources { resourcesSocketDirectory = x })
      (f resourcesSocketDirectory)
{-# INLINE resourcesSocketDirectoryL #-}

-- | Lens for 'dataDirectory'.
--
--   @since 1.12.0.0
dataDirectoryL :: Lens' Config DirectoryType
dataDirectoryL f (config@Config{..})
  = fmap (\ x -> config { dataDirectory = x } )
      (f dataDirectory)
{-# INLINE dataDirectoryL #-}

-- | Lens for 'plan'.
--
--   @since 1.12.0.0
planL :: Lens' Config Plan
planL f (config@Config{..})
  = fmap (\ x -> config { plan = x } )
      (f plan)
{-# INLINE planL #-}

-- | Lens for 'port'.
--
--   @since 1.12.0.0
portL :: Lens' Config (Last (Maybe Int))
portL f (config@Config{..})
  = fmap (\ x -> config { port = x } )
      (f port)
{-# INLINE portL #-}

-- | Lens for 'socketDirectory'.
--
--   @since 1.12.0.0
socketDirectoryL :: Lens' Config DirectoryType
socketDirectoryL f (config@Config{..})
  = fmap (\ x -> config { socketDirectory = x } )
      (f socketDirectory)
{-# INLINE socketDirectoryL #-}

-- | Lens for 'socketDirectory'.
--
--   @since 1.12.0.0
temporaryDirectoryL :: Lens' Config (Last FilePath)
temporaryDirectoryL f (config@Config{..})
  = fmap (\ x -> config { temporaryDirectory = x } )
      (f temporaryDirectory)
{-# INLINE temporaryDirectoryL #-}

-- | Lens for 'indexBased'.
--
--   @since 1.12.0.0
indexBasedL ::
  Lens' CommandLineArgs (Map Int String)
indexBasedL
  f_amNr
  (CommandLineArgs x_amNs x_amNt)
  = fmap (CommandLineArgs x_amNs)
      (f_amNr x_amNt)
{-# INLINE indexBasedL #-}

-- | Lens for 'keyBased'.
--
--   @since 1.12.0.0
keyBasedL ::
  Lens' CommandLineArgs (Map String (Maybe String))
keyBasedL
  f_amNv
  (CommandLineArgs x_amNw x_amNx)
  = fmap (`CommandLineArgs` x_amNx)
      (f_amNv x_amNw)
{-# INLINE keyBasedL #-}
