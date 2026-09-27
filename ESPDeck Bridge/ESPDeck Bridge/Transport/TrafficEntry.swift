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
	let summary   : String
	let bytes     : Int

	/// "show key 3 hash 9f86d081…", "hello id f4:12:… cached 12 items …".
	static func describe( json: Data ) -> String {
		guard let object = try? JSONSerialization.jsonObject( with: json ) as? [String: Any] else {
			return String( decoding: json.prefix( 80 ), as: UTF8.self )
		}
		var parts = [ object["type"] as? String ?? "?" ]
		for key in object.keys.sorted() where key != "type" {
			parts.append( "\(key) \(describe( value: object[key] as Any ))" )
		}
		return parts.joined( separator: "  " )
	}

	private static func describe( value: Any ) -> String {
		switch value {
			case let string as String:
				return string.count > 20 ? String( string.prefix( 8 ) ) + "…" : string
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

	/// Image and firmware frames (their MAC is added after this).
	static func describe( binary: Data ) -> String {
		let magic = String( decoding: binary.prefix( 4 ), as: UTF8.self )
		switch magic {
			case "IMG1":
				let hash = binary.dropFirst( 4 ).prefix( 4 ).map { String( format: "%02x", $0 ) }.joined()
				return "image \(hash)…  \(ByteCountFormatter.string( fromByteCount: Int64( binary.count - 20 ), countStyle: .file ))"
			case "FWU1":
				let offset = binary.dropFirst( 4 ).prefix( 4 ).enumerated().reduce( 0 ) { $0 | Int( $1.element ) << ( 8 * $1.offset ) }
				return "firmware chunk at \(offset)  \(ByteCountFormatter.string( fromByteCount: Int64( binary.count - 8 ), countStyle: .file ))"
			default:
				return "binary \(magic)"
		}
	}
}
