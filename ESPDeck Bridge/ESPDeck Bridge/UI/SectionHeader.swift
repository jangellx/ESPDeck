//
//  SectionHeader.swift
//  ESPDeck Bridge
//
//  A form section's title styled like System Settings: bold, in the label colour, and not
//  upper-cased. A grouped Form on Mac Catalyst otherwise draws a small grey caption, and
//  `headerProminence(.increased)` doesn't change that there. The colour is `Color.primary`
//  rather than `.primary`: in a header, `.primary` means the header's own (grey) style.
//

import SwiftUI

struct SectionHeader: View {
	let title : String
	/// Sidebar sections keep the sidebar's own smaller font, just not its grey.
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
