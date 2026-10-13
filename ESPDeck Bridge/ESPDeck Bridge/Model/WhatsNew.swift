//
//  WhatsNew.swift
//  ESPDeck Bridge
//
//  What the What's New window shows, read from WhatsNew.md in the app's bundle: a title and
//  one to four features, each a headline, an SF Symbol and a description. The window is
//  shown once before the configuration window whenever that file has changed, which is
//  judged by its hash.
//

import CryptoKit
import Foundation

/// The contents of WhatsNew.md.
struct WhatsNew: Equatable {
	/// One thing that's new.
	struct Feature: Equatable, Identifiable {
		var headline    : String
		/// An SF Symbol's name.
		var symbol      : String
		var description : String

		var id: String { headline }
	}

	var title    = "What\u{2019}s New in ESPDeck Bridge"
	var features : [Feature] = []
	/// SHA-256 of the file, in hex: what's remembered once the window has been seen.
	var hash     = ""

	/// At most this many features are shown, as in Apple's own What's New windows.
	static let maxFeatures = 4
	/// The symbol for a feature that names none.
	static let defaultSymbol = "sparkles"

	/// Where the hash of the file last shown is kept.
	private static let seenDefault = "whatsNewSeenHash"

	/// The bundle's WhatsNew.md; nil if it's missing or lists nothing.
	static let bundled: WhatsNew? = {
		guard let url = Bundle.main.url( forResource: "WhatsNew", withExtension: "md" ), let data = try? Data( contentsOf: url ) else { return nil }
		let parsed = WhatsNew( markdown: String( decoding: data, as: UTF8.self ), data: data )
		return parsed.features.isEmpty ? nil : parsed
	}()

	/// Reads the file's text: "# Title", then for each feature "## Headline", a "symbol:"
	/// line, and its description (lines are joined with spaces). HTML comments are skipped.
	init( markdown: String, data: Data? = nil ) {
		hash = SHA256.hash( data: data ?? Data( markdown.utf8 ) ).map { String( format: "%02x", $0 ) }.joined()

		var inComment = false
		for raw in markdown.components( separatedBy: .newlines ) {
			let line = raw.trimmingCharacters( in: .whitespaces )
			if inComment {
				if line.contains( "-->" ) { inComment = false }
				continue
			}
			if line.hasPrefix( "<!--" ) {
				inComment = !line.contains( "-->" )
				continue
			}
			if line.hasPrefix( "## " ) {
				features.append( Feature( headline: String( line.dropFirst( 3 ) ).trimmingCharacters( in: .whitespaces ), symbol: Self.defaultSymbol, description: "" ) )
			} else if line.hasPrefix( "# " ) {
				if features.isEmpty { title = String( line.dropFirst( 2 ) ).trimmingCharacters( in: .whitespaces ) }
			} else if let last = features.indices.last, !line.isEmpty {
				if line.lowercased().hasPrefix( "symbol:" ) {
					let symbol = line.dropFirst( "symbol:".count ).trimmingCharacters( in: .whitespaces )
					if !symbol.isEmpty { features[last].symbol = symbol }
				} else {
					features[last].description += ( features[last].description.isEmpty ? "" : " " ) + line
				}
			}
		}
		features = Array( features.filter { !$0.headline.isEmpty }.prefix( Self.maxFeatures ) )
	}

	/// Whether this file has been shown: its hash is the one remembered.
	var isSeen: Bool {
		UserDefaults.standard.string( forKey: Self.seenDefault ) == hash
	}

	/// Remembers that this file has been shown (or, for a new installation, needn't be).
	func markSeen() {
		UserDefaults.standard.set( hash, forKey: Self.seenDefault )
	}
}
