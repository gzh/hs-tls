{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Network.TLS.Handshake.Signature
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Handshake.Signature
    (
      DigitalSignatureAlg(..)
    , createCertificateVerify
    , certificateVerifyCheck
    , digitallySignDHParams
    , digitallySignECDHParams
    , digitallySignDHParamsVerify
    , digitallySignECDHParamsVerify
    , signatureCompatible
    ) where

import Network.TLS.Crypto
import Network.TLS.Context.Internal
import Network.TLS.Struct
import Network.TLS.Imports
import Network.TLS.Packet (generateCertificateVerify_SSL, generateCertificateVerify_SSL_DSS,
                           encodeSignedDHParams, encodeSignedECDHParams)
import Network.TLS.State
import Network.TLS.Handshake.State
import Network.TLS.Handshake.Key
import Network.TLS.Util

import Control.Monad.State

-- Digital signature algorithm, in close relation to public/private key types
-- and cipher key exchange.
data DigitalSignatureAlg = RSA | DSS | ECDSA deriving (Show, Eq)

signatureCompatible :: DigitalSignatureAlg -> HashAndSignatureAlgorithm -> Bool
signatureCompatible RSA   (_, SignatureRSA)   = True
signatureCompatible DSS   (_, SignatureDSS)   = True
signatureCompatible ECDSA (_, SignatureECDSA) = True
signatureCompatible _     (_, _)              = False

certificateVerifyCheck :: Context
                       -> Version
                       -> DigitalSignatureAlg
                       -> Bytes
                       -> DigitallySigned
                       -> IO Bool
certificateVerifyCheck ctx usedVersion sigAlgExpected msgs digSig@(DigitallySigned hashSigAlg _) =
    case (usedVersion, hashSigAlg) of
        (TLS12, Nothing)    -> return False
        (TLS12, Just hs) | sigAlgExpected `signatureCompatible` hs -> doVerify
                         | otherwise                               -> return False
        (_,     Nothing)    -> doVerify
        (_,     Just _)     -> return False
  where
    doVerify =
        prepareCertificateVerifySignatureData ctx usedVersion sigAlgExpected hashSigAlg msgs >>=
        signatureVerifyWithHashDescr ctx digSig

createCertificateVerify :: Context
                        -> Version
                        -> DigitalSignatureAlg
                        -> Maybe HashAndSignatureAlgorithm -- TLS12 only
                        -> Bytes
                        -> IO DigitallySigned
createCertificateVerify ctx usedVersion sigAlg hashSigAlg msgs =
    prepareCertificateVerifySignatureData ctx usedVersion sigAlg hashSigAlg msgs >>=
    signatureCreateWithHashDescr ctx hashSigAlg

type CertVerifyData = (SignatureParams, Bytes)

-- in the case of TLS < 1.2, RSA signing, then the data need to be hashed first, as
-- the SHA1_MD5 algorithm expect an already digested data
buildVerifyData :: SignatureParams -> Bytes -> CertVerifyData
buildVerifyData (RSAParams SHA1_MD5) bs = (RSAParams SHA1_MD5, hashFinal $ hashUpdate (hashInit SHA1_MD5) bs)
buildVerifyData sigParam             bs = (sigParam, bs)

prepareCertificateVerifySignatureData :: Context
                                      -> Version
                                      -> DigitalSignatureAlg
                                      -> Maybe HashAndSignatureAlgorithm -- TLS12 only
                                      -> Bytes
                                      -> IO CertVerifyData
prepareCertificateVerifySignatureData ctx usedVersion sigAlg hashSigAlg msgs
    | usedVersion == SSL3 = do
        (hashCtx, params, generateCV_SSL) <-
            case sigAlg of
                RSA -> return (hashInit SHA1_MD5, RSAParams SHA1_MD5, generateCertificateVerify_SSL)
                DSS -> return (hashInit SHA1, DSSParams, generateCertificateVerify_SSL_DSS)
                _   -> throwCore $ Error_Misc ("unsupported CertificateVerify signature for SSL3: " ++ show sigAlg)
        Just masterSecret <- usingHState ctx $ gets hstMasterSecret
        return (params, generateCV_SSL masterSecret $ hashUpdate hashCtx msgs)
    | usedVersion == TLS10 || usedVersion == TLS11 =
            return $ buildVerifyData (signatureParams sigAlg Nothing) msgs
    | otherwise = return (signatureParams sigAlg hashSigAlg, msgs)

signatureParams :: DigitalSignatureAlg -> Maybe HashAndSignatureAlgorithm -> SignatureParams
signatureParams RSA hashSigAlg =
    case hashSigAlg of
        Just (HashSHA512, SignatureRSA) -> RSAParams SHA512
        Just (HashSHA384, SignatureRSA) -> RSAParams SHA384
        Just (HashSHA256, SignatureRSA) -> RSAParams SHA256
        Just (HashSHA1  , SignatureRSA) -> RSAParams SHA1
        Nothing                         -> RSAParams SHA1_MD5
        Just (hsh       , SignatureRSA) -> error ("unimplemented RSA signature hash type: " ++ show hsh)
        Just (_         , sigAlg)       -> error ("signature algorithm is incompatible with RSA: " ++ show sigAlg)
signatureParams DSS hashSigAlg =
    case hashSigAlg of
        Nothing                       -> DSSParams
        Just (HashSHA1, SignatureDSS) -> DSSParams
        Just (_       , SignatureDSS) -> error "invalid DSA hash choice, only SHA1 allowed"
        Just (_       , sigAlg)       -> error ("signature algorithm is incompatible with DSS: " ++ show sigAlg)
signatureParams ECDSA hashSigAlg =
    case hashSigAlg of
        Just (HashSHA512, SignatureECDSA) -> ECDSAParams SHA512
        Just (HashSHA384, SignatureECDSA) -> ECDSAParams SHA384
        Just (HashSHA256, SignatureECDSA) -> ECDSAParams SHA256
        Just (HashSHA1  , SignatureECDSA) -> ECDSAParams SHA1
        Nothing                           -> ECDSAParams SHA1
        Just (hsh       , SignatureECDSA) -> error ("unimplemented ECDSA signature hash type: " ++ show hsh)
        Just (_         , sigAlg)         -> error ("signature algorithm is incompatible with ECDSA: " ++ show sigAlg)

signatureCreateWithHashDescr :: Context
                             -> Maybe HashAndSignatureAlgorithm
                             -> CertVerifyData
                             -> IO DigitallySigned
signatureCreateWithHashDescr ctx malg (sigParam, toSign) = do
    cc <- usingState_ ctx $ isClientContext
    DigitallySigned malg <$> signPrivate ctx cc sigParam toSign

signatureVerify :: Context -> DigitallySigned -> DigitalSignatureAlg -> Bytes -> IO Bool
signatureVerify ctx digSig@(DigitallySigned hashSigAlg _) sigAlgExpected toVerifyData = do
    usedVersion <- usingState_ ctx getVersion
    let (sigParam, toVerify) =
            case (usedVersion, hashSigAlg) of
                (TLS12, Nothing)    -> error "expecting hash and signature algorithm in a TLS12 digitally signed structure"
                (TLS12, Just hs) | sigAlgExpected `signatureCompatible` hs -> (signatureParams sigAlgExpected hashSigAlg, toVerifyData)
                                 | otherwise                               -> error "expecting different signature algorithm"
                (_,     Nothing)    -> buildVerifyData (signatureParams sigAlgExpected Nothing) toVerifyData
                (_,     Just _)     -> error "not expecting hash and signature algorithm in a < TLS12 digitially signed structure"
    signatureVerifyWithHashDescr ctx digSig (sigParam, toVerify)

signatureVerifyWithHashDescr :: Context
                             -> DigitallySigned
                             -> CertVerifyData
                             -> IO Bool
signatureVerifyWithHashDescr ctx (DigitallySigned _ bs) (sigParam, toVerify) = do
    cc <- usingState_ ctx $ isClientContext
    verifyPublic ctx cc sigParam toVerify bs

digitallySignParams :: Context -> Bytes -> DigitalSignatureAlg -> Maybe HashAndSignatureAlgorithm -> IO DigitallySigned
digitallySignParams ctx signatureData sigAlg hashSigAlg =
    let sigParam = signatureParams sigAlg hashSigAlg
     in signatureCreateWithHashDescr ctx hashSigAlg (buildVerifyData sigParam signatureData)

digitallySignDHParams :: Context
                      -> ServerDHParams
                      -> DigitalSignatureAlg
                      -> Maybe HashAndSignatureAlgorithm -- TLS12 only
                      -> IO DigitallySigned
digitallySignDHParams ctx serverParams sigAlg mhash = do
    dhParamsData <- withClientAndServerRandom ctx $ encodeSignedDHParams serverParams
    digitallySignParams ctx dhParamsData sigAlg mhash

digitallySignECDHParams :: Context
                        -> ServerECDHParams
                        -> DigitalSignatureAlg
                        -> Maybe HashAndSignatureAlgorithm -- TLS12 only
                        -> IO DigitallySigned
digitallySignECDHParams ctx serverParams sigAlg mhash = do
    ecdhParamsData <- withClientAndServerRandom ctx $ encodeSignedECDHParams serverParams
    digitallySignParams ctx ecdhParamsData sigAlg mhash

digitallySignDHParamsVerify :: Context
                            -> ServerDHParams
                            -> DigitalSignatureAlg
                            -> DigitallySigned
                            -> IO Bool
digitallySignDHParamsVerify ctx dhparams sigAlg signature = do
    expectedData <- withClientAndServerRandom ctx $ encodeSignedDHParams dhparams
    signatureVerify ctx signature sigAlg expectedData

digitallySignECDHParamsVerify :: Context
                              -> ServerECDHParams
                              -> DigitalSignatureAlg
                              -> DigitallySigned
                              -> IO Bool
digitallySignECDHParamsVerify ctx dhparams sigAlg signature = do
    expectedData <- withClientAndServerRandom ctx $ encodeSignedECDHParams dhparams
    signatureVerify ctx signature sigAlg expectedData

withClientAndServerRandom :: Context -> (ClientRandom -> ServerRandom -> b) -> IO b
withClientAndServerRandom ctx f = do
    (cran, sran) <- usingHState ctx $ (,) <$> gets hstClientRandom
                                          <*> (fromJust "withClientAndServer : server random" <$> gets hstServerRandom)
    return $ f cran sran
