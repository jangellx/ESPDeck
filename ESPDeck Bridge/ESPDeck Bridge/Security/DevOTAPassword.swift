//
//  DevOTAPassword.swift
//  ESPDeck Bridge
//
//  The password for uploads from PlatformIO (ArduinoOTA). Each Mac has one, generated the
//  first time it's needed and kept in the Keychain so it can be shown again and used for
//  every device. Devices only ever get its hash; the developer puts the password itself in
//  ota_password.txt for PlatformIO.
//
//  Its Keychain access is its own rather than KeychainItem's: tools/crypto_test compiles this
//  file with DeckCrypto.swift alone.
//

import CryptoKit
import Foundation
import Security

/// This Mac's password for uploads from PlatformIO: making, checking and keeping it.
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

	/// Where it's kept: the same Keychain access as the pairing keys (KeychainItem). It used to
	/// have its own copy, which deleted "the login keychain's copy" after storing and so lost
	/// the password at every launch: in this app both keychains are the same one.
	private static let item = KeychainItem( service: service, account: account )

	/// This Mac's password, if it has one yet.
	static func stored() -> String? {
		item.read().map { String( decoding: $0, as: UTF8.self ) }
	}

	/// Replaces this Mac's password in place (or adds it), so the old one is never gone before
	/// the new one is stored, and checks it reads back.
	@discardableResult
	static func store( _ password: String ) -> Bool {
		item.store( Data( password.utf8 ), label: "ESPDeck developer password", logTag: "DevOTAPassword" )
	}

	/// This Mac no longer has a password: moving the bridge away, or importing one without.
	static func delete() {
		item.delete()
	}
}
