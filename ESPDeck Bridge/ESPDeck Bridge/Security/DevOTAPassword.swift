//
//  DevOTAPassword.swift
//  ESPDeck Bridge
//
//  The password for uploads from PlatformIO (ArduinoOTA): what the device stores is its
//  hash, and the password itself stays with the developer (ota_password.txt).
//

import CryptoKit
import Foundation

enum DevOTAPassword {
	/// What ArduinoOTA's setPasswordHash() takes, and what espota derives from the password:
	/// the SHA-256 of its UTF-8 bytes, as 64 lowercase hex digits.
	static func hash( _ password: String ) -> String {
		SHA256.hash( data: Data( password.utf8 ) ).map { String( format: "%02x", $0 ) }.joined()
	}

	/// At least 8 characters, without spaces or quotes, so it goes into ota_password.txt and
	/// espota's command line as it is. Nil when it's fine.
	static func problem( _ password: String ) -> String? {
		if password.count < 8 { return "Passwords have at least 8 characters." }
		if password.contains( where: { $0.isWhitespace || "\"'`$\\".contains( $0 ) } ) {
			return "Passwords can't have spaces, quotes, backslashes, $ or `."
		}
		return nil
	}
}
