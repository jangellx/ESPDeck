//
//  SymbolCatalog.swift
//  ESPDeck Bridge
//
//  Every SF Symbol, with search keywords and categories, read from the system's
//  CoreGlyphs bundle. There's no public API for this; if the files move, the picker
//  falls back to a short built-in list (and any symbol can still be typed by name).
//

import Foundation

/// One of SF Symbols' categories, with its own symbol.
struct SymbolCategory: Identifiable, Hashable {
	let key  : String
	let icon : String

	var id: String { key }

	/// The name shown in the picker, from its key.
	var title: String {
		switch key {
			case "all":              "All"
			case "whatsnew":         "What's New"
			case "objectsandtools":  "Objects & Tools"
			case "cameraandphotos":  "Camera & Photos"
			case "textformatting":   "Text Formatting"
			default:                 key.prefix( 1 ).uppercased() + key.dropFirst()
		}
	}
}

/// The system's SF Symbols, searchable by name, keyword and category; read once.
final class SymbolCatalog {
	static let shared = SymbolCatalog()

	let names      : [String]
	let categories : [SymbolCategory]
	private let keywords      : [String: [String]]
	private let categoryNames : [String: [String]]

	/// Offered when the system's lists can't be read.
	private static let fallback = [
		"house.fill", "sparkles", "sun.max.fill", "moon.fill", "bed.double.fill", "sofa.fill", "tv.fill",
		"lightbulb.fill", "lamp.floor.fill", "fan.fill", "thermometer.medium", "snowflake", "flame.fill",
		"door.garage.closed", "door.left.hand.closed", "lock.fill", "bell.fill", "music.note", "play.fill",
		"power", "car.fill", "figure.walk", "leaf.fill", "drop.fill", "wifi", "star.fill", "heart.fill",
	]

	/// Reads the lists from CoreGlyphs, falling back to the short list.
	private init() {
		let resources = URL( fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources" )

		func plist<T>( _ name: String, as type: T.Type ) -> T? {
			guard let data = try? Data( contentsOf: resources.appending( path: name ) ) else { return nil }
			return ( try? PropertyListSerialization.propertyList( from: data, format: nil ) ) as? T
		}

		// An empty or changed list counts as missing.
		let ordered = plist( "symbol_order.plist", as: [String].self ) ?? []
		names    = ordered.isEmpty ? Self.fallback : ordered
		keywords = plist( "symbol_search.plist", as: [String: [String]].self ) ?? [:]

		var byCategory: [String: [String]] = [:]
		for ( symbol, keys ) in plist( "symbol_categories.plist", as: [String: [String]].self ) ?? [:] {
			for key in keys { byCategory[key, default: []].append( symbol ) }
		}
		categoryNames = byCategory

		let listed = plist( "categories.plist", as: [[String: String]].self ) ?? []
		categories = listed.compactMap { entry in
			guard let key = entry["key"], let icon = entry["icon"], key == "all" || byCategory[key] != nil else { return nil }
			return SymbolCategory( key: key, icon: icon )
		}
	}

	/// Symbols in `category` (nil or "all" for every symbol) whose name or keywords
	/// contain every word of `query`, in SF Symbols order.
	func symbols( matching query: String, in category: String? ) -> [String] {
		var result = names
		if let category, category != "all", let members = categoryNames[category] {
			let set = Set( members )
			result  = result.filter { set.contains( $0 ) }
		}

		let terms = query.lowercased().split( whereSeparator: { $0 == " " } ).map( String.init )
		guard !terms.isEmpty else { return result }
		return result.filter { name in
			let words = [ name ] + ( keywords[name] ?? [] )
			return terms.allSatisfy { term in words.contains { $0.contains( term ) } }
		}
	}
}
