//
//  BridgeIdentity.swift
//  ESPDeck Bridge
//
//  This bridge's ID, which decks remember when they're paired, kept outside
//  Settings.json as well: in the Keychain (next to the pairing keys) and in a small file.
//  Settings that had to be started over then keep the same ID, and the decks paired with
//  this Mac don't all show as paired with another bridge.
//

import Foundation
import Security

enum BridgeIdentity {
	private static let service = "ESPDeck Bridge identity"
	private static let account = "bridgeID"

	/// The ID kept outside the settings, if any.
	static func stored( fileIn directory: URL ) -> String? {
		keychainValue() ?? ( try? String( contentsOf: fileURL( directory ), encoding: .utf8 ) ).flatMap( valid )
	}

	/// Keeps `id` in both places, unless it's already there.
	static func store( _ id: String, fileIn directory: URL ) {
		if keychainValue() != id {
			storeInKeychain( id )
		}
		let url = fileURL( directory )
		if ( try? String( contentsOf: url, encoding: .utf8 ) ).flatMap( valid ) != id {
			try? Data( id.utf8 ).write( to: url, options: .atomic )
		}
	}

	private static func fileURL( _ directory: URL ) -> URL {
		directory.appending( path: "BridgeID" )
	}

	private static func valid( _ text: String ) -> String? {
		let id = text.trimmingCharacters( in: .whitespacesAndNewlines )
		return id.isEmpty || id.count > 64 ? nil : id
	}

	// MARK: - Keychain
	//
	// As PairingKeyStore: the data-protection keychain when the signing allows it, else the
	// login keychain.

	private static func keychainValue() -> String? {
		for dataProtection in [ true, false ] {
			var query = base( dataProtection: dataProtection )
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne

			var result: AnyObject?
			if SecItemCopyMatching( query as CFDictionary, &result ) == errSecSuccess, let data = result as? Data,
			   let id = valid( String( decoding: data, as: UTF8.self ) ) {
				return id
			}
		}
		return nil
	}

	private static func storeInKeychain( _ id: String ) {
		for dataProtection in [ true, false ] {
			SecItemDelete( base( dataProtection: dataProtection ) as CFDictionary )
		}
		for dataProtection in [ true, false ] {
			var query = base( dataProtection: dataProtection )
			query[kSecValueData as String]      = Data( id.utf8 )
			query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			query[kSecAttrLabel as String]      = "ESPDeck Bridge ID"
			if SecItemAdd( query as CFDictionary, nil ) == errSecSuccess { return }
		}
		print( "[BridgeIdentity] Couldn't keep the bridge ID in the Keychain; the file still has it." )
	}

	private static func base( dataProtection: Bool ) -> [String: Any] {
		[
			kSecClass as String:                     kSecClassGenericPassword,
			kSecAttrService as String:               service,
			kSecAttrAccount as String:               account,
			kSecUseDataProtectionKeychain as String: dataProtection,
		]
	}
}
