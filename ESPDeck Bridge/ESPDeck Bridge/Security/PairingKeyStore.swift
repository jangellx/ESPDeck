//
//  PairingKeyStore.swift
//  ESPDeck Bridge
//
//  Pairing keys, one per device ID, in the Keychain; and KeychainItem, the Keychain access
//  they share with the bridge ID: the data-protection keychain when the app's signing allows
//  it (no prompts across rebuilds), else the login keychain.
//

import Foundation
import Security

/// Pairing keys by device ID, cached so the main thread rarely waits on the Keychain.
enum PairingKeyStore {
	nonisolated private static let service = "ESPDeck Bridge pairing key"
	/// Keys already read, so a reconnect doesn't go to the Keychain on the main thread…
	private static var cache: [String: Data] = [:]
	/// …and IDs the Keychain definitely has none for (errSecItemNotFound), so hellos from
	/// unknown devices (or anyone making them up) don't either. Any other failure isn't
	/// remembered: one caching a paired device's key as missing, until the app quit, left it
	/// "needing unpairing" and unable to connect. Cleared when it gets large.
	private static var missing: Set<String> = []
	private static let missingLimit = 256

	/// The device's pairing key: from the cache, else the Keychain. A key the Keychain
	/// definitely doesn't have is remembered as missing.
	static func key( for deviceID: String ) -> Data? {
		if let cached = cache[deviceID] { return cached }
		if missing.contains( deviceID ) { return nil }
		var definitelyMissing = true
		let key = item( deviceID ).read { status, dataProtection in
			definitelyMissing = false
			print( "[PairingKeyStore] Reading the key for \(deviceID) (\(dataProtection ? "data protection" : "login") keychain) failed: \(status)" )
		}
		if let key {
			cache[deviceID] = key
			return key
		}
		if definitelyMissing {
			if missing.count >= missingLimit { missing.removeAll() }
			missing.insert( deviceID )
		}
		return nil
	}

	/// Straight from the Keychain, bypassing (and not touching) the caches, so it can run off
	/// the main thread: for checking again on a key that couldn't be read, when the Keychain
	/// may be slow to answer. remember() it if found.
	nonisolated static func read( _ deviceID: String ) -> Data? {
		item( deviceID ).read()
	}

	/// The Keychain said it has no key for this device (errSecItemNotFound), rather than
	/// failing to answer: checking again won't find one.
	static func isMissing( _ deviceID: String ) -> Bool {
		missing.contains( deviceID )
	}

	/// A key read() found.
	static func remember( _ key: Data, for deviceID: String ) {
		cache[deviceID] = key
		missing.remove( deviceID )
	}

	/// Replaces the key in place (or adds it), so the old one is never gone before the new one
	/// is stored.
	@discardableResult
	static func store( _ key: Data, for deviceID: String ) -> Bool {
		guard item( deviceID ).store( key, label: "ESPDeck \(deviceID)", logTag: "PairingKeyStore" ) else { return false }
		cache[deviceID] = key
		missing.remove( deviceID )
		return true
	}

	/// Removes the device's key from the Keychain; it's then known to be missing.
	static func delete( _ deviceID: String ) {
		cache[deviceID] = nil
		missing.insert( deviceID )
		item( deviceID ).delete()
	}

	/// Every device ID with a key, in either keychain: for moving the bridge to another Mac.
	static func storedDeviceIDs() -> Set<String> {
		var ids = Set<String>()
		for dataProtection in [ true, false ] {
			var query = item( "" ).query( dataProtection: dataProtection )
			query[kSecAttrAccount as String]      = nil
			query[kSecReturnAttributes as String] = true
			query[kSecMatchLimit as String]       = kSecMatchLimitAll

			var result: AnyObject?
			if SecItemCopyMatching( query as CFDictionary, &result ) == errSecSuccess, let items = result as? [[String: Any]] {
				ids.formUnion( items.compactMap { $0[kSecAttrAccount as String] as? String } )
			}
		}
		return ids
	}

	/// Replaces every key with `keys` (device ID → key). False if one couldn't be stored.
	@discardableResult
	static func replaceAll( with keys: [String: Data] ) -> Bool {
		for deviceID in storedDeviceIDs() where keys[deviceID] == nil {
			delete( deviceID )
		}
		var stored = true
		for ( deviceID, key ) in keys {
			stored = store( key, for: deviceID ) && stored
		}
		return stored
	}

	/// The device's key in the Keychain.
	nonisolated private static func item( _ deviceID: String ) -> KeychainItem {
		KeychainItem( service: service, account: deviceID )
	}
}

/// A generic password in the Keychain: in the data-protection keychain when the app's signing
/// allows it (no prompts across rebuilds), else the login keychain. Each operation tries them
/// in that order.
nonisolated struct KeychainItem: Sendable {
	let service : String
	let account : String

	/// The item's query in one keychain.
	func query( dataProtection: Bool ) -> [String: Any] {
		[
			kSecClass as String:                     kSecClassGenericPassword,
			kSecAttrService as String:               service,
			kSecAttrAccount as String:               account,
			kSecUseDataProtectionKeychain as String: dataProtection,
		]
	}

	/// The item's data from the first keychain that has it. `failed` hears of each keychain
	/// that didn't answer found or not found.
	func read( failed: ( _ status: OSStatus, _ dataProtection: Bool ) -> Void = { _, _ in } ) -> Data? {
		for dataProtection in [ true, false ] {
			var request = query( dataProtection: dataProtection )
			request[kSecReturnData as String] = true
			request[kSecMatchLimit as String] = kSecMatchLimitOne

			var result: AnyObject?
			let status = SecItemCopyMatching( request as CFDictionary, &result )
			if status == errSecSuccess, let data = result as? Data {
				return data
			}
			if status != errSecItemNotFound {
				failed( status, dataProtection )
			}
		}
		return nil
	}

	/// Replaces the item's data in place (or adds it), so the old data is never gone before the
	/// new is stored. `label` names a new item; `logTag` is for the console.
	@discardableResult
	func store( _ data: Data, label: String, logTag: String ) -> Bool {
		for dataProtection in [ true, false ] {
			let request = query( dataProtection: dataProtection )
			var status  = SecItemUpdate( request as CFDictionary, [ kSecValueData as String: data ] as CFDictionary )
			if status == errSecItemNotFound {
				var item = request
				item[kSecValueData as String]      = data
				item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				item[kSecAttrLabel as String]      = label
				status = SecItemAdd( item as CFDictionary, nil )
			}
			if status == errSecSuccess {
				if dataProtection {
					// An older copy in the login keychain would only be stale.
					SecItemDelete( query( dataProtection: false ) as CFDictionary )
				}
				return true
			}
			// -34018: missing keychain entitlement for the data-protection keychain.
			print( "[\(logTag)] Storing in the \(dataProtection ? "data-protection" : "login") keychain failed: \(status)" )
		}
		return false
	}

	/// Removes the item from both keychains.
	func delete() {
		for dataProtection in [ true, false ] {
			SecItemDelete( query( dataProtection: dataProtection ) as CFDictionary )
		}
	}
}
