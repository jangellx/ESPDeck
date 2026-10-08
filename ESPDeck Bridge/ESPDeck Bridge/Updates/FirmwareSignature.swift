//
//  FirmwareSignature.swift
//  ESPDeck Bridge
//
//  Firmware releases are signed with an Ed25519 key that only GitHub Actions has (the
//  FIRMWARE_SIGNING_KEY secret; see docs/development.md, Release signing). Each release file has a
//  `<file>.sig` next to it: the raw 64-byte signature over the file's exact bytes. Every
//  image downloaded from GitHub Releases must carry a valid one before it's installed, over
//  Wi-Fi or over USB. Files the user picks (Install Firmware from File…, Choose File…) aren't
//  checked: the user chose them and confirms first.
//
//  Rotating the key means a new app release with the new public key here, and in
//  ESPDeck Device/tools/firmware_signing_public_key.pem.
//

import CryptoKit
import Foundation

/// Checks release files against the firmware signing key.
nonisolated enum FirmwareSignature {
	/// The raw Ed25519 public key: the last 32 bytes of the SPKI DER in
	/// firmware_signing_public_key.pem.
	static let publicKey = Data( [
		0xa8, 0x0c, 0xd3, 0xfc, 0x90, 0x86, 0x2c, 0xfc,
		0x0c, 0x0f, 0xd6, 0xb8, 0x64, 0x91, 0xba, 0x3e,
		0x1f, 0x6b, 0xf5, 0xff, 0x24, 0x3d, 0x7e, 0xb6,
		0x0f, 0x37, 0xf4, 0xf8, 0xae, 0x74, 0xca, 0x20,
	] )

	/// The first firmware release published with signatures. Earlier releases (3.2.0 and
	/// before) have none, so the app doesn't offer them; they can still be installed from a file.
	static let firstSignedRelease = "4.1.0"

	/// What a release publishes next to each file.
	static let fileSuffix = ".sig"
	static let size       = 64

	/// True if `signature` is a valid Ed25519 signature of exactly `file`'s bytes.
	static func isValid( _ signature: Data, for file: Data, publicKey: Data = publicKey ) -> Bool {
		guard signature.count == size, let key = try? Curve25519.Signing.PublicKey( rawRepresentation: publicKey ) else { return false }
		return key.isValidSignature( signature, for: file )
	}
}
