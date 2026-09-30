//
//  SharedViews.swift
//  ESPDeck Bridge
//
//  Small pieces the pages share: gray captions, a title with a caption under it, the orange
//  warning line, and a Bool binding for dialogs shown while an optional is set.
//

import SwiftUI

extension View {
	/// Caption-sized and gray. `Color.secondary` rather than `.secondary`, so it stays gray in
	/// section headers and button labels, where `.secondary` follows their own style.
	func secondaryCaption() -> some View {
		font( .caption )
			.foregroundStyle( Color.secondary )
	}
}

/// A line of text with a gray caption under it, as in a Settings row.
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

/// The accent color, except on a selected sidebar row, where it would vanish into the blue
/// selection: there it's the row's text color (white).
private struct SidebarAccent: ViewModifier {
	@Environment( \.backgroundProminence ) private var prominence

	func body( content: Content ) -> some View {
		content.foregroundStyle( prominence == .increased ? AnyShapeStyle( .primary ) : AnyShapeStyle( .tint ) )
	}
}

/// A count in a capsule, accent on white text, turned around on a selected sidebar row.
struct SidebarBadge: View {
	let count: Int

	@Environment( \.backgroundProminence ) private var prominence

	var body: some View {
		let selected = prominence == .increased
		Text( "\(count)" )
			.font( .caption.weight( .bold ).monospacedDigit() )
			.foregroundStyle( selected ? Color.accentColor : .white )
			.frame( minWidth: 18, minHeight: 18 )
			.padding( .horizontal, count > 9 ? 3 : 0 )
			.background( Capsule().fill( selected ? Color.white : Color.accentColor ) )
	}
}

extension View {
	/// Accent-colored, but white on a selected sidebar row (SidebarAccent).
	func sidebarAccent() -> some View {
		modifier( SidebarAccent() )
	}
}
