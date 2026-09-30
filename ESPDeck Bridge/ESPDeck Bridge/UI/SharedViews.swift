//
//  SharedViews.swift
//  ESPDeck Bridge
//
//  Small pieces the pages share: grey captions, a title with a caption under it, the orange
//  warning line, and a Bool binding for dialogs shown while an optional is set.
//

import SwiftUI

extension View {
	/// Caption-sized and grey. `Color.secondary` rather than `.secondary`, so it stays grey in
	/// section headers and button labels, where `.secondary` follows their own style.
	func secondaryCaption() -> some View {
		font( .caption )
			.foregroundStyle( Color.secondary )
	}
}

/// A line of text with a grey caption under it, as in a Settings row.
struct CaptionedText: View {
	let title   : String
	let caption : String
	var spacing : CGFloat = 1

	init( _ title: String, caption: String, spacing: CGFloat = 1 ) {
		self.title   = title
		self.caption = caption
		self.spacing = spacing
	}

	var body: some View {
		VStack( alignment: .leading, spacing: spacing ) {
			Text( title )
			Text( caption )
				.secondaryCaption()
		}
	}
}

/// Something that went wrong, in orange behind a warning triangle.
struct WarningLabel: View {
	let text: String

	init( _ text: String ) {
		self.text = text
	}

	var body: some View {
		Label( text, systemImage: "exclamationmark.triangle.fill" )
			.foregroundStyle( .orange )
	}
}

extension Binding where Value == Bool {
	/// True while `value` is set; dismissing (setting false) clears it. For dialogs and alerts
	/// about a pending item.
	init<Wrapped: Sendable>( presenting value: Binding<Wrapped?> ) {
		self.init {
			value.wrappedValue != nil
		} set: { shown in
			if !shown { value.wrappedValue = nil }
		}
	}
}

extension Sequence where Element: Hashable {
	/// The elements in their order, each only the first time it appears.
	nonisolated func uniqued() -> [Element] {
		var seen: Set<Element> = []
		return filter { seen.insert( $0 ).inserted }
	}
}
