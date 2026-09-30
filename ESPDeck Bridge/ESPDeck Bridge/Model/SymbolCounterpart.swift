//
//  SymbolCounterpart.swift
//  ESPDeck Bridge
//
//  Finds the SF Symbol that suits a key's opposite state: lightswitch.on.square for On gives
//  lightswitch.off.square for Off, lightbulb.fill gives lightbulb, door.garage.open gives
//  door.garage.closed, lock gives lock.open.
//

import UIKit

/// SF Symbol names for a state's opposite; see the file comment.
enum SymbolCounterpart {
	/// The symbol for `target` that pairs with `symbol`, or nil when there's no real SF Symbol
	/// that fits. `target` is the state the returned symbol is for.
	static func symbol( pairing symbol: String, for target: KeyState ) -> String? {
		candidates( for: symbol, target: target ).first { $0 != symbol && UIImage( systemName: $0 ) != nil }
	}

	/// `symbol` as it should look in `state`, for a default icon: the matching variant, if
	/// there is one, except that Off never gains a slash (the symbol itself is the plain one).
	static func variant( of symbol: String, for state: KeyState ) -> String {
		guard let variant = self.symbol( pairing: symbol, for: state ),
			  symbol.contains( "slash" ) || !variant.contains( "slash" ) else { return symbol }
		return variant
	}

	/// Names that might suit `target`, best first; they may not exist.
	private static func candidates( for symbol: String, target: KeyState ) -> [String] {
		let parts   = symbol.split( separator: "." ).map( String.init )
		let filled  = parts.last == "fill"
		let base    = filled ? Array( parts.dropLast() ) : parts
		let join    = { ( parts: [String], fill: Bool ) in ( parts + ( fill ? [ "fill" ] : [] ) ).joined( separator: "." ) }

		// A symbol with .on/.off in it (lightswitch.on.square), or poweron/poweroff: that part
		// says the state, and the rest (square, fill) stays as it is. Only when the other one
		// exists: in doc.on.doc, "on" isn't a state, so it fills and unfills as usual.
		if target == .on || target == .off {
			let words: [String: String] = [ "on": "off", "off": "on", "poweron": "poweroff", "poweroff": "poweron" ]
			if let index = base.firstIndex( where: { words[$0] != nil } ) {
				var swapped = base
				swapped[index] = words[base[index]]!
				let other = join( swapped, filled )
				if UIImage( systemName: other ) != nil {
					let wanted = target == .on ? [ "on", "poweron" ] : [ "off", "poweroff" ]
					return wanted.contains( base[index] ) ? [] : [ other ]   // [] when already right
				}
			}
		}

		switch target {
			case .off:
				// Unfilled first (lightbulb.fill → lightbulb), then slashed (bell → bell.slash).
				var result: [String] = []
				if filled { result.append( join( base, false ) ) }
				result.append( join( base + [ "slash" ], filled ) )
				return result

			case .on:
				// Drop a slash (bell.slash → bell), then fill (lightbulb → lightbulb.fill).
				var result: [String] = []
				if base.last == "slash" {
					result.append( join( base.dropLast(), filled ) )
					result.append( join( base.dropLast(), true ) )
				}
				if !filled { result.append( join( base, true ) ) }
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
