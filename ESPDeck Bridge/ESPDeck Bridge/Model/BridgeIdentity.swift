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

/// Keeps the bridge ID in the Keychain and in a file beside the settings.
enum BridgeIdentity {
	private static let item = KeychainItem( service: "ESPDeck Bridge identity", account: "bridgeID" )

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

	/// The file's place in the settings folder.
	private static func fileURL( _ directory: URL ) -> URL {
		directory.appending( path: "BridgeID" )
	}

	/// The ID in `text`, trimmed; nil if it's empty or too long to be one.
	private static func valid( _ text: String ) -> String? {
		let id = text.trimmingCharacters( in: .whitespacesAndNewlines )
		return id.isEmpty || id.count > 64 ? nil : id
	}

	// MARK: - Keychain
	//
	// As the pairing keys (KeychainItem): the data-protection keychain when the signing
	// allows it, else the login keychain.

	/// The first valid ID either keychain has.
	private static func keychainValue() -> String? {
		for dataProtection in [ true, false ] {
			var query = item.query( dataProtection: dataProtection )
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

	/// Replaces the ID in the Keychain: in the first keychain that takes it.
	private static func storeInKeychain( _ id: String ) {
		item.delete()
		for dataProtection in [ true, false ] {
			var query = item.query( dataProtection: dataProtection )
			query[kSecValueData as String]      = Data( id.utf8 )
			query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			query[kSecAttrLabel as String]      = "ESPDeck Bridge ID"
			if SecItemAdd( query as CFDictionary, nil ) == errSecSuccess { return }
		}
		print( "[BridgeIdentity] Couldn't keep the bridge ID in the Keychain; the file still has it." )
	}
}
