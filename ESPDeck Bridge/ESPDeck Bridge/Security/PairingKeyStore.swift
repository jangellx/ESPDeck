//
//  PairingKeyStore.swift
//  ESPDeck Bridge
//
//  Pairing keys, one per device ID, in the Keychain. Uses the data-protection keychain
//  when the app's signing allows it (no prompts across rebuilds), else the login keychain.
//

import Foundation
import Security

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

	static func key( for deviceID: String ) -> Data? {
		if let cached = cache[deviceID] { return cached }
		if missing.contains( deviceID ) { return nil }
		var definitelyMissing = true
		for dataProtection in [ true, false ] {
			var query = base( deviceID, dataProtection: dataProtection )
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne

			var result: AnyObject?
			let status = SecItemCopyMatching( query as CFDictionary, &result )
			if status == errSecSuccess, let data = result as? Data {
				cache[deviceID] = data
				return data
			}
			if status != errSecItemNotFound {
				definitelyMissing = false
				print( "[PairingKeyStore] Reading the key for \(deviceID) (\(dataProtection ? "data protection" : "login") keychain) failed: \(status)" )
			}
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
		for dataProtection in [ true, false ] {
			var query = base( deviceID, dataProtection: dataProtection )
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne
			var result: AnyObject?
			if SecItemCopyMatching( query as CFDictionary, &result ) == errSecSuccess, let data = result as? Data {
				return data
			}
		}
		return nil
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
		for dataProtection in [ true, false ] {
			let query  = base( deviceID, dataProtection: dataProtection )
			var status = SecItemUpdate( query as CFDictionary, [ kSecValueData as String: key ] as CFDictionary )
			if status == errSecItemNotFound {
				var item = query
				item[kSecValueData as String]      = key
				item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				item[kSecAttrLabel as String]      = "ESPDeck \(deviceID)"
				status = SecItemAdd( item as CFDictionary, nil )
			}
			if status == errSecSuccess {
				if dataProtection {
					// An older copy in the login keychain would only be stale.
					SecItemDelete( base( deviceID, dataProtection: false ) as CFDictionary )
				}
				cache[deviceID] = key
				missing.remove( deviceID )
				return true
			}
			// -34018: missing keychain entitlement for the data-protection keychain.
			print( "[PairingKeyStore] Storing in the \(dataProtection ? "data-protection" : "login") keychain failed: \(status)" )
		}
		return false
	}

	static func delete( _ deviceID: String ) {
		cache[deviceID] = nil
		missing.insert( deviceID )
		for dataProtection in [ true, false ] {
			SecItemDelete( base( deviceID, dataProtection: dataProtection ) as CFDictionary )
		}
	}

	/// Every device ID with a key, in either keychain: for moving the bridge to another Mac.
	static func storedDeviceIDs() -> Set<String> {
		var ids = Set<String>()
		for dataProtection in [ true, false ] {
			var query = base( "", dataProtection: dataProtection )
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

	nonisolated private static func base( _ deviceID: String, dataProtection: Bool ) -> [String: Any] {
		[
			kSecClass as String:                     kSecClassGenericPassword,
			kSecAttrService as String:               service,
			kSecAttrAccount as String:               deviceID,
			kSecUseDataProtectionKeychain as String: dataProtection,
		]
	}
}
