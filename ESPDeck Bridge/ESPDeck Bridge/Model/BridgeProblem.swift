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
	/// Worth a notification: it happened behind the user's back (a key press, a trigger),
	/// not in answer to something just done in the window.
	var notifies = false

	init( _ title: String, _ detail: String, link: Link? = nil, notifies: Bool = false ) {
		self.title    = title
		self.detail   = detail
		self.link     = link
		self.notifies = notifies
	}

	/// Opens a shortcut in the Shortcuts editor, by name (Shortcuts' own URL scheme).
	static func openShortcut( named name: String ) -> Link? {
		var components        = URLComponents()
		components.scheme     = "shortcuts"
		components.host       = "open-shortcut"
		components.queryItems = [ URLQueryItem( name: "name", value: name ) ]
		return components.url.map { Link( title: "Open in Shortcuts", url: $0 ) }
	}
}
