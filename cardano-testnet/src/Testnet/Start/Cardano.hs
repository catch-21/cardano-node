{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module Testnet.Start.Cardano
  ( ForkPoint(..)
  , CardanoTestnetOptions(..)
  , extraSpoNodeCliArgs
  , TestnetNodeOptions(..)
  , cardanoDefaultTestnetOptions
  , cardanoDefaultTestnetNodeOptions

  , TestnetRuntime (..)
  , PaymentKeyPair(..)

  , cardanoTestnet
  , cardanoTestnetDefault
  ) where



import           Prelude hiding (lines)

import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except (runExceptT)
import Control.Concurrent (threadDelay)
import qualified Control.Exception as IO
import Control.Monad
import Control.Monad.Trans.Class (lift)
import           Data.Aeson
import qualified Data.Aeson as Aeson
import           Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LBS
import           Data.Either
import Data.Functor (($>))
import qualified Data.List as L
import           Data.Maybe

import qualified Data.Text as Text
import           Data.Time (UTCTime)
import qualified Data.Time.Clock as DTC
import           Data.Word (Word32)
import qualified GHC.Stack as GHC
import qualified Network.Socket as IO
import           Prelude hiding (lines)
import           System.FilePath ((</>))
import qualified System.Info as OS

import Hedgehog (MonadTest)
import qualified Hedgehog as H
import           Hedgehog.Extras (failMessage)
import Hedgehog.Extras.Stock (allocateRandomPorts)
import qualified Hedgehog.Extras.Stock.OS as OS
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H

import qualified Testnet.Defaults as Defaults

import           Cardano.Api
import           Cardano.Api.Ledger (StandardCrypto)
import           Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import           Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import           Testnet.Components.Configuration
import           Testnet.Filepath
import qualified Testnet.Process.Run as H
import           Testnet.Process.Run
import qualified Testnet.Property.Assert as H
import           Testnet.Property.Checks
import           Testnet.Runtime as TR hiding (shelleyGenesis)
import qualified Testnet.Start.Byron as Byron
import           Testnet.Start.Types

{- HLINT ignore "Redundant flip" -}
{- HLINT ignore "Redundant id" -}
{- HLINT ignore "Use let" -}


-- | There are certain conditions that need to be met in order to run
-- a valid node cluster.
testnetMinimumConfigurationRequirements :: CardanoTestnetOptions -> H.Integration ()
testnetMinimumConfigurationRequirements cTestnetOpts = do
  let actualLength = length (cardanoNodes cTestnetOpts)
  when (actualLength < 2) $ do
     H.noteShow_ ("Need at least two nodes to run a cluster, but got: " <> show actualLength)
     H.noteShow_ cTestnetOpts
     H.failure

data ForkPoint
  = AtVersion Int
  | AtEpoch Int
  deriving (Show, Eq, Read)


-- | Check if a TCP port is open
isPortOpen :: Int -> IO Bool
isPortOpen port = do
  socketAddressInfos <- IO.getAddrInfo Nothing (Just "127.0.0.1") (Just (show port))
  case socketAddressInfos of
    socketAddressInfo : _ -> canConnect (IO.addrAddress socketAddressInfo) $> True
    [] -> return False

{- | Check if it is possible to connect to a socket address
 TODO: upstream fix to Hedgehog Extras
-}
canConnect :: IO.SockAddr -> IO Bool
canConnect sockAddr = IO.bracket (IO.socket IO.AF_INET IO.Stream 6) IO.close' $ \sock -> do
  res <- IO.try $ IO.connect sock sockAddr
  case res of
    Left (_ :: IO.IOException) -> return False
    Right _ -> return True

-- | Get random list of open ports. Timeout after 60seconds if unsuccessful.
getOpenPorts :: (MonadTest m, MonadIO m) => Int -> Int -> m [Int]
getOpenPorts n numberOfPorts = do
  when (n == 0) $ do
    error "getOpenPorts timeout"
  ports <- liftIO $ allocateRandomPorts numberOfPorts
  allOpen <- liftIO $ mapM isPortOpen ports
  unless (and allOpen) $ do
    H.annotate "Some ports are not open, trying again..."
    liftIO $ threadDelay 1_000_000 -- wait 1 sec
    void $ getOpenPorts (pred n) numberOfPorts
  pure ports

{- | For an unknown reason, CLI commands are a lot slower on Windows than on Linux and
 MacOS.  We need to allow a lot more time to set up a testnet.
-}
startTimeOffsetSeconds :: DTC.NominalDiffTime
startTimeOffsetSeconds = if OS.isWin32 then 90 else 15

-- | Like 'cardanoTestnet', but using defaults for all configuration files.
-- See 'cardanoTestnet' for additional documentation.
cardanoTestnetDefault :: ()
  => CardanoTestnetOptions
  -> Conf
  -> H.Integration TestnetRuntime
cardanoTestnetDefault opts conf = do
  alonzoGenesis <- H.evalEither $ first prettyError Defaults.defaultAlonzoGenesis
  currentTime <- H.noteShowIO DTC.getCurrentTime
  startTime <- H.noteShow $ DTC.addUTCTime startTimeOffsetSeconds currentTime
  cardanoTestnet
    opts conf startTime
    (Defaults.defaultShelleyGenesis startTime opts) alonzoGenesis Defaults.defaultConwayGenesis

-- | Setup a number of credentials and pools, like this:
--
-- > ├── byron
-- > │   └── genesis.json
-- > ├── byron-gen-command
-- > │   └── genesis-keys.00{0,1,2}.key
-- > ├── byron.genesis.spec.json
-- > ├── configuration.yaml
-- > ├── current-stake-pools.json
-- > ├── delegate-keys
-- > │   ├── delegate{1,2,3}
-- > │   │   ├── kes.{skey,vkey}
-- > │   │   ├── key.{skey,vkey}
-- > │   │   ├── opcert.{cert,counter}
-- > │   │   └── vrf.{skey,vkey}
-- > │   └── README.md
-- > ├── drep-keys
-- > │   └── drep{1,2,3}
-- > │       └── drep.{skey,vkey}
-- > ├── genesis.{alonzo,conway}.spec.json
-- > ├── genesis-keys
-- > │   ├── genesis{1,2,3}
-- > │   │   └── key.{skey,vkey}
-- > │   └── README.md
-- > ├── logs
-- > │   └── pool3
-- > │       └── {stderr,stdout}.log
-- > ├── module
-- > ├── pools-keys
-- > │   ├── pool{1,2,3}
-- > │   │   ├── byron-delegate.key
-- > │   │   ├── byron-delegation.cert
-- > │   │   ├── cold.{skey,vkey}
-- > │   │   ├── kes.{skey,vkey}
-- > │   │   ├── opcert.{cert,counter}
-- > │   │   ├── staking-reward.{skey,vkey}
-- > │   │   ├── topology.json
-- > │   │   └── vrf.{skey,vkey}
-- > │   └── README.md
-- > ├── shelley
-- > │   └── genesis.{alonzo,conway,shelley}.json
-- > ├── socket
-- > │   └── pool{1,2,3}
-- > │       └── sock
-- > ├── stake-delegators
-- > │   └── delegator{1,2,3}
-- > │       ├── payment.{skey,vkey}
-- > │       └── staking.{skey,vkey}
-- > └─── utxo-keys
-- >     ├── README.md
-- >     └── utxo{1,2,3}
-- >         └── utxo.{addr,skey,vkey}
cardanoTestnet :: ()
  => CardanoTestnetOptions -- ^ The options to use. Must be consistent with the genesis files.
  -> Conf
  -> UTCTime -- ^ The starting time. Must be the same as the one in the shelley genesis.
  -> ShelleyGenesis StandardCrypto -- ^ The shelley genesis to use, for example 'Defaults.defaultShelleyGenesis'.
                                   --   Some fields are overridden by the accompanying 'CardanoTestnetOptions'.
  -> AlonzoGenesis -- ^ The alonzo genesis to use, for example 'Defaults.defaultAlonzoGenesis'.
  -> ConwayGenesis StandardCrypto -- ^ The conway genesis to use, for example 'Defaults.defaultConwayGenesis'.
  -> H.Integration TestnetRuntime
cardanoTestnet
  testnetOptions Conf {tempAbsPath=TmpAbsolutePath tmpAbsPath} startTime
  shelleyGenesis alonzoGenesis conwayGenesis = do
  let shelleyStartTime = sgSystemStart shelleyGenesis
      shelleyTestnetMagic = sgNetworkMagic shelleyGenesis
      optionsMagic :: Word32 = fromIntegral $ cardanoTestnetMagic testnetOptions
      testnetMagic = cardanoTestnetMagic testnetOptions
      numPoolNodes = length $ cardanoNodes testnetOptions
      -- nbPools = numPools testnetOptions
      era = cardanoNodeEra testnetOptions

   -- Sanity checks
  testnetMinimumConfigurationRequirements testnetOptions
  when (shelleyStartTime /= startTime) $ do
    H.note_ $ "Expected same system start in shelley genesis and parameter, but got " <> show shelleyStartTime <> " and " <> show startTime
    H.failure
  when (shelleyTestnetMagic /= optionsMagic) $ do
    H.note_ $ "Expected same network magic in shelley genesis and parameter, but got " <> show shelleyTestnetMagic <> " and " <> show optionsMagic
    H.failure
  -- Done with sanity checks

  H.note_ OS.os

  if all isJust [mconfig | SpoTestnetNodeOptions mconfig _ <- cardanoNodes testnetOptions]
  then
    -- TODO: We need a very simple non-obscure way of generating the files necessary
    -- to run a testnet. "create-staked" is not a good way to do this especially because it
    -- makes assumptions about where things should go and where genesis template files should be.
    -- See all of the ad hoc file creation/renaming/dir creation etc below.
    H.failMessage GHC.callStack "Specifying node configuration files per node not supported yet."
  else do
    H.lbsWriteFile (tmpAbsPath </> "byron.genesis.spec.json")
      . encode $ Defaults.defaultByronProtocolParamsJsonValue

    -- Because in Conway the overlay schedule and decentralization parameter
    -- are deprecated, we must use the "create-staked" cli command to create
    -- SPOs in the ShelleyGenesis
    Byron.createByronGenesis
      testnetMagic
      startTime
      Byron.byronDefaultGenesisOptions
      (tmpAbsPath </> "byron.genesis.spec.json")
      (tmpAbsPath </> "byron-gen-command")

    -- Write Alonzo genesis file
    alonzoGenesisJsonFile <- H.noteShow $ tmpAbsPath </> "genesis.alonzo.spec.json"
    H.evalIO $ LBS.writeFile alonzoGenesisJsonFile $ Aeson.encode alonzoGenesis

    -- Write Conway genesis file
    conwayGenesisJsonFile <- H.noteShow $ tmpAbsPath </> "genesis.conway.spec.json"
    H.evalIO $ LBS.writeFile conwayGenesisJsonFile $ Aeson.encode conwayGenesis

    configurationFile <- H.noteShow $ tmpAbsPath </> "configuration.yaml"

    _ <- createSPOGenesisAndFiles testnetOptions era shelleyGenesis (TmpAbsolutePath tmpAbsPath)

    poolKeys <- H.noteShow $ flip fmap [1..numPoolNodes] $ \n ->
      PoolNodeKeys
        { poolNodeKeysColdVkey = tmpAbsPath </> "pools" </> "cold" <> show n <> ".vkey"
        , poolNodeKeysColdSkey = tmpAbsPath </> "pools" </> "cold" <> show n <> ".skey"
        , poolNodeKeysVrfVkey = tmpAbsPath </> "pools" </> "vrf" <> show n <> ".vkey"
        , poolNodeKeysVrfSkey = tmpAbsPath </> "pools" </> "vrf" <> show n <> ".skey"
        , poolNodeKeysStakingVkey = tmpAbsPath </> "pools" </> "staking-reward" <> show n <> ".vkey"
        , poolNodeKeysStakingSkey = tmpAbsPath </> "pools" </> "staking-reward" <> show n <> ".skey"
        }
    let makeUTxOVKeyFp :: Int -> FilePath
        makeUTxOVKeyFp n = tmpAbsPath </> "utxo-keys" </> "utxo" <> show n </> "utxo.vkey"

        makeUTxOSkeyFp :: Int -> FilePath
        makeUTxOSkeyFp n = tmpAbsPath </> "utxo-keys" </> "utxo" <> show n </> "utxo.skey"

    wallets <- forM [1..3] $ \idx -> do
      let paymentSKeyFile = makeUTxOSkeyFp idx
      let paymentVKeyFile = makeUTxOVKeyFp idx
      let paymentAddrFile = tmpAbsPath </> "utxo-keys" </> "utxo" <> show @Int idx </> "utxo.addr"

      execCli_
        [ "address", "build"
        , "--payment-verification-key-file", makeUTxOVKeyFp idx
        , "--testnet-magic", show @Int testnetMagic
        , "--out-file", paymentAddrFile
        ]

      paymentAddr <- H.readFile paymentAddrFile

      pure $ PaymentKeyInfo
        { paymentKeyInfoPair = PaymentKeyPair
          { paymentSKey = paymentSKeyFile
          , paymentVKey = paymentVKeyFile
          }
        , paymentKeyInfoAddr = Text.pack paymentAddr
        }

    _delegators <- forM [1..3] $ \idx -> do
      pure $ Delegator
        { paymentKeyPair = PaymentKeyPair
          { paymentSKey = tmpAbsPath </> "stake-delegator-keys/payment" <> show @Int idx <> ".skey"
          , paymentVKey = tmpAbsPath </> "stake-delegator-keys/payment" <> show @Int idx <> ".vkey"
          }
        , stakingKeyPair = StakingKeyPair
          { stakingSKey = tmpAbsPath </> "stake-delegator-keys/staking" <> show @Int idx <> ".skey"
          , stakingVKey = tmpAbsPath </> "stake-delegator-keys/staking" <> show @Int idx <> ".vkey"
          }
        }

    -- TODO: This should come from the configuration!
    let poolKeyDir :: Int -> FilePath
        poolKeyDir i = "pools-keys" </> "pool" <> show i
        poolKeysFps = map poolKeyDir [1 .. numPoolNodes]


    -- Add Byron, Shelley and Alonzo genesis hashes to node configuration
    finalYamlConfig <- createConfigYaml (TmpAbsolutePath tmpAbsPath) era

    H.evalIO $ LBS.writeFile configurationFile finalYamlConfig

    -- Byron related

    H.renameFile (tmpAbsPath </> "byron-gen-command/delegate-keys.000.key") (tmpAbsPath </> poolKeyDir 1 </> "byron-delegate.key")
    H.renameFile (tmpAbsPath </> "byron-gen-command/delegate-keys.001.key") (tmpAbsPath </> poolKeyDir 2 </> "byron-delegate.key")
    H.renameFile (tmpAbsPath </> "byron-gen-command/delegate-keys.002.key") (tmpAbsPath </> poolKeyDir 3 </> "byron-delegate.key")

    H.renameFile (tmpAbsPath </> "byron-gen-command/delegation-cert.000.json") (tmpAbsPath </> poolKeyDir 1 </>"byron-delegation.cert")
    H.renameFile (tmpAbsPath </> "byron-gen-command/delegation-cert.001.json") (tmpAbsPath </> poolKeyDir 2 </>"byron-delegation.cert")
    H.renameFile (tmpAbsPath </> "byron-gen-command/delegation-cert.002.json") (tmpAbsPath </> poolKeyDir 3 </>"byron-delegation.cert")

    [port1, port2, port3, otherPort] <- getOpenPorts 60 (length (cardanoNodes testnetOptions) + 1)

    H.writeFile (tmpAbsPath </> poolKeyDir 1 </> "port") (show port1)
    H.writeFile (tmpAbsPath </> poolKeyDir 2 </> "port") (show port2)
    H.writeFile (tmpAbsPath </> poolKeyDir 3 </> "port") (show port3)


    -- Make topology files
    -- TODO generalise this over the N BFT nodes and pool nodes

    H.lbsWriteFile (tmpAbsPath </> poolKeyDir 1 </> "topology.json") $ encode $
      object
      [ "Producers" .= toJSON
        [ object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port2
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port3
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int otherPort
          , "valency" .= toJSON @Int 1
          ]
        ]
      ]

    H.lbsWriteFile (tmpAbsPath </> poolKeyDir 2 </> "topology.json")  $ encode $
      object
      [ "Producers" .= toJSON
        [ object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port1
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port3
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int otherPort
          , "valency" .= toJSON @Int 1
          ]
        ]
      ]

    H.lbsWriteFile (tmpAbsPath </> poolKeyDir 3 </> "topology.json") $ encode $
      object
      [ "Producers" .= toJSON
        [ object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port1
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int port2
          , "valency" .= toJSON @Int 1
          ]
        , object
          [ "addr"    .= toJSON @String "127.0.0.1"
          , "port"    .= toJSON @Int otherPort
          , "valency" .= toJSON @Int 1
          ]
        ]
      ]

    let spoNodesWithPortNos = L.zip poolKeysFps [3001..]
    ePoolNodes <- forM (L.zip spoNodesWithPortNos poolKeys) $ \((node, port),key) -> do
      let nodeName = tail $ dropWhile (/= '/') node
      H.note_ $ "Node name: " <> nodeName
      eRuntime <- lift . lift . runExceptT $ startNode (TmpAbsolutePath tmpAbsPath) nodeName port testnetMagic
                                  [ "run"
                                  , "--config", configurationFile
                                  , "--topology", tmpAbsPath </> node </> "topology.json"
                                  , "--database-path", tmpAbsPath </> node </> "db"
                                  , "--shelley-kes-key", tmpAbsPath </> node </> "kes.skey"
                                  , "--shelley-vrf-key", tmpAbsPath </> node </> "vrf.skey"
                                  , "--byron-delegation-certificate", tmpAbsPath </> node </> "byron-delegation.cert"
                                  , "--byron-signing-key", tmpAbsPath </> node </> "byron-delegate.key"
                                  , "--shelley-operational-certificate", tmpAbsPath </> node </> "opcert.cert"
                                  ]
      return $ flip PoolNode key <$> eRuntime

    if any isLeft ePoolNodes
    -- TODO: We can render this in a nicer way
    then failMessage GHC.callStack . show . map show $ lefts ePoolNodes
    else do
      let (_ , poolNodes) = partitionEithers ePoolNodes

      -- FIXME: replace with ledger events waiting for chain extensions
      liftIO $ threadDelay 10
      now <- H.noteShowIO DTC.getCurrentTime
      deadline <- H.noteShow $ DTC.addUTCTime 35 now

      forM_ (map (nodeStdout . poolRuntime) poolNodes) $ \nodeStdoutFile -> do
        H.assertChainExtended deadline (cardanoNodeLoggingFormat testnetOptions) nodeStdoutFile

      H.noteShowIO_ DTC.getCurrentTime

      forM_ wallets $ \wallet -> do
        H.cat $ paymentSKey $ paymentKeyInfoPair wallet
        H.cat $ paymentVKey $ paymentKeyInfoPair wallet

      let runtime = TestnetRuntime
            { configurationFile
            , shelleyGenesisFile = tmpAbsPath </> Defaults.defaultShelleyGenesisFp
            , testnetMagic
            , poolNodes
            , wallets = wallets
            , delegators = []
            }

      let tempBaseAbsPath = makeTmpBaseAbsPath $ TmpAbsolutePath tmpAbsPath

      node1sprocket <- H.headM $ poolSprockets runtime
      execConfig <- H.mkExecConfig tempBaseAbsPath node1sprocket testnetMagic

      forM_ wallets $ \wallet -> do
        H.cat $ paymentSKey $ paymentKeyInfoPair wallet
        H.cat $ paymentVKey $ paymentKeyInfoPair wallet

        utxos <- execCli' execConfig
          [ "query", "utxo"
          , "--address", Text.unpack $ paymentKeyInfoAddr wallet
          , "--cardano-mode"
          ]

        H.note_ utxos

      stakePoolsFp <- H.note $ tmpAbsPath </> "current-stake-pools.json"

      prop_spos_in_ledger_state stakePoolsFp testnetOptions execConfig

      pure runtime


