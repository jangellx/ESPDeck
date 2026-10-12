//
//  BridgeProblem.swift
//  ESPDeck Bridge
//
//  Something that went wrong, for the sidebar's Status section: a short title, and what
//  happened under it.
//

import Foundation

/// A problem to show in Status: "Shortcut Error", then "Key 4: …", and optionally a button
/// that goes where it can be fixed.
struct BridgeProblem: Equatable {
	/// A button under the problem: its title, and the URL it opens.
	struct Link: Equatable {
		let title : String
		let url   : URL
	}

	let title  : String
	let detail : String
	var link   : Link?

	init( _ title: String, _ detail: String, link: Link? = nil ) {
		self.title  = title
		self.detail = detail
		self.link   = link
	}

	/// Opens a question of the FAQ on GitHub, by its heading's anchor.
	static func faq( _ anchor: String, repository: String? ) -> Link? {
		URL( string: "https://github.com/\(repository ?? "jangellx/ESPDeck")/blob/main/docs/faq.md#\(anchor)" )
			.map { Link( title: "Why This Happens", url: $0 ) }
	}

	/// The FAQ's question about garage doors and locks while the Mac is locked (docs/faq.md;
	/// GitHub makes the anchor from the heading).
	static let lockedMacAnchor = "garage-doors-and-locks-dont-work-while-the-mac-is-locked"

	/// Opens a shortcut in the Shortcuts editor, by name (Shortcuts' own URL scheme).
	static func openShortcut( named name: String ) -> Link? {
		var components        = URLComponents()
		components.scheme     = "shortcuts"
		components.host       = "open-shortcut"
		components.queryItems = [ URLQueryItem( name: "name", value: name ) ]
		return components.url.map { Link( title: "Open in Shortcuts", url: $0 ) }
	}
}
