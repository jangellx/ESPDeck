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

extension EnvironmentValues {
	/// Set on a sidebar row while it's selected. The Mac's sidebar doesn't raise
	/// backgroundProminence for its selection, so rows say so themselves.
	@Entry var sidebarRowSelected = false
}

/// The accent color, except on a selected sidebar row, where it would vanish into the blue
/// selection: there it's the row's text color (white).
private struct SidebarAccent: ViewModifier {
	@Environment( \.backgroundProminence ) private var prominence
	@Environment( \.sidebarRowSelected ) private var rowSelected

	func body( content: Content ) -> some View {
		content.foregroundStyle( prominence == .increased || rowSelected ? AnyShapeStyle( .white ) : AnyShapeStyle( .tint ) )
	}
}

/// A count in a capsule, white on `color` (the accent unless given), turned around on a
/// selected sidebar row.
struct SidebarBadge: View {
	let count : Int
	var color : Color = .accentColor

	@Environment( \.backgroundProminence ) private var prominence
	@Environment( \.sidebarRowSelected ) private var rowSelected

	var body: some View {
		let selected = prominence == .increased || rowSelected
		Text( "\(count)" )
			.font( .caption.weight( .bold ).monospacedDigit() )
			.foregroundStyle( selected ? color : .white )
			.frame( minWidth: 18, minHeight: 18 )
			.padding( .horizontal, count > 9 ? 3 : 0 )
			.background( Capsule().fill( selected ? Color.white : color ) )
	}
}

extension View {
	/// Accent-colored, but white on a selected sidebar row (SidebarAccent).
	func sidebarAccent() -> some View {
		modifier( SidebarAccent() )
	}
}

/// A problem in the sidebar's Status section, laid out like the rows above it: an orange
/// warning sign, the title in the body font, what happened in a caption under it, and an ✕
/// that clears it (when it can be cleared).
struct ProblemRow: View {
	let problem   : BridgeProblem
	var onDismiss : ( () -> Void )?

	var body: some View {
		Label {
			HStack( alignment: .firstTextBaseline ) {
				VStack( alignment: .leading, spacing: 1 ) {
					Text( problem.title )
						.foregroundStyle( .primary )
					Text( problem.detail )
						.secondaryCaption()
					if let link = problem.link {
						Link( destination: link.url ) {
							Label( link.title, systemImage: "arrow.up.forward.app" )
						}
						.font( .caption )
						.buttonStyle( .borderless )
						.padding( .top, 3 )
					}
				}
				Spacer( minLength: 4 )
				if let onDismiss {
					Button( action: onDismiss ) {
						Image( systemName: "xmark.circle.fill" )
							.foregroundStyle( .secondary )
					}
					.buttonStyle( .borderless )
					.help( "Clear" )
					.accessibilityLabel( "Clear \(problem.title)" )
				}
			}
			.sidebarTrailingInset()
		} icon: {
			Image( systemName: "exclamationmark.triangle.fill" )
				.foregroundStyle( .orange )
		}
	}
}

extension View {
	/// A bar floating at the bottom naming a problem further down, while there's one to show;
	/// clicking it runs `reveal`. An overlay rather than a safe-area bar: on Mac Catalyst a
	/// safe-area bar kept (and stretched) its space after its content went away.
	func problemBar( _ problem: BridgeProblem?, reveal: @escaping () -> Void ) -> some View {
		overlay( alignment: .bottom ) {
			if let problem {
				ProblemBar( title: problem.title, reveal: reveal )
					.background( .regularMaterial, in: RoundedRectangle( cornerRadius: 10, style: .continuous ) )
					.overlay( RoundedRectangle( cornerRadius: 10, style: .continuous ).strokeBorder( Color.orange.opacity( 0.4 ), lineWidth: 1 ) )
					.padding( 8 )
					.transition( .move( edge: .bottom ).combined( with: .opacity ) )
			}
		}
		.animation( .easeOut( duration: 0.2 ), value: problem )
	}
}

/// "Shortcut Error ⌄" at the bottom of the sidebar, which scrolls to it when clicked.
private struct ProblemBar: View {
	let title  : String
	let reveal : () -> Void

	var body: some View {
		Button( action: reveal ) {
			HStack {
				Label( title, systemImage: "exclamationmark.triangle.fill" )
				Spacer()
				Image( systemName: "chevron.down" )
			}
			.font( .callout )
			.frame( maxWidth: .infinity, alignment: .leading )
			.padding( .horizontal, 14 )
			.padding( .vertical, 8 )
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.foregroundStyle( .orange )
		.help( "Show it in Status" )
	}
}

extension View {
	/// Reports whether this view is on screen in its scroll view (List included): at least
	/// half of it showing. Before iOS 18, onAppear and onDisappear stand in, which a List that
	/// doesn't need to scroll doesn't report reliably.
	@ViewBuilder
	func onOnScreenChange( _ action: @escaping ( Bool ) -> Void ) -> some View {
		if #available( iOS 18.0, * ) {
			onScrollVisibilityChange( threshold: 0.5, action )
		} else {
			onAppear { action( true ) }
				.onDisappear { action( false ) }
		}
	}
}

extension View {
	/// Room on the right of a sidebar row, so its badge or button lines up with the count in a
	/// collapsible section's header, which sits left of the system's disclosure arrow.
	func sidebarTrailingInset() -> some View {
		padding( .trailing, 14 )
	}
}
