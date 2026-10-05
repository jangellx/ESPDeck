//
//  DeckCrypto.swift
//  ESPDeck Bridge
//
//  The key derivations from PROTOCOL.md's Security section. Byte strings are
//  concatenated in the order listed; labels are UTF-8 without a terminator.
//  tools/crypto_test in ESPDeck Device checks this file against the firmware's mbedTLS
//  implementation.
//

import CryptoKit
import Foundation

/// Keys, proofs and MACs for pairing, authentication and sessions.
enum DeckCrypto {
	static let nonceSize = 16
	static let macSize   = 16

	/// Mac → ESP32 and ESP32 → Mac, for frame MACs.
	enum Direction: UInt8 {
		case toDevice = 0x01
		case toBridge = 0x02
	}

	/// From CryptoKit's key generation, which uses the system's secure generator and can't fail.
	static func randomBytes( _ count: Int ) -> Data {
		SymmetricKey( size: SymmetricKeySize( bitCount: count * 8 ) ).withUnsafeBytes { Data( $0 ) }
	}

	/// HMAC-SHA256 of the parts, one after another.
	static func hmac( _ key: Data, _ parts: [Data] ) -> Data {
		var mac = HMAC<SHA256>( key: SymmetricKey( data: key ) )
		for part in parts { mac.update( data: part ) }
		return Data( mac.finalize() )
	}

	private static func utf8( _ string: String ) -> Data { Data( string.utf8 ) }

	// MARK: Pairing (protocol 4)

	/// The device's commitment to its public key and nonce, sent before it sees the Mac's nonce.
	static func pairCommitment( deviceNonce: Data, devicePublicKey: Data, macPublicKey: Data ) -> Data {
		hmac( deviceNonce, [ utf8( "espdeck-pair-commit" ), devicePublicKey, macPublicKey ] )
	}

	/// Six digits both sides show; they differ if anyone is in the middle.
	static func pairingCode( macPublicKey: Data, devicePublicKey: Data, macNonce: Data, deviceNonce: Data ) -> String {
		let digest = Data( SHA256.hash( data: utf8( "espdeck-pair-code-v4" ) + macPublicKey + devicePublicKey + macNonce + deviceNonce ) )
		let value  = digest.prefix( 4 ).reduce( UInt32( 0 ) ) { $0 << 8 | UInt32( $1 ) }
		return String( format: "%06u", value % 1_000_000 )
	}

	/// K, the pairing key both sides store: from the X25519 shared secret and everything
	/// the pairing exchanged.
	static func pairingKey( sharedSecret: Data, macPublicKey: Data, devicePublicKey: Data, macNonce: Data, deviceNonce: Data,
							bridgeID: String, deviceID: String ) -> Data {
		hmac( sharedSecret, [ utf8( "espdeck-pairing-key-v4" ), macPublicKey, devicePublicKey, macNonce, deviceNonce, utf8( bridgeID ), utf8( deviceID ) ] )
	}

	/// The deck's proof, after the user confirmed there, that it derived the same K.
	static func pairConfirmProof( key: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-pair-confirm" ) ] )
	}

	// MARK: Authentication

	/// The Mac's proof that it holds the pairing key, sent with `auth`.
	static func bridgeProof( key: Data, deviceNonce: Data, bridgeNonce: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-bridge" ), deviceNonce, bridgeNonce ] )
	}

	/// The device's proof that it holds the pairing key, covering its exact hello.
	static func deviceProof( key: Data, bridgeNonce: Data, deviceNonce: Data, hello: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-device" ), bridgeNonce, deviceNonce, Data( SHA256.hash( data: hello ) ) ] )
	}

	/// The key for the session's frame MACs.
	static func sessionKey( key: Data, deviceNonce: Data, bridgeNonce: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-session" ), deviceNonce, bridgeNonce ] )
	}

	/// A frame's MAC: the direction and counter bind it to its place in the session.
	static func frameMAC( session: Data, direction: Direction, counter: UInt64, payload: Data ) -> Data {
		var count = counter.bigEndian
		let counterBytes = withUnsafeBytes( of: &count ) { Data( $0 ) }
		return hmac( session, [ Data( [ direction.rawValue ] ), counterBytes, payload ] ).prefix( macSize )
	}

	// MARK: devOTA

	/// devOTA's password hash, AES-256-GCM under HMAC( S, "espdeck-devota" ), with the counter
	/// of the Mac → ESP32 frame that carries it as the nonce: ciphertext, then the 16-byte tag.
	static func sealDevOTA( session: Data, counter: UInt64, passwordHash: Data ) -> Data? {
		guard let box = try? AES.GCM.seal( passwordHash, using: devOTAKey( session ), nonce: devOTANonce( counter ) ) else { return nil }
		// A fresh Data: the ciphertext is a slice that doesn't start at index 0, and so would
		// their sum, which traps a caller that indexes from 0.
		return Data( box.ciphertext + box.tag )
	}

	/// The inverse of sealDevOTA; only tools/crypto_test uses it, to check the round trip.
	static func openDevOTA( session: Data, counter: UInt64, sealed: Data ) -> Data? {
		guard sealed.count > 16, let box = try? AES.GCM.SealedBox( nonce: devOTANonce( counter ), ciphertext: sealed.dropLast( 16 ), tag: sealed.suffix( 16 ) ) else { return nil }
		return try? AES.GCM.open( box, using: devOTAKey( session ) )
	}

	/// HMAC( S, "espdeck-devota" ).
	private static func devOTAKey( _ session: Data ) -> SymmetricKey {
		SymmetricKey( data: hmac( session, [ utf8( "espdeck-devota" ) ] ) )
	}

	/// The Mac → ESP32 direction byte, three zero bytes, and the frame counter, big-endian.
	private static func devOTANonce( _ counter: UInt64 ) -> AES.GCM.Nonce {
		var count = counter.bigEndian
		let bytes = Data( [ Direction.toDevice.rawValue, 0, 0, 0 ] ) + withUnsafeBytes( of: &count ) { Data( $0 ) }
		return try! AES.GCM.Nonce( data: bytes )   // always 12 bytes
	}

	/// Constant-time comparison for proofs and MACs.
	static func equal( _ a: Data, _ b: Data ) -> Bool {
		guard a.count == b.count else { return false }
		return zip( a, b ).reduce( UInt8( 0 ) ) { $0 | ( $1.0 ^ $1.1 ) } == 0
	}
}

extension Data {
	/// Two lowercase hex digits per byte.
	var hex: String { map { String( format: "%02x", $0 ) }.joined() }

	/// Exactly two hex digits (either case) per byte, and nothing else: no signs, spaces or "0x".
	init?( hex: String ) {
		let digits = Array( hex.utf8 )
		guard digits.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity( digits.count / 2 )
		for index in stride( from: 0, to: digits.count, by: 2 ) {
			guard let high = Self.nibble( digits[index] ), let low = Self.nibble( digits[index + 1] ) else { return nil }
			bytes.append( high << 4 | low )
		}
		self.init( bytes )
	}

	/// A hex digit's value.
	private static func nibble( _ digit: UInt8 ) -> UInt8? {
		switch digit {
			case UInt8( ascii: "0" )...UInt8( ascii: "9" ): digit - UInt8( ascii: "0" )
			case UInt8( ascii: "a" )...UInt8( ascii: "f" ): digit - UInt8( ascii: "a" ) + 10
			case UInt8( ascii: "A" )...UInt8( ascii: "F" ): digit - UInt8( ascii: "A" ) + 10
			default:                                        nil
		}
	}
}
