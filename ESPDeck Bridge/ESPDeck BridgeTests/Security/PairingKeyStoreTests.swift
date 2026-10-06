//
//  PairingKeyStoreTests.swift
//  ESPDeck BridgeTests
//
//  A pairing key that isn't really in the Keychain only shows at the next launch, as a deck
//  that has to be unpaired and paired again. That happened: storing a key also deleted it,
//  while the in-memory cache hid the loss until the app quit. These go to the real Keychain,
//  under IDs no deck has, and remove what they add.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

/// Pairing keys really reach the Keychain, and really leave it.
struct PairingKeyStoreTests {
	/// A device ID of this test's own, so tests running side by side don't share one.
	private let deviceID = "test:" + UUID().uuidString.lowercased()
	private let key      = Data( ( 0..<32 ).map { _ in UInt8.random( in: 0...255 ) } )

	/// What the app would find at its next launch: read straight from the Keychain, not from
	/// the store's cache.
	@Test func aStoredKeyIsInTheKeychain() {
		defer { PairingKeyStore.delete( deviceID ) }
		#expect( PairingKeyStore.store( key, for: deviceID ) )
		#expect( PairingKeyStore.read( deviceID ) == key, "the key must outlive the cache" )
		#expect( PairingKeyStore.storedDeviceIDs().contains( deviceID ) )
	}

	/// Pairing again replaces the key; the old one doesn't come back.
	@Test func storingAgainReplacesTheKey() {
		defer { PairingKeyStore.delete( deviceID ) }
		let newer = Data( repeating: 0x42, count: 32 )
		#expect( PairingKeyStore.store( key, for: deviceID ) )
		#expect( PairingKeyStore.store( newer, for: deviceID ) )
		#expect( PairingKeyStore.read( deviceID ) == newer )
	}

	/// Forgetting a deck takes its key out of the Keychain, and out of the cache.
	@Test func aDeletedKeyIsGone() {
		#expect( PairingKeyStore.store( key, for: deviceID ) )
		PairingKeyStore.delete( deviceID )
		#expect( PairingKeyStore.read( deviceID ) == nil )
		#expect( PairingKeyStore.key( for: deviceID ) == nil )
		#expect( PairingKeyStore.isMissing( deviceID ) )
	}
}
