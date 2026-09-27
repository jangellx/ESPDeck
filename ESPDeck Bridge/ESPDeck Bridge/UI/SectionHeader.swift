//
//  SectionHeader.swift
//  ESPDeck Bridge
//
//  A form section's title styled like System Settings: bold, in the primary colour, and not
//  upper-cased. A grouped Form on Mac Catalyst otherwise draws a small grey caption, and
//  `headerProminence(.increased)` doesn't change that there.
//

import SwiftUI

struct SectionHeader: View {
	let title: String

	init( _ title: String ) {
		self.title = title
	}

	var body: some View {
		Text( title )
			.font( .headline )
			.foregroundStyle( .primary )
			.textCase( nil )
	}
}
