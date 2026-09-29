//
//  TrafficEntry.swift
//  ESPDeck Bridge
//
//  One frame to or from a device, summarized for the Log tab.
//

import Foundation

struct TrafficEntry: Identifiable {
	enum Direction {
		case sent
		case received
		case event      // something the app did or noticed: an action, a trigger, sleep
	}

	let id        = UUID()
	let date      = Date()
	let direction : Direction
	/// What happened, in plain words: "Key 3 pressed", "Brightness set to 60%".
	let summary   : String
	/// The frame itself, briefly, for the second line: "keyDown  key 2",
	/// "show  hash 9f86d081…  key 4". Empty for events.
	let detail    : String
	let bytes     : Int

	init( direction: Direction, summary: String, detail: String = "", bytes: Int = 0 ) {
		self.direction = direction
		self.summary   = summary
		self.detail    = detail
		self.bytes     = bytes
	}

	/// A JSON frame, sent or received.
	static func frame( json: Data, direction: Direction ) -> TrafficEntry {
		guard let object = try? JSONSerialization.jsonObject( with: json ) as? [String: Any] else {
			let text = String( decoding: json.prefix( 80 ), as: UTF8.self )
			return TrafficEntry( direction: direction, summary: direction == .sent ? "Sent a message" : "Received a message", detail: text, bytes: json.count )
		}
		let type = object["type"] as? String ?? "?"
		let summary = direction == .sent ? describeSent( type, object ) : describeReceived( type, object )
		return TrafficEntry( direction: direction, summary: summary, detail: describe( type, object ), bytes: json.count )
	}

	/// An image or firmware frame (their MAC is added after this). `firmwareTotal`: the size
	/// of the whole firmware image, for a firmware frame.
	static func frame( binary: Data, firmwareTotal: Int? = nil, imageKeys: [Int] = [] ) -> TrafficEntry {
		let magic = String( decoding: binary.prefix( 4 ), as: UTF8.self )
		let summary : String
		let detail  : String
		switch magic {
			case "IMG1":
				let hash = binary.dropFirst( 4 ).prefix( 4 ).map { String( format: "%02x", $0 ) }.joined()
				let keys = imageKeys.sorted().map { String( $0 + 1 ) }
				switch keys.count {
					case 0:  summary = "Sent a key image"
					case 1:  summary = "Sent image to key \(keys[0])"
					default: summary = "Sent image to keys \(ListFormatter.localizedString( byJoining: keys ))"
				}
				detail  = "IMG1  hash \(hash)…  \(size( binary.count - 20 ))"
			case "FWU1":
				let offset = binary.dropFirst( 4 ).prefix( 4 ).enumerated().reduce( 0 ) { $0 | Int( $1.element ) << ( 8 * $1.offset ) }
				let end    = offset + binary.count - 8
				summary = "Firmware update: sent \(kilobytes( end ))" + ( firmwareTotal.map { " of \(kilobytes( $0 )) KB" } ?? " KB" )
				detail  = "FWU1  offset \(offset)  \(size( binary.count - 8 ))"
			default:
				summary = "Sent binary data"
				detail  = "binary \(magic)"
		}
		return TrafficEntry( direction: .sent, summary: summary, detail: detail, bytes: binary.count )
	}

	// MARK: - Plain words

	/// Mac → ESP32 (PROTOCOL.md, Messages).
	private static func describeSent( _ type: String, _ object: [String: Any] ) -> String {
		switch type {
			case "show":           return "Asked \(key( object )) to show its image"
			case "brightness":     return ( object["value"] as? Int ).map { "Brightness set to \($0)%" } ?? "Brightness set"
			case "setName":        return "Renamed the deck \u{201C}\(plain( object["name"] ))\u{201D}"
			case "orientation":    return "Orientation set to \(orientation( object["value"] as? String ))"
			case "sleepTimeout":
				guard let seconds = object["seconds"] as? Int else { return "Sleep timer set" }
				return seconds == 0 ? "Sleep timer turned off" : "Sleep timer set to \(duration( seconds ))"
			case "sleep":          return "Asked the deck to sleep"
			case "wake":           return "Asked the deck to wake"
			case "setupMode":      return object["enabled"] as? Bool == true ? "Asked the deck to enter setup mode" : "Asked the deck to leave setup mode"
			case "unpair":         return "Unpaired: asked the deck to delete its pairing key"
			case "devOTA":         return ( object["sealedHash"] as? String ).map { !$0.isEmpty } == true ? "Allowed uploads from PlatformIO" : "Turned off uploads from PlatformIO"
			case "factoryReset":   return "Asked the deck to reset to factory settings"
			case "encryptStorage": return "Asked the deck to encrypt its storage"
			case "firmwareBegin":
				let version = plain( object["version"] )
				let size    = ( object["size"] as? Int ).map { ", \(Self.size( $0 ))" } ?? ""
				return "Firmware update: starting version \(version)\(size)" + ( object["allowDowngrade"] as? Bool == true ? ", downgrade allowed" : "" )
			case "firmwareEnd":    return "Firmware update: all data sent"
			case "auth":           return "Sent this Mac's proof of identity"
			case "pairRequest":    return "Pairing: asked the deck to pair"
			case "pairNonce":      return "Pairing: sent this Mac's nonce"
			case "pairCancel":     return "Pairing cancelled on this Mac"
			default:               return "Sent \(plain( type ))"
		}
	}

	/// ESP32 → Mac (PROTOCOL.md, Messages).
	private static func describeReceived( _ type: String, _ object: [String: Any] ) -> String {
		switch type {
			case "hello":
				let name = plain( object["name"] )
				return "Hello from \u{201C}\(name)\u{201D}" + ( object["firmware"] is String ? ", firmware \(plain( object["firmware"] ))" : "" )
			case "auth":           return "Connected and authenticated"
			case "pairResponse":   return "Pairing: the deck accepted and sent its key"
			case "pairReveal":     return "Pairing: the deck revealed its nonce"
			case "pairConfirm":    return "Pairing: code confirmed on the deck"
			case "pairCancel":
				switch object["reason"] as? String {
					case "deck":      return "Pairing cancelled on the deck"
					case "timeout":   return "Pairing timed out on the deck"
					case "setupMode": return "The deck refused pairing: it's in setup mode"
					case "paired":    return "The deck refused pairing: it's paired with another Mac"
					case "busy":      return "The deck refused pairing: it's installing firmware"
					case "failed":    return "Pairing failed on the deck"
					case let reason?: return "The deck cancelled pairing (\(plain( reason )))"
					case nil:         return "The deck cancelled pairing"
				}
			case "firmwareStatus":
				switch object["state"] as? String {
					case "ready":     return "Firmware update: the deck is ready"
					case "progress":  return ( object["received"] as? Int ).map { "Firmware update: the deck has received \(kilobytes( $0 )) KB" } ?? "Firmware update: in progress"
					case "installed": return "Firmware installed; the deck is restarting"
					case "error":     return "Firmware update failed: \(plain( object["message"] ))"
					default:          return "Firmware update: \(plain( object["state"] ))"
				}
			case "storageStatus":
				switch object["state"] as? String {
					case "encrypting": return "The deck is encrypting its storage"
					case "error":      return "Encrypting storage failed: \(plain( object["message"] ))"
					default:           return "Storage: \(plain( object["state"] ))"
				}
			case "deck":
				guard let deck = object["deck"] as? [String: Any], deck["connected"] as? Bool == true else {
					return "The Stream Deck was unplugged"
				}
				let layout = ( deck["cols"] as? Int ).flatMap { cols in ( deck["rows"] as? Int ).map { ", \(cols) × \($0) keys" } } ?? ""
				return "The deck reported its layout: \(plain( deck["model"] ))\(layout)"
			case "status":
				let status = object["status"] as? [String: Any] ?? [:]
				let state  = status["setupMode"] as? Bool == true ? "in setup mode" : status["asleep"] as? Bool == true ? "asleep" : "awake"
				let why    = ( object["reason"] as? String ).map { " (\(DeviceStatus.describe( reason: plain( $0 ) )))" } ?? ""
				return "The deck is \(state)\(why)"
			case "usbDevice":
				guard let vid = object["vid"] as? Int, let pid = object["pid"] as? Int else {
					return "Something was plugged into the USB port, but it couldn't be identified"
				}
				let id = String( format: "%04X:%04X", vid, pid )
				if object["class"] as? Int == 0x09 {
					return "A USB hub (\(id)) was plugged in; a Stream Deck behind a hub isn't supported"
				}
				return vid == 0x0FD9 ? "An Elgato device (\(id)) was plugged in" : "A USB device (\(id)) was plugged in; it isn't a Stream Deck"
			case "need":           return "The deck asked for an image it doesn't have"
			case "shown":          return "\(key( object ).capitalizedFirst) now shows its image"
			case "keyDown":        return "\(key( object ).capitalizedFirst) pressed"
			case "keyUp":          return "\(key( object ).capitalizedFirst) released"
			default:               return "Received \(plain( type ))"
		}
	}

	/// "key 3", numbered from 1 as the app shows keys.
	private static func key( _ object: [String: Any] ) -> String {
		( object["key"] as? Int ).map { "key \($0 + 1)" } ?? "a key"
	}

	private static func orientation( _ value: String? ) -> String {
		switch value {
			case "auto":      "automatic"
			case "none":      "no rotation"
			case "transpose": "transposed"
			case "rotate90":  "rotated 90° clockwise"
			case "rotate270": "rotated 90° counterclockwise"
			case "rotate180": "rotated 180°"
			default:          plain( value )
		}
	}

	private static func duration( _ seconds: Int ) -> String {
		Duration.seconds( seconds ).formatted( .units( allowed: [.days, .hours, .minutes, .seconds], width: .wide ) )
	}

	private static func size( _ bytes: Int ) -> String {
		ByteCountFormatter.string( fromByteCount: Int64( bytes ), countStyle: .file )
	}

	/// "1,392": whole kilobytes (1024 bytes), rounded.
	private static func kilobytes( _ bytes: Int ) -> String {
		( ( bytes + 512 ) / 1024 ).formatted()
	}

	/// A string the device sent, fit to show on one line: no control or format characters,
	/// at most 80 characters.
	private static func plain( _ value: Any? ) -> String {
		guard let string = value as? String else { return "?" }
		let scalars = string.unicodeScalars.filter { scalar in
			switch scalar.properties.generalCategory {
				case .control, .lineSeparator, .paragraphSeparator, .format: false
				default:                                                     true
			}
		}
		let text = String( String.UnicodeScalarView( scalars ) )
		return text.count > 80 ? String( text.prefix( 80 ) ) + "…" : text
	}

	// MARK: - The frame, briefly

	/// "show  hash 9f86d081…  key 4", "hello  cached [12]  id f4:12:…  …".
	private static func describe( _ type: String, _ object: [String: Any] ) -> String {
		var parts = [ plain( type ) ]
		for key in object.keys.sorted() where key != "type" {
			parts.append( "\(key) \(describe( value: object[key] as Any ))" )
		}
		return parts.joined( separator: "  " )
	}

	private static func describe( value: Any ) -> String {
		switch value {
			case let string as String:
				return string.count > 20 ? plain( String( string.prefix( 8 ) ) ) + "…" : plain( string )
			case let array as [Any]:
				return "[\(array.count)]"
			case let dictionary as [String: Any]:
				// One level, briefly: "{connected true, model Stream Deck Mini, …}".
				let inner = dictionary.keys.sorted().prefix( 4 ).map { "\($0) \(describe( value: dictionary[$0] as Any ))" }
				return "{" + inner.joined( separator: ", " ) + ( dictionary.count > 4 ? ", …" : "" ) + "}"
			case let number as NSNumber:
				return CFGetTypeID( number ) == CFBooleanGetTypeID() ? ( number.boolValue ? "true" : "false" ) : number.stringValue
			default:
				return "\(value)"
		}
	}
}

private extension String {
	/// "Key 3" from "key 3".
	var capitalizedFirst: String {
		prefix( 1 ).uppercased() + dropFirst()
	}
}
