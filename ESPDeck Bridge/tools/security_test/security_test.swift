// Tests FirmwareSignature and BridgeTransfer with the app's own code. run.sh compiles it
// together with Updates/FirmwareSignature.swift and Security/BridgeTransfer.swift, and passes
// a file signed by sign_release.sh with a throwaway key, its .sig, that key's raw public key,
// and the release public key from firmware_signing_public_key.pem.
import CryptoKit
import Foundation

var failures = 0

func check( _ condition: Bool, _ what: String ) {
	print( condition ? "ok \(what)" : "FAIL \(what)" )
	if !condition { failures += 1 }
}

func expect( _ problem: BridgeTransfer.Problem, _ what: String, _ body: () throws -> Void ) {
	do {
		try body()
		check( false, "\(what) (no error)" )
	} catch let error as BridgeTransfer.Problem {
		check( error == problem, error == problem ? what : "\(what) (got \(error))" )
	} catch {
		check( false, "\(what) (got \(error))" )
	}
}

func hex( _ data: Data ) -> String { data.map { String( format: "%02x", $0 ) }.joined() }

func flipping( _ data: Data, at offset: Int ) -> Data {
	var copy = data
	copy[copy.startIndex + offset] ^= 0x01
	return copy
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
	print( "usage: security_test FILE SIGNATURE THROWAWAY_PUBLIC_KEY RELEASE_PUBLIC_KEY" )
	exit( 2 )
}
let file           = try Data( contentsOf: URL( fileURLWithPath: arguments[1] ) )
let signature      = try Data( contentsOf: URL( fileURLWithPath: arguments[2] ) )
let throwawayKey   = try Data( contentsOf: URL( fileURLWithPath: arguments[3] ) )
let releasePEMKey  = try Data( contentsOf: URL( fileURLWithPath: arguments[4] ) )

// MARK: - Firmware signatures

print( "Firmware signatures" )
check( FirmwareSignature.publicKey == releasePEMKey, "the app's public key is firmware_signing_public_key.pem's" )
check( signature.count == FirmwareSignature.size, "sign_release.sh writes a raw 64-byte signature" )
check( FirmwareSignature.isValid( signature, for: file, publicKey: throwawayKey ), "an openssl signature verifies with CryptoKit" )
check( !FirmwareSignature.isValid( signature, for: flipping( file, at: 0 ), publicKey: throwawayKey ), "a changed first byte fails" )
check( !FirmwareSignature.isValid( signature, for: flipping( file, at: file.count / 2 ), publicKey: throwawayKey ), "a changed middle byte fails" )
check( !FirmwareSignature.isValid( signature, for: file.dropLast(), publicKey: throwawayKey ), "a truncated file fails" )
check( !FirmwareSignature.isValid( signature, for: file + Data( [ 0 ] ), publicKey: throwawayKey ), "an extended file fails" )
check( !FirmwareSignature.isValid( flipping( signature, at: 10 ), for: file, publicKey: throwawayKey ), "a changed signature fails" )
check( !FirmwareSignature.isValid( signature.prefix( 63 ), for: file, publicKey: throwawayKey ), "a short signature fails" )
check( !FirmwareSignature.isValid( signature + Data( [ 0 ] ), for: file, publicKey: throwawayKey ), "a long signature fails" )

// The release key: nothing made without its private key passes.
check( !FirmwareSignature.isValid( signature, for: file ), "the throwaway key's signature fails with the release key" )
check( !FirmwareSignature.isValid( Data( repeating: 0, count: 64 ), for: file ), "an all-zero signature fails with the release key" )
var forged = 0
for _ in 0..<1000 {
	let random = Data( ( 0..<64 ).map { _ in UInt8.random( in: 0 ... 255 ) } )
	if FirmwareSignature.isValid( random, for: file ) { forged += 1 }
}
check( forged == 0, "1000 random signatures all fail with the release key" )
let other = Curve25519.Signing.PrivateKey()
check( !FirmwareSignature.isValid( try other.signature( for: file ), for: file ), "another key's signature fails with the release key" )
check( FirmwareSignature.isValid( try other.signature( for: file ), for: file, publicKey: other.publicKey.rawRepresentation ),
	   "CryptoKit's own signature verifies (control)" )

// MARK: - Bridge export

print( "Bridge export" )

// PBKDF2-HMAC-SHA256 against published vectors (RFC 7914, section 11, and the common ones).
check( BridgeTransfer.pbkdf2( password: Array( "password".utf8 ), salt: Data( "salt".utf8 ), iterations: 1 ).map( hex )
	   == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "PBKDF2 vector: 1 iteration" )
check( BridgeTransfer.pbkdf2( password: Array( "password".utf8 ), salt: Data( "salt".utf8 ), iterations: 4096 ).map( hex )
	   == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", "PBKDF2 vector: 4096 iterations" )
check( BridgeTransfer.pbkdf2( password: Array( "passwd".utf8 ), salt: Data( "salt".utf8 ), iterations: 1, length: 64 ).map( hex )
	   == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783",
	   "PBKDF2 vector: RFC 7914" )

check( BridgeTransfer.passphraseProblem( "short" ) != nil, "a short passphrase is refused" )
check( BridgeTransfer.passphraseProblem( "aaaaaaaaaaaaaaaa" ) != nil, "a repetitive passphrase is refused" )
check( BridgeTransfer.passphraseProblem( "correct horse battery" ) == nil, "a good passphrase is accepted" )

let settings = Data( """
	{"bridgeID":"0c6e0a52-1f6b-4b8e-9f1a-2b3c4d5e6f70","devices":[{"id":"f4:12:fa:00:00:01","name":"Kitchen","keys":[{"icons":{"on":"A.png"}}]},\
	{"id":"f4:12:fa:00:00:02","name":"Office"}],"usbScanning":true}
	""".utf8 )
let archive = BridgeArchive(
	appVersion: "1.0", exported: Date( timeIntervalSince1970: 1_790_000_000 ), macName: "Test Mac", bridgeID: "0c6e0a52-1f6b-4b8e-9f1a-2b3c4d5e6f70",
	devices: [ .init( id: "f4:12:fa:00:00:01", name: "Kitchen", isDemo: false, paired: true ),
			   .init( id: "f4:12:fa:00:00:02", name: "Office", isDemo: false, paired: true ) ],
	settings: settings,
	pairingKeys: [ "f4:12:fa:00:00:01": Data( repeating: 0x11, count: 32 ), "f4:12:fa:00:00:02": Data( repeating: 0x22, count: 32 ) ],
	developerPassword: "correct-horse-battery",
	icons: [ "A.png": Data( [ 0x89, 0x50, 0x4E, 0x47, 1, 2, 3 ] ) ],
	shortcutIcons: [ "B1C2-D3.png": Data( [ 0x89, 0x50, 0x4E, 0x47, 4, 5 ] ) ] )
let passphrase = "correct horse battery staple"
let fast       = BridgeTransfer.minimumIterations

let sealed = try BridgeTransfer.seal( archive, passphrase: passphrase, iterations: fast )
check( ( try? BridgeTransfer.open( sealed, passphrase: passphrase ) ) == archive, "an export opens with its passphrase, unchanged" )
check( sealed.range( of: Data( "Kitchen".utf8 ) ) == nil && sealed.range( of: Data( repeating: 0x11, count: 32 ) ) == nil,
	   "the file doesn't contain the names or keys in the clear" )
let again = try BridgeTransfer.seal( archive, passphrase: passphrase, iterations: fast )
check( again != sealed, "each export gets a new salt and nonce" )

expect( .wrongPassphrase, "a wrong passphrase fails" ) { _ = try BridgeTransfer.open( sealed, passphrase: "correct horse battery stapler" ) }
expect( .wrongPassphrase, "an empty passphrase fails" ) { _ = try BridgeTransfer.open( sealed, passphrase: "" ) }

// Every part of the file is covered.
let prefixLength = try BridgeTransfer.header( of: sealed ).prefixLength
expect( .notAnExport, "a changed magic fails" ) { _ = try BridgeTransfer.open( flipping( sealed, at: 0 ), passphrase: passphrase ) }
expect( .newerVersion, "a newer container version fails" ) {
	var newer = sealed
	newer[BridgeTransfer.magic.count] = 2
	_ = try BridgeTransfer.open( newer, passphrase: passphrase )
}
expect( .wrongPassphrase, "a changed ciphertext fails" ) { _ = try BridgeTransfer.open( flipping( sealed, at: prefixLength + 5 ), passphrase: passphrase ) }
expect( .wrongPassphrase, "a changed tag fails" ) { _ = try BridgeTransfer.open( flipping( sealed, at: sealed.count - 1 ), passphrase: passphrase ) }
expect( .damaged, "a truncated file fails" ) { _ = try BridgeTransfer.open( sealed.prefix( prefixLength + 10 ), passphrase: passphrase ) }
expect( .notAnExport, "an empty file fails" ) { _ = try BridgeTransfer.open( Data(), passphrase: passphrase ) }

// The header is authenticated: the same file with an edited header (re-encoded, with its
// length updated) fails, even where the edit alone wouldn't change the key.
func rewritingHeader( _ edit: ( inout BridgeTransfer.Header ) -> Void ) throws -> Data {
	var ( header, prefixLength ) = try BridgeTransfer.header( of: sealed )
	edit( &header )
	let encoder = JSONEncoder()
	encoder.outputFormatting = .sortedKeys   // as seal() writes it
	let bytes = try encoder.encode( header )
	var file  = BridgeTransfer.magic
	file.append( BridgeTransfer.containerVersion )
	file.append( UInt8( bytes.count >> 8 ) )
	file.append( UInt8( bytes.count & 0xFF ) )
	return file + bytes + sealed.suffix( from: sealed.startIndex + prefixLength )
}
check( ( try? BridgeTransfer.open( try rewritingHeader { _ in }, passphrase: passphrase ) ) == archive, "(a re-encoded, unchanged header still opens)" )
expect( .wrongPassphrase, "a changed header nonce fails" ) { _ = try BridgeTransfer.open( try rewritingHeader { $0.nonce[0] ^= 1 }, passphrase: passphrase ) }
expect( .wrongPassphrase, "a changed header salt fails" ) { _ = try BridgeTransfer.open( try rewritingHeader { $0.salt[0] ^= 1 }, passphrase: passphrase ) }
expect( .wrongPassphrase, "changed header iterations fail" ) { _ = try BridgeTransfer.open( try rewritingHeader { $0.iterations += 1 }, passphrase: passphrase ) }
expect( .damaged, "too few iterations are refused" ) { _ = try BridgeTransfer.open( try rewritingHeader { $0.iterations = 1000 }, passphrase: passphrase ) }
expect( .damaged, "too many iterations are refused" ) {
	_ = try BridgeTransfer.open( try rewritingHeader { $0.iterations = BridgeTransfer.maximumIterations + 1 }, passphrase: passphrase )
}
expect( .newerVersion, "another key derivation is refused" ) { _ = try BridgeTransfer.open( try rewritingHeader { $0.kdf = "argon2id" }, passphrase: passphrase ) }

// Newer contents, and contents that would write outside the icon folders.
var newer = archive
newer.format = BridgeArchive.currentFormat + 1
expect( .newerVersion, "a newer archive format fails" ) {
	_ = try BridgeTransfer.open( try BridgeTransfer.seal( newer, passphrase: passphrase, iterations: fast ), passphrase: passphrase )
}
var escaping = archive
escaping.icons = [ "../../Settings.json": Data( [ 1 ] ) ]
expect( .unreadable( "it names an icon file that isn't allowed" ), "an icon name with a path fails" ) {
	_ = try BridgeTransfer.open( try BridgeTransfer.seal( escaping, passphrase: passphrase, iterations: fast ), passphrase: passphrase )
}
check( !BridgeArchive.isSafeFileName( ".hidden" ) && !BridgeArchive.isSafeFileName( "a/b.png" ) && BridgeArchive.isSafeFileName( "0A1B-2C.png" ),
	   "icon file names are checked" )

// The same passphrase, typed composed or decomposed.
let accented = try BridgeTransfer.seal( archive, passphrase: "caf\u{E9} cr\u{E8}me br\u{FB}l\u{E9}e", iterations: fast )
check( ( try? BridgeTransfer.open( accented, passphrase: "cafe\u{301} cre\u{300}me bru\u{302}le\u{301}e" ) ) == archive,
	   "a passphrase opens however its accents were typed" )

// A real export: calibrated iterations, and how long opening it takes here.
let calibrated = try BridgeTransfer.seal( archive, passphrase: passphrase )
let iterations = try BridgeTransfer.header( of: calibrated ).header.iterations
let start      = Date()
check( ( try? BridgeTransfer.open( calibrated, passphrase: passphrase ) ) == archive, "a calibrated export opens" )
let seconds    = Date().timeIntervalSince( start )
print( String( format: "   calibrated to %u iterations; opening took %.2f s", iterations, seconds ) )
check( iterations >= BridgeTransfer.minimumIterations && seconds > 0.3 && seconds < 3, "calibration takes roughly 0.75 s" )

print( failures == 0 ? "All passed" : "\(failures) failed" )
exit( failures == 0 ? 0 : 1 )
