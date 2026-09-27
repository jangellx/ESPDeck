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
	private static let service = "ESPDeck Bridge pairing key"
	/// Keys already read, so a reconnect doesn't go to the Keychain on the main thread.
	private static var cache: [String: Data] = [:]

	static func key( for deviceID: String ) -> Data? {
		if let cached = cache[deviceID] { return cached }
		for dataProtection in [ true, false ] {
			var query = base( deviceID, dataProtection: dataProtection )
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne

			var result: AnyObject?
			if SecItemCopyMatching( query as CFDictionary, &result ) == errSecSuccess, let data = result as? Data {
				cache[deviceID] = data
				return data
			}
		}
		return nil
	}

	@discardableResult
	static func store( _ key: Data, for deviceID: String ) -> Bool {
		delete( deviceID )
		for dataProtection in [ true, false ] {
			var query = base( deviceID, dataProtection: dataProtection )
			query[kSecValueData as String]      = key
			query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			query[kSecAttrLabel as String]      = "ESPDeck \(deviceID)"

			let status = SecItemAdd( query as CFDictionary, nil )
			if status == errSecSuccess {
				cache[deviceID] = key
				return true
			}
			// -34018: missing keychain entitlement for the data-protection keychain.
			print( "[PairingKeyStore] Storing in the \(dataProtection ? "data-protection" : "login") keychain failed: \(status)" )
		}
		return false
	}

	static func delete( _ deviceID: String ) {
		cache[deviceID] = nil
		for dataProtection in [ true, false ] {
			SecItemDelete( base( deviceID, dataProtection: dataProtection ) as CFDictionary )
		}
	}

	private static func base( _ deviceID: String, dataProtection: Bool ) -> [String: Any] {
		[
			kSecClass as String:                     kSecClassGenericPassword,
			kSecAttrService as String:               service,
			kSecAttrAccount as String:               deviceID,
			kSecUseDataProtectionKeychain as String: dataProtection,
		]
	}
}
