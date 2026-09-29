//
//  DeckMessages.swift
//  ESPDeck Bridge
//
//  Wire format shared with the ESP32. See PROTOCOL.md next to the two projects.
//

import Foundation

/// The deck object: whether a Stream Deck is plugged in, and if so what it is.
struct DeckInfo: Codable, Equatable {
	var connected : Bool
	var model     : String?
	var pid       : Int?
	var serial    : String?
	var firmware  : String?
	var rows      : Int?
	var cols      : Int?
	var keySize   : Int?
	var format    : KeyImageFormat?
	var transform : KeyTransform?

	static let disconnected = DeckInfo( connected: false )

	/// What a Stream Deck can have; a report outside these has no layout (the XL has 4 × 8
	/// keys of 96 px, the + 120 px ones).
	static let rowRange     = 1...8
	static let columnRange  = 1...8
	static let keySizeRange = 16...256

	/// The layout to render for, when the report is complete and plausible.
	var layout: DeckLayout? {
		guard connected, let rows, let cols, Self.rowRange.contains( rows ), Self.columnRange.contains( cols ) else { return nil }
		// A deck without images (the Pedal) reports a key size of 0; its grid still shows.
		guard let keySize = format == KeyImageFormat.none ? 72 : keySize, Self.keySizeRange.contains( keySize ) else { return nil }
		return DeckLayout( model: model ?? "Stream Deck", rows: rows, cols: cols, keySize: keySize,
						   format: format ?? .jpeg, transform: transform ?? .none )
	}

	/// Without a size the layout can't have: rendering and the key grid never see one.
	var sanitized: DeckInfo {
		guard layout == nil else { return self }
		var copy = self
		copy.rows    = nil
		copy.cols    = nil
		copy.keySize = nil
		return copy
	}
}

/// The settings object; the ESP32 persists these.
struct DeviceReportedSettings: Codable, Equatable {
	var orientation  : String?
	var sleepTimeout : Int?
	var brightness   : Int?
	var ip           : String?
}

/// The status object.
struct DeviceStatus: Codable, Equatable {
	var asleep    = false
	var setupMode = false
	/// Reports keyTap, keyDoubleTap and keyHold (firmware with keyModes); nil before, when
	/// the Mac acts on keyUp.
	var presses   : Bool?
	/// Uploads from PlatformIO are allowed (firmware 3.2.0 and later; nil before).
	var devOTA    : Bool?
	/// How NVS (Wi-Fi password, pairing key, …) is stored: "plain", "encrypted", or
	/// "unsupported" (plain, and the chip can't encrypt it). Firmware 4.1.0 and later; nil before.
	var storage   : String?
	/// Its name on the network (DHCP, and <hostname>.local). Firmware 4.1.0 and later; nil
	/// before, when it's always the default (DeviceSettings.defaultHostname).
	var hostname  : String?
	/// The Wi-Fi network it's set up for. Only sent inside the session (firmware 4.1.0 and
	/// later; nil before, and in the unauthenticated hello).
	var wifi      : WiFi?
	/// Why it last changed: "timer", "key", "bridge", "chord", "setupPage", "exitKey", "boot",
	/// "improv", "pairing", "timeout", "session".
	var reason    : String?

	struct WiFi: Codable, Equatable {
		/// The network name in its settings, "" when it has none.
		var ssid      : String
		/// Whether it's on that network now.
		var connected : Bool
	}

	/// With a network name fit to show.
	var sanitized: DeviceStatus {
		var copy = self
		copy.wifi?.ssid = DeviceMessage.displayName( wifi?.ssid ) ?? ""
		return copy
	}

	static func describe( reason: String ) -> String {
		switch reason {
			case "timer":     "sleep timer"
			case "key":       "key press"
			case "bridge":    "from ESPDeck Bridge"
			case "chord":     "corner-key hold"
			case "setupPage": "setup page"
			case "exitKey":   "Exit key"
			case "boot":      "restart"
			case "improv":    "Wi-Fi set over USB"
			case "pairing":   "pairing"
			case "timeout":   "setup mode timed out"
			case "session":   "connected"
			case "deck":      "Stream Deck plugged in"
			default:          reason
		}
	}
}

struct DeviceHello {
	var protocolVersion : Int
	/// 16 random bytes for the authentication handshake (protocol 3 and later).
	var nonce           : Data?
	/// Bridge ID the device is paired with; empty when unpaired.
	var pairedBridge    : String
	var id        : String
	var name      : String
	var firmware  : String
	/// Hex SHA-256 of the running app's ELF file (firmware 3.1.0 and later).
	var elfSHA256 : String?
	var cached    : [String]
	var deck      : DeckInfo
	var settings  : DeviceReportedSettings
	var status    : DeviceStatus
}

/// ESP32 → Mac
enum DeviceMessage {
	case hello( DeviceHello )
	case deck( DeckInfo )
	case status( DeviceStatus )
	case need( hash: String )
	case keyDown( Int )
	case keyUp( Int )
	/// A held Level key, again (firmware 4.1.0 and later; see HostMessage.repeatKeys).
	case keyRepeat( Int )
	/// What kind of press it was, judged on the device (see HostMessage.keyModes).
	case keyPress( Int, PressKind )
	/// A key now shows this image on the deck (uploaded, or it already did).
	case shown( key: Int, hash: String )
	case auth( proof: Data )
	/// Pairing (protocol 4): the deck's public key and its commitment to it and its nonce.
	case pairResponse( publicKey: Data, commitment: Data )
	/// The nonce the commitment covers, after the Mac sent its own.
	case pairReveal( nonce: Data )
	case pairConfirm( proof: Data )
	/// Why the deck cancelled or refused pairing: "deck", "timeout", "setupMode", "paired",
	/// "busy", "failed", or nil (firmware before 4.0.0).
	case pairCancel( reason: String? )
	case firmwareStatus( FirmwareStatus )
	/// The answer to encryptStorage.
	case storageStatus( StorageStatus )
	/// Something was plugged into the deck's USB port (firmware 4.1.0 and later). Only for
	/// the log, which describes it from the JSON.
	case usbDevice

	struct FirmwareStatus {
		enum State: String {
			case ready, progress, installed, error
		}
		var state    : State
		var received : Int?
		var message  : String?
	}

	struct StorageStatus {
		enum State: String {
			/// Under way; the device restarts when it's done.
			case encrypting
			/// Nothing changed; `message` says why.
			case error
		}
		var state   : State
		var message : String?
	}

	/// Messages the ESP32 may send before the session is authenticated.
	var isHandshake: Bool {
		switch self {
			case .hello, .auth, .pairResponse, .pairReveal, .pairConfirm, .pairCancel: true
			default:                                                                   false
		}
	}

	private struct Envelope: Decodable {
		var type     : String
		var `protocol`   : Int?
		var nonce        : String?
		var pairedBridge : String?
		var proof        : String?
		var publicKey    : String?
		var commitment   : String?
		var state        : String?
		var received     : Int?
		var message      : String?
		var id        : String?
		var name      : String?
		var firmware  : String?
		var elfSHA256 : String?
		var cached    : [String]?
		var deck      : DeckInfo?
		var settings  : DeviceReportedSettings?
		var status    : DeviceStatus?
		var reason    : String?        // beside `status`, not inside it
		var hash      : String?
		var key       : Int?
	}

	/// Keys beyond this are ignored; no Stream Deck has more.
	static let maxKeys = 64
	/// Longer names (from a device that hasn't authenticated, say) are cut.
	static let maxNameLength = 64

	init?( json: Data ) {
		guard let envelope = try? JSONDecoder().decode( Envelope.self, from: json ) else { return nil }

		switch envelope.type {
			case "hello":
				guard let id = envelope.id?.lowercased(), Self.isDeviceID( id ) else { return nil }
				self = .hello( DeviceHello( protocolVersion: envelope.protocol ?? 2, nonce: envelope.nonce.flatMap { Data( hex: $0 ) },
											pairedBridge: envelope.pairedBridge ?? "",
											id: id, name: Self.displayName( envelope.name ) ?? id, firmware: envelope.firmware ?? "?",
											elfSHA256: envelope.elfSHA256?.lowercased(),
											cached: envelope.cached ?? [], deck: ( envelope.deck ?? .disconnected ).sanitized,
											settings: envelope.settings ?? DeviceReportedSettings(), status: ( envelope.status ?? DeviceStatus() ).sanitized ) )
			case "deck":
				guard let deck = envelope.deck else { return nil }
				self = .deck( deck.sanitized )
			case "status":
				guard var status = envelope.status else { return nil }
				status.reason = envelope.reason ?? status.reason
				self = .status( status.sanitized )
			case "need":
				guard let hash = envelope.hash else { return nil }
				self = .need( hash: hash )
			case "keyDown":
				guard let key = envelope.key, ( 0..<Self.maxKeys ).contains( key ) else { return nil }
				self = .keyDown( key )
			case "keyUp":
				guard let key = envelope.key, ( 0..<Self.maxKeys ).contains( key ) else { return nil }
				self = .keyUp( key )
			case "keyRepeat":
				guard let key = envelope.key, ( 0..<Self.maxKeys ).contains( key ) else { return nil }
				self = .keyRepeat( key )
			case "keyTap", "keyDoubleTap", "keyHold":
				guard let key = envelope.key, ( 0..<Self.maxKeys ).contains( key ) else { return nil }
				self = .keyPress( key, envelope.type == "keyTap" ? .tap : envelope.type == "keyDoubleTap" ? .doubleTap : .hold )
			case "shown":
				guard let key = envelope.key, ( 0..<Self.maxKeys ).contains( key ), let hash = envelope.hash else { return nil }
				self = .shown( key: key, hash: hash )
			case "auth":
				guard let proof = envelope.proof.flatMap( { Data( hex: $0 ) } ) else { return nil }
				self = .auth( proof: proof )
			case "pairResponse":
				guard let key = envelope.publicKey.flatMap( { Data( hex: $0 ) } ), key.count == 32,
					  let commitment = envelope.commitment.flatMap( { Data( hex: $0 ) } ), commitment.count == 32 else { return nil }
				self = .pairResponse( publicKey: key, commitment: commitment )
			case "pairReveal":
				guard let nonce = envelope.nonce.flatMap( { Data( hex: $0 ) } ), nonce.count == DeckCrypto.nonceSize else { return nil }
				self = .pairReveal( nonce: nonce )
			case "pairConfirm":
				guard let proof = envelope.proof.flatMap( { Data( hex: $0 ) } ) else { return nil }
				self = .pairConfirm( proof: proof )
			case "pairCancel":
				self = .pairCancel( reason: envelope.reason )
			case "firmwareStatus":
				guard let state = envelope.state.flatMap( FirmwareStatus.State.init( rawValue: ) ) else { return nil }
				self = .firmwareStatus( FirmwareStatus( state: state, received: envelope.received, message: envelope.message ) )
			case "storageStatus":
				guard let state = envelope.state.flatMap( StorageStatus.State.init( rawValue: ) ) else { return nil }
				self = .storageStatus( StorageStatus( state: state, message: envelope.message ) )
			case "usbDevice":
				self = .usbDevice
			default:
				return nil
		}
	}

	/// The Wi-Fi MAC address, "aa:bb:cc:dd:ee:ff" in lowercase.
	static func isDeviceID( _ id: String ) -> Bool {
		let parts = id.split( separator: ":", omittingEmptySubsequences: false )
		return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy( \.isHexDigit ) }
	}

	/// Without control or formatting characters (bidirectional overrides, say; the joiner in
	/// emoji sequences stays) or surrounding spaces, and at most maxNameLength long.
	static func displayName( _ name: String? ) -> String? {
		guard let name else { return nil }
		let scalars = name.unicodeScalars.filter { scalar in
			switch scalar.properties.generalCategory {
				case .control, .lineSeparator, .paragraphSeparator: false
				case .format:                                       scalar.value == 0x200D
				default:                                            true
			}
		}
		let trimmed = String( String.UnicodeScalarView( scalars ) ).trimmingCharacters( in: .whitespacesAndNewlines )
		return trimmed.isEmpty ? nil : String( trimmed.prefix( maxNameLength ) )
	}
}

/// Mac → ESP32 control messages. Images go out as binary frames; see `imageFrame`.
enum HostMessage: Encodable, Equatable {
	case show( key: Int, hash: String )
	case brightness( Int )
	case setName( String )
	case orientation( String )
	case sleepTimeout( Int )
	case sleep
	case wake
	case setupMode( Bool )
	/// Its name on the network; "" for the default. It restarts to use it. Firmware 4.1.0 and later.
	case setHostname( String )
	/// Which keys repeat while held, and how (milliseconds). Firmware 4.1.0 before keyModes.
	case repeatKeys( keys: [Int], delay: Int, interval: Int )
	/// How keys report presses: which repeat, which have a double tap or a hold, and the
	/// timings (milliseconds). Firmware that reports presses (DeviceStatus.presses).
	case keyModes( repeat: [Int], doubleTap: [Int], hold: [Int], delay: Int, interval: Int, doubleTapWindow: Int, holdTime: Int )
	case unpair
	case factoryReset
	/// Burns the chip's eFuse key and encrypts NVS with it (firmware 4.1.0 and later). Permanent.
	case encryptStorage
	/// Uploads from PlatformIO: their password's SHA-256 sealed for the frame that carries it
	/// (DeckServer.sendDevOTA), or nil to turn them off.
	case devOTA( sealedHash: Data? )
	/// allowDowngrade: the user confirmed installing this image even if it's older.
	case firmwareBegin( version: String, size: Int, sha256: String, allowDowngrade: Bool )
	case firmwareEnd
	// Unauthenticated handshake messages
	case auth( nonce: Data, proof: Data )
	case pairRequest( bridgeID: String, bridgeName: String, publicKey: Data )
	case pairNonce( Data )
	case pairCancel
	/// This Mac can't authenticate the deck (it has no key for it): the deck stays connected
	/// and idle, so it still shows as here, rather than giving up on this Mac. Firmware 4.1.0
	/// and later; older firmware ignores it and drops the connection after 10 s.
	case noKey

	private enum CodingKeys: String, CodingKey {
		case type, key, keys, hash, value, name, seconds, enabled, delay, interval, hostname
		case `repeat`, doubleTap, hold, doubleTapWindow, holdTime
		case version, size, sha256, allowDowngrade, nonce, proof, bridgeID, bridgeName, publicKey, passwordHash, sealedHash
	}

	func encode( to encoder: Encoder ) throws {
		var container = encoder.container( keyedBy: CodingKeys.self )
		switch self {
			case .show( let key, let hash ):
				try container.encode( "show", forKey: .type )
				try container.encode( key, forKey: .key )
				try container.encode( hash, forKey: .hash )
			case .brightness( let value ):
				try container.encode( "brightness", forKey: .type )
				try container.encode( value, forKey: .value )
			case .setName( let name ):
				try container.encode( "setName", forKey: .type )
				try container.encode( name, forKey: .name )
			case .orientation( let value ):
				try container.encode( "orientation", forKey: .type )
				try container.encode( value, forKey: .value )
			case .sleepTimeout( let seconds ):
				try container.encode( "sleepTimeout", forKey: .type )
				try container.encode( seconds, forKey: .seconds )
			case .sleep:
				try container.encode( "sleep", forKey: .type )
			case .wake:
				try container.encode( "wake", forKey: .type )
			case .setupMode( let enabled ):
				try container.encode( "setupMode", forKey: .type )
				try container.encode( enabled, forKey: .enabled )
			case .setHostname( let hostname ):
				try container.encode( "setHostname", forKey: .type )
				try container.encode( hostname, forKey: .hostname )
			case .keyModes( let keys, let doubleTap, let hold, let delay, let interval, let window, let holdTime ):
				try container.encode( "keyModes", forKey: .type )
				try container.encode( keys, forKey: .repeat )
				try container.encode( doubleTap, forKey: .doubleTap )
				try container.encode( hold, forKey: .hold )
				try container.encode( delay, forKey: .delay )
				try container.encode( interval, forKey: .interval )
				try container.encode( window, forKey: .doubleTapWindow )
				try container.encode( holdTime, forKey: .holdTime )
			case .repeatKeys( let keys, let delay, let interval ):
				try container.encode( "repeatKeys", forKey: .type )
				try container.encode( keys, forKey: .keys )
				try container.encode( delay, forKey: .delay )
				try container.encode( interval, forKey: .interval )
			case .unpair:
				try container.encode( "unpair", forKey: .type )
			case .factoryReset:
				try container.encode( "factoryReset", forKey: .type )
			case .encryptStorage:
				try container.encode( "encryptStorage", forKey: .type )
			case .devOTA( let sealedHash ):
				try container.encode( "devOTA", forKey: .type )
				if let sealedHash {
					try container.encode( sealedHash.hex, forKey: .sealedHash )
				} else {
					try container.encode( "", forKey: .passwordHash )   // off, which firmware before 4.0.0 understands too
				}
			case .firmwareBegin( let version, let size, let sha256, let allowDowngrade ):
				try container.encode( "firmwareBegin", forKey: .type )
				try container.encode( version, forKey: .version )
				try container.encode( size, forKey: .size )
				try container.encode( sha256, forKey: .sha256 )
				if allowDowngrade {
					try container.encode( true, forKey: .allowDowngrade )
				}
			case .firmwareEnd:
				try container.encode( "firmwareEnd", forKey: .type )
			case .auth( let nonce, let proof ):
				try container.encode( "auth", forKey: .type )
				try container.encode( nonce.hex, forKey: .nonce )
				try container.encode( proof.hex, forKey: .proof )
			case .pairRequest( let bridgeID, let bridgeName, let publicKey ):
				try container.encode( "pairRequest", forKey: .type )
				try container.encode( bridgeID, forKey: .bridgeID )
				try container.encode( bridgeName, forKey: .bridgeName )
				try container.encode( publicKey.hex, forKey: .publicKey )
			case .pairNonce( let nonce ):
				try container.encode( "pairNonce", forKey: .type )
				try container.encode( nonce.hex, forKey: .nonce )
			case .pairCancel:
				try container.encode( "pairCancel", forKey: .type )
			case .noKey:
				try container.encode( "noKey", forKey: .type )
		}
	}

	/// Sendable before the session is authenticated.
	var isHandshake: Bool {
		switch self {
			case .auth, .pairRequest, .pairNonce, .pairCancel, .noKey: true
			default:                                                   false
		}
	}

	/// "FWU1" + 32-bit little-endian offset + a chunk of the app image.
	static func firmwareFrame( offset: Int, chunk: Data ) -> Data {
		var frame = Data( "FWU1".utf8 )
		var value = UInt32( offset ).littleEndian
		withUnsafeBytes( of: &value ) { frame.append( contentsOf: $0 ) }
		frame.append( chunk )
		return frame
	}

	/// "IMG1" + 16 raw hash bytes + image file.
	static func imageFrame( hash: String, image: Data ) -> Data? {
		let digits = Array( hash.utf8 )
		guard digits.count == 32 else { return nil }

		var frame = Data( "IMG1".utf8 )
		for index in stride( from: 0, to: digits.count, by: 2 ) {
			guard let pair = String( bytes: digits[index...index + 1], encoding: .ascii ),
				  let byte = UInt8( pair, radix: 16 ) else { return nil }
			frame.append( byte )
		}
		frame.append( image )
		return frame
	}
}
