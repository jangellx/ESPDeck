//
//  BridgeProblem.swift
//  ESPDeck Bridge
//
//  Something that went wrong, for the sidebar's Status section: a short title, and what
//  happened under it.
//

import Foundation

/// A problem to show in Status: "Shortcut Error", then "Key 4: …".
struct BridgeProblem: Equatable {
	let title  : String
	let detail : String

	init( _ title: String, _ detail: String ) {
		self.title  = title
		self.detail = detail
	}
}
