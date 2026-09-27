//
//  SymbolCounterpart.swift
//  ESPDeck Bridge
//
//  Finds the SF Symbol that suits a key's opposite state: lightbulb.fill for On gives
//  lightbulb for Off, door.garage.open gives door.garage.closed, lock gives lock.open.
//

import UIKit

enum SymbolCounterpart {
	/// The symbol for `target` that pairs with `symbol`, or nil when there's no real SF Symbol
	/// that fits. `target` is the state the returned symbol is for.
	static func symbol( pairing symbol: String, for target: KeyState ) -> String? {
		candidates( for: symbol, target: target ).first { $0 != symbol && UIImage( systemName: $0 ) != nil }
	}

	private static func candidates( for symbol: String, target: KeyState ) -> [String] {
		let parts   = symbol.split( separator: "." ).map( String.init )
		let filled  = parts.last == "fill"
		let base    = filled ? Array( parts.dropLast() ) : parts
		let join    = { ( parts: [String], fill: Bool ) in ( parts + ( fill ? [ "fill" ] : [] ) ).joined( separator: "." ) }

		switch target {
			case .off:
				// Unfilled first (lightbulb.fill → lightbulb), then slashed (bell → bell.slash).
				var result: [String] = []
				if filled { result.append( join( base, false ) ) }
				result.append( join( base + [ "slash" ], filled ) )
				if base.last == "on" { result.append( join( base.dropLast() + [ "off" ], filled ) ) }
				return result

			case .on:
				// Drop a slash (bell.slash → bell), then fill (lightbulb → lightbulb.fill).
				var result: [String] = []
				if base.last == "slash" {
					result.append( join( base.dropLast(), filled ) )
					result.append( join( base.dropLast(), true ) )
				}
				if !filled { result.append( join( base, true ) ) }
				if base.last == "off" { result.append( join( base.dropLast() + [ "on" ], filled ) ) }
				return result

			case .closed, .locked:
				// door.garage.open → door.garage.closed; lock.open → lock.
				guard let index = base.firstIndex( of: "open" ) else { return [] }
				var closed = base
				closed[index] = "closed"
				var removed = base
				removed.remove( at: index )
				return [ join( closed, filled ), join( removed, filled ) ]

			case .open, .unlocked:
				// door.garage.closed → door.garage.open; lock → lock.open.
				if let index = base.firstIndex( of: "closed" ) {
					var open = base
					open[index] = "open"
					return [ join( open, filled ) ]
				}
				guard !base.contains( "open" ), let first = base.first else { return [] }
				return [ join( [ first, "open" ] + base.dropFirst(), filled ) ]

			default:
				return []
		}
	}
}
