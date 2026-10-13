//
//  WhatsNewTests.swift
//  ESPDeck BridgeTests
//
//  WhatsNew.md is written by hand for each version, and the app shows whatever it reads from
//  it to every user once. A slip in reading it (a comment shown as a feature, a missing
//  symbol, a fifth feature) would ship unnoticed, and the hash decides who sees it again.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

/// Reading WhatsNew.md.
struct WhatsNewTests {
	private static let file = """
		# What’s New in Something

		<!--
		## Not a feature
		symbol: xmark
		-->

		## Menus
		symbol: square.grid.2x2.fill
		A key can open a menu
		of more keys.

		## No Symbol
		Described on one line.
		"""

	/// The title, each feature's headline, symbol and description; comments are left out.
	@Test func readsFeatures() {
		let whatsNew = WhatsNew( markdown: Self.file )
		#expect( whatsNew.title == "What’s New in Something" )
		#expect( whatsNew.features == [
			WhatsNew.Feature( headline: "Menus", symbol: "square.grid.2x2.fill", description: "A key can open a menu of more keys." ),
			WhatsNew.Feature( headline: "No Symbol", symbol: WhatsNew.defaultSymbol, description: "Described on one line." ),
		] )
	}

	/// No more than four features, however many the file lists.
	@Test func showsAtMostFourFeatures() {
		let many = ( 1...6 ).map { "## Feature \($0)\nsymbol: star\nText." }.joined( separator: "\n\n" )
		#expect( WhatsNew( markdown: many ).features.map( \.headline ) == [ "Feature 1", "Feature 2", "Feature 3", "Feature 4" ] )
	}

	/// The hash follows the file's contents, so any edit shows the window again.
	@Test func hashChangesWithTheFile() {
		let first  = WhatsNew( markdown: Self.file )
		let same   = WhatsNew( markdown: Self.file )
		let edited = WhatsNew( markdown: Self.file + "\n" )
		#expect( first.hash == same.hash )
		#expect( first.hash != edited.hash )
		#expect( first.hash.count == 64 )
	}
}
