//
//  LenientDecoding.swift
//  ESPDeck Bridge
//
//  Settings.json is read field by field, so a field that can't be read (a newer
//  version's enum case, the wrong type) falls back to its default instead of making the
//  whole file unreadable.
//

import Foundation

extension KeyedDecodingContainer {
	/// The value, or nil when it's missing, null, or can't be read.
	func lenient<T: Decodable>( _ type: T.Type, forKey key: Key ) -> T? {
		( try? decodeIfPresent( type, forKey: key ) ) ?? nil
	}

	/// The elements that can be read; each one that can't is left out, or replaced by
	/// `placeholder` when positions matter (a deck's keys). Nil when the array is missing
	/// or isn't an array.
	func lenientArray<T: Decodable>( of type: T.Type, forKey key: Key, placeholder: T? = nil ) -> [T]? {
		guard var list = try? nestedUnkeyedContainer( forKey: key ) else { return nil }
		var elements: [T] = []
		while !list.isAtEnd {
			if let element = try? list.decode( T.self ) {
				elements.append( element )
				continue
			}
			// A failed decode doesn't move past the element, so step over it.
			if ( try? list.decodeNil() ) != true {
				guard ( try? list.decode( Skipped.self ) ) != nil else { break }
			}
			if let placeholder { elements.append( placeholder ) }
		}
		return elements
	}
}

/// Decodes from anything, to step over an element.
private struct Skipped: Decodable {
	init( from decoder: Decoder ) throws {}
}
