//
//  DeckCrypto.swift
//  ESPDeck Bridge
//
//  The key derivations from PROTOCOL.md's Security section. Byte strings are
//  concatenated in the order listed; labels are UTF-8 without a terminator.
//

import CryptoKit
import Foundation

enum DeckCrypto {
	static let nonceSize = 16
	static let macSize   = 16

	/// Mac → ESP32 and ESP32 → Mac, for frame MACs.
	enum Direction: UInt8 {
		case toDevice = 0x01
		case toBridge = 0x02
	}

	static func randomBytes( _ count: Int ) -> Data {
		var bytes = [UInt8]( repeating: 0, count: count )
		_ = SecRandomCopyBytes( kSecRandomDefault, count, &bytes )
		return Data( bytes )
	}

	static func hmac( _ key: Data, _ parts: [Data] ) -> Data {
		var mac = HMAC<SHA256>( key: SymmetricKey( data: key ) )
		for part in parts { mac.update( data: part ) }
		return Data( mac.finalize() )
	}

	private static func utf8( _ string: String ) -> Data { Data( string.utf8 ) }

	// MARK: Pairing

	/// Six digits both sides show; they differ if anyone is in the middle.
	static func pairingCode( sharedSecret: Data ) -> String {
		let digest = Data( SHA256.hash( data: utf8( "espdeck-pair-code" ) + sharedSecret ) )
		let value  = digest.prefix( 4 ).reduce( UInt32( 0 ) ) { $0 << 8 | UInt32( $1 ) }
		return String( format: "%06u", value % 1_000_000 )
	}

	static func pairingKey( sharedSecret: Data, bridgeID: String, deviceID: String ) -> Data {
		hmac( sharedSecret, [ utf8( "espdeck-pairing-key" ), utf8( bridgeID ), utf8( deviceID ) ] )
	}

	static func pairConfirmProof( key: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-pair-confirm" ) ] )
	}

	// MARK: Authentication

	static func bridgeProof( key: Data, deviceNonce: Data, bridgeNonce: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-bridge" ), deviceNonce, bridgeNonce ] )
	}

	static func deviceProof( key: Data, bridgeNonce: Data, deviceNonce: Data, hello: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-device" ), bridgeNonce, deviceNonce, Data( SHA256.hash( data: hello ) ) ] )
	}

	static func sessionKey( key: Data, deviceNonce: Data, bridgeNonce: Data ) -> Data {
		hmac( key, [ utf8( "espdeck-session" ), deviceNonce, bridgeNonce ] )
	}

	static func frameMAC( session: Data, direction: Direction, counter: UInt64, payload: Data ) -> Data {
		var count = counter.bigEndian
		let counterBytes = withUnsafeBytes( of: &count ) { Data( $0 ) }
		return hmac( session, [ Data( [ direction.rawValue ] ), counterBytes, payload ] ).prefix( macSize )
	}

	/// Constant-time comparison for proofs and MACs.
	static func equal( _ a: Data, _ b: Data ) -> Bool {
		guard a.count == b.count else { return false }
		return zip( a, b ).reduce( UInt8( 0 ) ) { $0 | ( $1.0 ^ $1.1 ) } == 0
	}
}

extension Data {
	var hex: String { map { String( format: "%02x", $0 ) }.joined() }

	init?( hex: String ) {
		let digits = Array( hex.utf8 )
		guard digits.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity( digits.count / 2 )
		for index in stride( from: 0, to: digits.count, by: 2 ) {
			guard let pair = String( bytes: digits[index...index + 1], encoding: .ascii ), let byte = UInt8( pair, radix: 16 ) else { return nil }
			bytes.append( byte )
		}
		self.init( bytes )
	}
}
