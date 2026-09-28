//
//  BridgeTransfer.swift
//  ESPDeck Bridge
//
//  The file that moves a bridge to another Mac (File ▸ Export Bridge… and Import Bridge…):
//  its ID, every device's pairing key, the settings and icons, and the developer password,
//  encrypted with a passphrase. Anyone with the file and the passphrase can control the
//  decks, so it's as sensitive as they are.
//
//  Layout (all of it read before decrypting, and all of it authenticated):
//    "ESPDeckBridge"      13-byte magic
//    container version    1 byte (1)
//    header length        2 bytes, big-endian
//    header               JSON: kdf, iterations, salt, cipher, nonce
//    sealed archive       AES-256-GCM ciphertext of the archive's JSON, then the 16-byte tag
//  The key is PBKDF2-HMAC-SHA256 of the passphrase (Unicode NFC, UTF-8) with the header's
//  salt and iterations, calibrated when exporting to take about 0.75 s on that Mac. The
//  associated data is everything before the sealed archive, so the header can't be changed
//  either. A wrong passphrase and a changed file look the same: the tag doesn't match.
//
//  Kept to Foundation, CryptoKit and CommonCrypto so tools/security_test can compile it on
//  its own.
//

import CommonCrypto
import CryptoKit
import Foundation

/// A bridge, as exported: everything another Mac needs to answer the decks as this one.
nonisolated struct BridgeArchive: Codable, Equatable, Sendable {
	struct Device: Codable, Equatable, Sendable {
		var id     : String
		var name   : String
		var isDemo : Bool
		/// This Mac had its pairing key.
		var paired : Bool
	}

	/// What this version writes; a newer one can't be imported.
	static let currentFormat = 1

	var format            = BridgeArchive.currentFormat
	var appVersion        : String
	var exported          : Date
	/// The exporting Mac's name, for the summary on import.
	var macName           : String
	var bridgeID          : String
	/// For the summary; the settings are what's imported.
	var devices           : [Device]
	/// Settings.json, as ConfigStore writes it.
	var settings          : Data
	/// Device ID → pairing key.
	var pairingKeys       : [String: Data]
	var developerPassword : String?
	/// File name → PNG, from the Icons and Shortcut Icons folders.
	var icons             : [String: Data]
	var shortcutIcons     : [String: Data]

	/// Names that are safe to write into the icon folders: letters, digits, - _ and . only,
	/// not starting with a dot.
	static func isSafeFileName( _ name: String ) -> Bool {
		!name.isEmpty && name.count <= 128 && !name.hasPrefix( "." )
			&& name.unicodeScalars.allSatisfy { $0.isASCII && ( CharacterSet.alphanumerics.contains( $0 ) || "-_.".unicodeScalars.contains( $0 ) ) }
	}
}

nonisolated enum BridgeTransfer {
	static let fileExtension    = "espdeckbridge"
	static let magic            = Data( "ESPDeckBridge".utf8 )
	static let containerVersion : UInt8 = 1
	static let kdfName          = "pbkdf2-sha256"
	static let cipherName       = "aes-256-gcm"
	static let saltSize         = 16
	/// About this long to derive the key on the exporting Mac.
	static let calibrationMilliseconds: UInt32 = 750
	/// Exports never use fewer, however fast the Mac; imports refuse fewer or more (a file
	/// that asks for more would just hang the app).
	static let minimumIterations: UInt32 = 1_000_000
	static let maximumIterations: UInt32 = 50_000_000
	/// Larger than any real export: icons are small PNGs.
	static let maximumFileSize = 64 * 1024 * 1024
	static let minimumPassphraseLength = 10

	enum Problem: LocalizedError, Equatable {
		case notAnExport
		case newerVersion
		case damaged
		case wrongPassphrase
		case unreadable( String )
		case tooLarge

		var errorDescription: String? {
			switch self {
				case .notAnExport:           "That file isn't an ESPDeck Bridge export."
				case .newerVersion:          "That export was made by a newer version of ESPDeck Bridge. Update ESPDeck Bridge on this Mac, then import it again."
				case .damaged:               "That export is damaged: its header can't be read."
				case .wrongPassphrase:       "The passphrase is wrong, or the file was changed after it was exported."
				case .unreadable( let what ): "The export was decrypted, but its contents can't be used: \(what)."
				case .tooLarge:              "That file is too large to be an ESPDeck Bridge export."
			}
		}
	}

	struct Header: Codable, Equatable {
		var kdf        : String
		var iterations : UInt32
		var salt       : Data
		var cipher     : String
		var nonce      : Data
	}

	// MARK: - Passphrases

	/// Why a passphrase is too weak to export with; nil if it's fine.
	static func passphraseProblem( _ passphrase: String ) -> String? {
		if passphrase.count < minimumPassphraseLength {
			return "Use at least \(minimumPassphraseLength) characters."
		}
		if Set( passphrase.lowercased() ).count < 5 {
			return "Use more different characters."
		}
		return nil
	}

	/// The same bytes on every Mac for the same passphrase, however it was typed.
	private static func passphraseBytes( _ passphrase: String ) -> [UInt8] {
		Array( passphrase.precomposedStringWithCanonicalMapping.utf8 )
	}

	/// About `calibrationMilliseconds` of PBKDF2 on this Mac, and at least the minimum.
	static func calibratedIterations( passphrase: String ) -> UInt32 {
		let rounds = CCCalibratePBKDF( CCPBKDFAlgorithm( kCCPBKDF2 ), passphraseBytes( passphrase ).count, saltSize,
									   CCPseudoRandomAlgorithm( kCCPRFHmacAlgSHA256 ), kCCKeySizeAES256, calibrationMilliseconds )
		return min( max( rounds, minimumIterations ), maximumIterations )
	}

	/// PBKDF2-HMAC-SHA256 (CommonCrypto), `length` bytes.
	static func pbkdf2( password: [UInt8], salt: Data, iterations: UInt32, length: Int = kCCKeySizeAES256 ) -> Data? {
		guard !password.isEmpty, iterations > 0 else { return nil }
		var derived = [UInt8]( repeating: 0, count: length )
		let status  = password.withUnsafeBufferPointer { password in
			salt.withUnsafeBytes { salt in
				password.withMemoryRebound( to: CChar.self ) { password in
					CCKeyDerivationPBKDF( CCPBKDFAlgorithm( kCCPBKDF2 ), password.baseAddress, password.count,
										  salt.bindMemory( to: UInt8.self ).baseAddress, salt.count,
										  CCPseudoRandomAlgorithm( kCCPRFHmacAlgSHA256 ), iterations, &derived, length )
				}
			}
		}
		return status == kCCSuccess ? Data( derived ) : nil
	}

	private static func key( passphrase: String, header: Header ) -> SymmetricKey? {
		pbkdf2( password: passphraseBytes( passphrase ), salt: header.salt, iterations: header.iterations ).map { SymmetricKey( data: $0 ) }
	}

	// MARK: - Sealing

	/// The export file for `archive`. Slow (the key derivation): call it off the main thread.
	/// `iterations` is for tests; exports calibrate.
	static func seal( _ archive: BridgeArchive, passphrase: String, iterations: UInt32? = nil ) throws -> Data {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting     = .sortedKeys
		let plaintext = try encoder.encode( archive )

		let nonce  = AES.GCM.Nonce()
		let header = Header( kdf: kdfName, iterations: iterations ?? calibratedIterations( passphrase: passphrase ),
							 salt: randomBytes( saltSize ), cipher: cipherName, nonce: Data( nonce ) )
		let headerBytes = try encoder.encode( header )
		guard headerBytes.count <= Int( UInt16.max ), let key = key( passphrase: passphrase, header: header ) else { throw Problem.damaged }

		var prefix = magic
		prefix.append( containerVersion )
		prefix.append( UInt8( headerBytes.count >> 8 ) )
		prefix.append( UInt8( headerBytes.count & 0xFF ) )
		prefix.append( headerBytes )

		let box = try AES.GCM.seal( plaintext, using: key, nonce: nonce, authenticating: prefix )
		return prefix + box.ciphertext + box.tag
	}

	/// The header, checked, and where the sealed archive starts. Reading it needs no passphrase.
	static func header( of file: Data ) throws -> ( header: Header, prefixLength: Int ) {
		let bytes = [UInt8]( file.prefix( magic.count + 3 ) )
		guard bytes.count == magic.count + 3, Data( bytes.prefix( magic.count ) ) == magic else { throw Problem.notAnExport }
		guard bytes[magic.count] == containerVersion else {
			throw bytes[magic.count] > containerVersion ? Problem.newerVersion : Problem.damaged
		}
		let length = Int( bytes[magic.count + 1] ) << 8 | Int( bytes[magic.count + 2] )
		let start  = file.startIndex + magic.count + 3
		guard file.count >= magic.count + 3 + length + 16 else { throw Problem.damaged }
		guard let header = try? JSONDecoder().decode( Header.self, from: file.subdata( in: start..<start + length ) ) else { throw Problem.damaged }
		guard header.kdf == kdfName, header.cipher == cipherName else { throw Problem.newerVersion }
		guard header.salt.count == saltSize, header.nonce.count == 12,
			  ( minimumIterations...maximumIterations ).contains( header.iterations ) else { throw Problem.damaged }
		return ( header, magic.count + 3 + length )
	}

	/// The archive in an export file. Slow (the key derivation): call it off the main thread.
	/// Nothing is changed here; the caller imports the result.
	static func open( _ file: Data, passphrase: String ) throws -> BridgeArchive {
		guard file.count <= maximumFileSize else { throw Problem.tooLarge }
		let ( header, prefixLength ) = try Self.header( of: file )
		let start  = file.startIndex
		let prefix = file.subdata( in: start..<start + prefixLength )
		let sealed = file.subdata( in: start + prefixLength..<file.endIndex )
		guard !passphrase.isEmpty, let key = key( passphrase: passphrase, header: header ),
			  let nonce = try? AES.GCM.Nonce( data: header.nonce ),
			  let box = try? AES.GCM.SealedBox( nonce: nonce, ciphertext: sealed.dropLast( 16 ), tag: sealed.suffix( 16 ) ),
			  let plaintext = try? AES.GCM.open( box, using: key, authenticating: prefix ) else { throw Problem.wrongPassphrase }

		// The format first, so a newer export says so rather than failing to decode.
		struct Format: Decodable { var format: Int }
		guard let format = try? JSONDecoder().decode( Format.self, from: plaintext ).format else { throw Problem.unreadable( "it has no format version" ) }
		guard format <= BridgeArchive.currentFormat else { throw Problem.newerVersion }

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let archive: BridgeArchive
		do {
			archive = try decoder.decode( BridgeArchive.self, from: plaintext )
		} catch {
			throw Problem.unreadable( "\(error.localizedDescription)" )
		}
		try check( archive )
		return archive
	}

	/// What can be checked without the app: the ID and the file names.
	static func check( _ archive: BridgeArchive ) throws {
		let id = archive.bridgeID
		guard !id.isEmpty, id.count <= 64, id == id.trimmingCharacters( in: .whitespacesAndNewlines ) else { throw Problem.unreadable( "its bridge ID isn't valid" ) }
		guard archive.icons.keys.allSatisfy( BridgeArchive.isSafeFileName ), archive.shortcutIcons.keys.allSatisfy( BridgeArchive.isSafeFileName ) else {
			throw Problem.unreadable( "it names an icon file that isn't allowed" )
		}
		guard archive.pairingKeys.allSatisfy( { !$0.key.isEmpty && $0.key.count <= 64 && !$0.value.isEmpty } ) else {
			throw Problem.unreadable( "it has a pairing key that isn't valid" )
		}
	}

	private static func randomBytes( _ count: Int ) -> Data {
		var generator = SystemRandomNumberGenerator()
		return Data( ( 0..<count ).map { _ in UInt8.random( in: .min ... .max, using: &generator ) } )
	}
}
