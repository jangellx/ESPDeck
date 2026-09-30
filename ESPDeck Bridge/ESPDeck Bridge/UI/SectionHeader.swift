//
//  SectionHeader.swift
//  ESPDeck Bridge
//
//  A form section's title styled like System Settings: bold, in the label color, and not
//  upper-cased. A grouped Form on Mac Catalyst otherwise draws a small gray caption, and
//  `headerProminence(.increased)` doesn't change that there. The color is `Color.primary`
//  rather than `.primary`: in a header, `.primary` means the header's own (gray) style.
//

import SwiftUI

/// A section's title in the label color, not the form's gray caption.
struct SectionHeader: View {
	let title : String
	/// Sidebar sections keep the sidebar's own smaller font, just not its gray.
	var sidebar = false

	init( _ title: String, sidebar: Bool = false ) {
		self.title   = title
		self.sidebar = sidebar
	}

	var body: some View {
		Text( title )
			.font( sidebar ? nil : .headline )
			.foregroundStyle( Color.primary )
			.textCase( nil )
	}
}
