//
//  SymbolCounterpartTests.swift
//  ESPDeck BridgeTests
//
//  A key's icon for On and Off comes from one symbol and its counterpart. The rules have
//  regressed before (doc.on.doc lost its fill), so the cases that matter are pinned here.
//

import Testing
@testable import ESPDeck_Bridge

/// The SF Symbol that suits a key's other state.
struct SymbolCounterpartTests {
	/// A symbol and the state asked for, with the symbol that state should show.
	struct Case: Sendable, CustomTestStringConvertible {
		let symbol   : String
		let state    : KeyState
		let expected : String

		var testDescription: String { "\(symbol) for \(state.rawValue) → \(expected)" }
	}

	@Test( arguments: [
		// Filled is on, plain is off.
		Case( symbol: "lightbulb", state: .on, expected: "lightbulb.fill" ),
		Case( symbol: "lightbulb.fill", state: .off, expected: "lightbulb" ),
		// A symbol that says on or off in its name swaps the word and keeps the rest.
		Case( symbol: "lightswitch.on", state: .off, expected: "lightswitch.off" ),
		Case( symbol: "lightswitch.off", state: .on, expected: "lightswitch.on" ),
		Case( symbol: "lightswitch.on.fill", state: .off, expected: "lightswitch.off.fill" ),
		// Already right for the state: unchanged.
		Case( symbol: "lightswitch.on", state: .on, expected: "lightswitch.on" ),
		// "on" that isn't a state: fills and unfills as any other symbol.
		Case( symbol: "doc.on.doc", state: .on, expected: "doc.on.doc.fill" ),
		Case( symbol: "doc.on.doc.fill", state: .off, expected: "doc.on.doc" ),
		// Off never gains a slash the symbol didn't have.
		Case( symbol: "bell", state: .off, expected: "bell" ),
		// A slashed symbol loses it for on.
		Case( symbol: "bell.slash", state: .on, expected: "bell" ),
	] )
	func picksTheVariantForAState( _ example: Case ) {
		#expect( SymbolCounterpart.variant( of: example.symbol, for: example.state ) == example.expected )
	}

	/// A name that isn't an SF Symbol has no counterpart, and stays as it is.
	@Test func leavesUnknownSymbolsAlone() {
		#expect( SymbolCounterpart.symbol( pairing: "not.a.real.symbol", for: .on ) == nil )
		#expect( SymbolCounterpart.variant( of: "not.a.real.symbol", for: .on ) == "not.a.real.symbol" )
	}
}
