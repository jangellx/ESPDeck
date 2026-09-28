// The same vectors as crypto_test.cpp, computed by ESPDeck Bridge's own DeckCrypto
// (CryptoKit). run.sh compiles it together with ESPDeck Bridge/Security/DeckCrypto.swift.
import CryptoKit
import Foundation

func bytes( _ hex: String ) -> Data {
	Data( hex: hex )!
}

func utf8( _ text: String ) -> Data { Data( text.utf8 ) }

let bridgeID        = "0c6e0a52-1f6b-4b8e-9f1a-2b3c4d5e6f70"
let deviceID        = "f4:12:fa:00:00:01"
let macPairNonce    = bytes( "202122232425262728292a2b2c2d2e2f" )
let devicePairNonce = bytes( "303132333435363738393a3b3c3d3e3f" )
let deviceNonce     = bytes( "000102030405060708090a0b0c0d0e0f" )
let bridgeNonce     = bytes( "101112131415161718191a1b1c1d1e1f" )
let hello           = utf8( "{\"type\":\"hello\",\"protocol\":4,\"id\":\"f4:12:fa:00:00:01\"}" )
let frame           = utf8( "{\"type\":\"show\",\"key\":0,\"hash\":\"9f86d081884c7d659a2feaa0c55ad015\"}" )
let otaPassword     = "correct-horse-battery"
let otaCounter      = UInt64( 5 )

let mac       = try! Curve25519.KeyAgreement.PrivateKey( rawRepresentation: bytes( "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a" ) )
let device    = try! Curve25519.KeyAgreement.PrivateKey( rawRepresentation: bytes( "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb" ) )
let macPublic = mac.publicKey.rawRepresentation
let devPublic = device.publicKey.rawRepresentation
let shared    = try! mac.sharedSecretFromKeyAgreement( with: device.publicKey ).withUnsafeBytes { Data( $0 ) }

let key       = DeckCrypto.pairingKey( sharedSecret: shared, macPublicKey: macPublic, devicePublicKey: devPublic, macNonce: macPairNonce,
									   deviceNonce: devicePairNonce, bridgeID: bridgeID, deviceID: deviceID )
let helloHash = Data( SHA256.hash( data: hello ) )
let session   = DeckCrypto.sessionKey( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce )

func frameMAC( _ direction: DeckCrypto.Direction, _ counter: UInt64 ) -> String {
	DeckCrypto.frameMAC( session: session, direction: direction, counter: counter, payload: frame ).hex
}

/// Hex parsing takes exactly two hex digits per byte and nothing else.
func strictHex() -> Bool {
	let bad = [ "+f", "-1", " f", "f ", "0x", "g0", "f" ]
	return bad.allSatisfy { Data( hex: $0 ) == nil } && Data( hex: "0aFf" ) == Data( [ 0x0A, 0xFF ] ) && Data( hex: "" ) == Data()
}

print( "macPublicKey=\(macPublic.hex)" )
print( "devicePublicKey=\(devPublic.hex)" )
print( "sharedSecret=\(shared.hex)" )
print( "pairCommitment=\(DeckCrypto.pairCommitment( deviceNonce: devicePairNonce, devicePublicKey: devPublic, macPublicKey: macPublic ).hex)" )
print( "code=\(DeckCrypto.pairingCode( macPublicKey: macPublic, devicePublicKey: devPublic, macNonce: macPairNonce, deviceNonce: devicePairNonce ))" )
print( "K=\(key.hex)" )
print( "pairConfirmProof=\(DeckCrypto.pairConfirmProof( key: key ).hex)" )
print( "helloSHA256=\(helloHash.hex)" )
print( "bridgeProof=\(DeckCrypto.bridgeProof( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce ).hex)" )
print( "deviceProof=\(DeckCrypto.deviceProof( key: key, bridgeNonce: bridgeNonce, deviceNonce: deviceNonce, hello: hello ).hex)" )
print( "S=\(session.hex)" )
print( "macFromBridgeCounter0=\(frameMAC( .toDevice, 0 ))" )
print( "macFromBridgeCounter1=\(frameMAC( .toDevice, 1 ))" )
print( "macFromDeviceCounter0=\(frameMAC( .toBridge, 0 ))" )
print( "macFromDeviceCounter0102030405060708=\(frameMAC( .toBridge, 0x0102030405060708 ))" )

let passwordHash = Data( hex: DevOTAPassword.hash( otaPassword ) )!
var sealed       = DeckCrypto.sealDevOTA( session: session, counter: otaCounter, passwordHash: passwordHash )!
print( "devOTAPasswordHash=\(passwordHash.hex)" )
print( "devOTASealedCounter5=\(sealed.hex)" )
let opens    = DeckCrypto.openDevOTA( session: session, counter: otaCounter, sealed: sealed ) == passwordHash
let wrongCtr = DeckCrypto.openDevOTA( session: session, counter: otaCounter + 1, sealed: sealed ) != nil
sealed[sealed.startIndex + 3] ^= 0x01
let tampered = DeckCrypto.openDevOTA( session: session, counter: otaCounter, sealed: sealed ) != nil
print( "devOTAOpens=\(opens ? "yes" : "no")" )
print( "devOTARejectsOtherCounter=\(wrongCtr ? "no" : "yes")" )
print( "devOTARejectsTampering=\(tampered ? "no" : "yes")" )
print( "strictHex=\(strictHex() ? "yes" : "no")" )
