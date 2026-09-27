// The same vectors as crypto_test.cpp, computed with CryptoKit the way ESPDeck Bridge should.
//   swift crypto_test.swift
import CryptoKit
import Foundation

func bytes( _ hex: String ) -> Data {
	var data = Data()
	var index = hex.startIndex
	while index < hex.endIndex {
		let next = hex.index( index, offsetBy: 2 )
		data.append( UInt8( hex[index..<next], radix: 16 )! )
		index = next
	}
	return data
}

func hex<D: Sequence>( _ data: D ) -> String where D.Element == UInt8 {
	data.map { String( format: "%02x", $0 ) }.joined()
}

func hmac( _ key: Data, _ parts: Data... ) -> Data {
	var mac = HMAC<SHA256>( key: SymmetricKey( data: key ) )
	for part in parts { mac.update( data: part ) }
	return Data( mac.finalize() )
}

func utf8( _ text: String ) -> Data { Data( text.utf8 ) }

let bridgeID    = "0c6e0a52-1f6b-4b8e-9f1a-2b3c4d5e6f70"
let deviceID    = "f4:12:fa:00:00:01"
let deviceNonce = bytes( "000102030405060708090a0b0c0d0e0f" )
let bridgeNonce = bytes( "101112131415161718191a1b1c1d1e1f" )
let hello       = utf8( "{\"type\":\"hello\",\"protocol\":3,\"id\":\"f4:12:fa:00:00:01\"}" )
let frame       = utf8( "{\"type\":\"show\",\"key\":0,\"hash\":\"9f86d081884c7d659a2feaa0c55ad015\"}" )

let mac    = try! Curve25519.KeyAgreement.PrivateKey( rawRepresentation: bytes( "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a" ) )
let device = try! Curve25519.KeyAgreement.PrivateKey( rawRepresentation: bytes( "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb" ) )
let shared = try! mac.sharedSecretFromKeyAgreement( with: device.publicKey ).withUnsafeBytes { Data( $0 ) }

let codeDigest = Array( SHA256.hash( data: utf8( "espdeck-pair-code" ) + shared ) )
let codeValue  = codeDigest[0..<4].reduce( UInt32( 0 ) ) { $0 << 8 | UInt32( $1 ) } % 1_000_000
let key        = hmac( shared, utf8( "espdeck-pairing-key" ), utf8( bridgeID ), utf8( deviceID ) )
let helloHash  = Data( SHA256.hash( data: hello ) )
let session    = hmac( key, utf8( "espdeck-session" ), deviceNonce, bridgeNonce )

func frameMAC( _ direction: UInt8, _ counter: UInt64 ) -> String {
	var header = Data( [ direction ] )
	withUnsafeBytes( of: counter.bigEndian ) { header.append( contentsOf: $0 ) }
	return hex( hmac( session, header, frame ).prefix( 16 ) )
}

print( "macPublicKey=\(hex( mac.publicKey.rawRepresentation ))" )
print( "devicePublicKey=\(hex( device.publicKey.rawRepresentation ))" )
print( "sharedSecret=\(hex( shared ))" )
print( "code=\(String( format: "%06u", codeValue ))" )
print( "K=\(hex( key ))" )
print( "pairConfirmProof=\(hex( hmac( key, utf8( "espdeck-pair-confirm" ) ) ))" )
print( "helloSHA256=\(hex( helloHash ))" )
print( "bridgeProof=\(hex( hmac( key, utf8( "espdeck-bridge" ), deviceNonce, bridgeNonce ) ))" )
print( "deviceProof=\(hex( hmac( key, utf8( "espdeck-device" ), bridgeNonce, deviceNonce, helloHash ) ))" )
print( "S=\(hex( session ))" )
print( "macFromBridgeCounter0=\(frameMAC( 0x01, 0 ))" )
print( "macFromBridgeCounter1=\(frameMAC( 0x01, 1 ))" )
print( "macFromDeviceCounter0=\(frameMAC( 0x02, 0 ))" )
print( "macFromDeviceCounter0102030405060708=\(frameMAC( 0x02, 0x0102030405060708 ))" )
