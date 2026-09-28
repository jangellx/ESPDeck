//
//  DevOTAPassword.swift
//  ESPDeck Bridge
//
//  The password for uploads from PlatformIO (ArduinoOTA). Each Mac has one, generated the
//  first time it's needed and kept in the Keychain so it can be shown again and used for
//  every device. Devices only ever get its hash; the developer puts the password itself in
//  ota_password.txt for PlatformIO.
//

import CryptoKit
import Foundation
import Security

nonisolated enum DevOTAPassword {
	/// Letters, digits, - and _: nothing a shell, espota's --auth or ota_password.txt treats
	/// specially.
	static let alphabet = Array( "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" )
	static let generatedLength = 20

	/// A new random password (about 120 bits from the system's secure generator).
	static func generate() -> String {
		var random = SystemRandomNumberGenerator()
		return String( ( 0..<generatedLength ).map { _ in alphabet.randomElement( using: &random )! } )
	}

	/// What ArduinoOTA's setPasswordHash() takes, and what espota derives from the password:
	/// the SHA-256 of its UTF-8 bytes, as 64 lowercase hex digits.
	static func hash( _ password: String ) -> String {
		SHA256.hash( data: Data( password.utf8 ) ).map { String( format: "%02x", $0 ) }.joined()
	}

	/// For a password the user picks: at least 8 characters, without spaces or quotes, so it
	/// goes into ota_password.txt and espota's command line as it is. Nil when it's fine.
	static func problem( _ password: String ) -> String? {
		if password.count < 8 { return "Passwords have at least 8 characters." }
		if password.contains( where: { $0.isWhitespace || "\"'`$\\".contains( $0 ) } ) {
			return "Passwords can't have spaces, quotes, backslashes, $ or `."
		}
		return nil
	}

	/// The contents of ota_password.txt: the password alone. tools/dev_ota.py strips
	/// surrounding whitespace, so an editor's trailing newline doesn't matter either.
	static func fileContents( _ password: String ) -> Data {
		Data( password.utf8 )
	}

	// MARK: - Keychain

	private static let service = "ESPDeck Bridge developer password"
	private static let account = "PlatformIO uploads"

	/// This Mac's password, if it has one yet.
	static func stored() -> String? {
		for dataProtection in [ true, false ] {
			var query = base( dataProtection: dataProtection )
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne
			var result: AnyObject?
			if SecItemCopyMatching( query as CFDictionary, &result ) == errSecSuccess, let data = result as? Data {
				return String( decoding: data, as: UTF8.self )
			}
		}
		return nil
	}

	/// Replaces this Mac's password in place (or adds it), so the old one is never gone before
	/// the new one is stored. The data-protection keychain when the app's signing allows it,
	/// else the login keychain, as for the pairing keys.
	@discardableResult
	static func store( _ password: String ) -> Bool {
		let data = Data( password.utf8 )
		for dataProtection in [ true, false ] {
			let query  = base( dataProtection: dataProtection )
			var status = SecItemUpdate( query as CFDictionary, [ kSecValueData as String: data ] as CFDictionary )
			if status == errSecItemNotFound {
				var item = query
				item[kSecValueData as String]      = data
				item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				item[kSecAttrLabel as String]      = "ESPDeck developer password"
				status = SecItemAdd( item as CFDictionary, nil )
			}
			if status == errSecSuccess {
				if dataProtection {
					SecItemDelete( base( dataProtection: false ) as CFDictionary )   // an older, stale copy
				}
				return true
			}
			print( "[DevOTAPassword] Storing in the \(dataProtection ? "data-protection" : "login") keychain failed: \(status)" )
		}
		return false
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
