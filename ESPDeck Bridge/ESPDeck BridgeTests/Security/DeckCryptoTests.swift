//
//  DeckCryptoTests.swift
//  ESPDeck BridgeTests
//
//  The derivations themselves are checked against the firmware's by tools/crypto_test in
//  ESPDeck Device. These cover what that can't: that a frame's MAC is bound to its place in
//  the session, that devOTA's sealing opens only as sealed, and the hex and comparison
//  helpers everything else leans on.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

/// Frame MACs, devOTA sealing, pairing codes, and the helpers around them.
struct DeckCryptoTests {
	private let session = Data( repeating: 0x5A, count: 32 )
	private let payload = Data( "{\"type\":\"keyDown\",\"key\":3}".utf8 )

	/// The same frame always has the same MAC, of the length the protocol sends.
	@Test func frameMACIsStableAndTruncated() {
		let first  = DeckCrypto.frameMAC( session: session, direction: .toDevice, counter: 7, payload: payload )
		let second = DeckCrypto.frameMAC( session: session, direction: .toDevice, counter: 7, payload: payload )
		#expect( first == second )
		#expect( first.count == DeckCrypto.macSize )
	}

	/// A frame can't be replayed later, sent back the other way, or altered.
	@Test func frameMACIsBoundToCounterDirectionAndPayload() {
		let mac = DeckCrypto.frameMAC( session: session, direction: .toDevice, counter: 7, payload: payload )
		#expect( mac != DeckCrypto.frameMAC( session: session, direction: .toDevice, counter: 8, payload: payload ) )
		#expect( mac != DeckCrypto.frameMAC( session: session, direction: .toBridge, counter: 7, payload: payload ) )
		#expect( mac != DeckCrypto.frameMAC( session: session, direction: .toDevice, counter: 7, payload: payload + Data( [ 0 ] ) ) )
		#expect( mac != DeckCrypto.frameMAC( session: Data( repeating: 0x5B, count: 32 ), direction: .toDevice, counter: 7, payload: payload ) )
	}

	/// What's sealed opens to the same bytes, and carries its 16-byte tag.
	@Test func devOTARoundTrips() throws {
		let hash   = Data( repeating: 0xC3, count: 32 )
		let sealed = try #require( DeckCrypto.sealDevOTA( session: session, counter: 12, passwordHash: hash ) )
		#expect( sealed.count == hash.count + 16 )
		#expect( DeckCrypto.openDevOTA( session: session, counter: 12, sealed: sealed ) == hash )
	}

	/// It opens only under the counter and session it was sealed with, and not if altered.
	@Test func devOTARejectsTheWrongCounterSessionOrBytes() throws {
		let hash   = Data( repeating: 0xC3, count: 32 )
		let sealed = try #require( DeckCrypto.sealDevOTA( session: session, counter: 12, passwordHash: hash ) )
		var altered = sealed
		altered[0] ^= 0x01
		#expect( DeckCrypto.openDevOTA( session: session, counter: 13, sealed: sealed ) == nil )
		#expect( DeckCrypto.openDevOTA( session: Data( repeating: 0x5B, count: 32 ), counter: 12, sealed: sealed ) == nil )
		#expect( DeckCrypto.openDevOTA( session: session, counter: 12, sealed: altered ) == nil )
		#expect( DeckCrypto.openDevOTA( session: session, counter: 12, sealed: Data( repeating: 0, count: 16 ) ) == nil )
	}

	/// Always six digits, leading zeros kept, and different when either side's nonce is.
	@Test func pairingCodeIsSixDigitsAndDependsOnBothNonces() {
		let macKey = Data( repeating: 1, count: 32 ), deckKey = Data( repeating: 2, count: 32 )
		let macNonce = Data( repeating: 3, count: 16 ), deckNonce = Data( repeating: 4, count: 16 )
		let code = DeckCrypto.pairingCode( macPublicKey: macKey, devicePublicKey: deckKey, macNonce: macNonce, deviceNonce: deckNonce )
		#expect( code.count == 6 )
		#expect( code.allSatisfy { $0.isNumber } )
		#expect( code == DeckCrypto.pairingCode( macPublicKey: macKey, devicePublicKey: deckKey, macNonce: macNonce, deviceNonce: deckNonce ) )
		#expect( code != DeckCrypto.pairingCode( macPublicKey: macKey, devicePublicKey: deckKey, macNonce: Data( repeating: 5, count: 16 ), deviceNonce: deckNonce ) )
		#expect( code != DeckCrypto.pairingCode( macPublicKey: macKey, devicePublicKey: deckKey, macNonce: macNonce, deviceNonce: Data( repeating: 5, count: 16 ) ) )
	}

	/// Equal only for the same bytes at the same length.
	@Test func comparesProofsExactly() {
		let proof = Data( [ 1, 2, 3, 4 ] )
		#expect( DeckCrypto.equal( proof, Data( [ 1, 2, 3, 4 ] ) ) )
		#expect( DeckCrypto.equal( proof, Data( [ 1, 2, 3, 5 ] ) ) == false )
		#expect( DeckCrypto.equal( proof, Data( [ 1, 2, 3 ] ) ) == false )
		#expect( DeckCrypto.equal( Data(), Data() ) )
	}

	/// Hex reads back to the same bytes, in either case.
	@Test func hexRoundTrips() {
		let bytes = Data( [ 0x00, 0x0F, 0xA5, 0xFF ] )
		#expect( bytes.hex == "000fa5ff" )
		#expect( Data( hex: "000fa5ff" ) == bytes )
		#expect( Data( hex: "000FA5FF" ) == bytes )
	}

	/// Anything that isn't whole bytes of hex digits is refused, not guessed at.
	@Test( arguments: [ "abc", "0x12", "12 34", "zz", "-1" ] )
	func hexRejectsMalformedInput( _ string: String ) {
		#expect( Data( hex: string ) == nil )
	}
}
