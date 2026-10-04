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

extension Sequence {
	/// The elements gathered by `key` in one pass: groups in the order their first element
	/// appears, each group's elements in their order.
	nonisolated func grouped<Key: Hashable>( by key: ( Element ) -> Key ) -> [( key: Key, elements: [Element] )] {
		var groups: [( key: Key, elements: [Element] )] = []
		var index: [Key: Int] = [:]
		for element in self {
			let group = key( element )
			if let at = index[group] {
				groups[at].elements.append( element )
			} else {
				index[group] = groups.count
				groups.append( ( group, [ element ] ) )
			}
		}
		return groups
	}
}

extension Set {
	/// Whether `member` is in the set; setting it adds or removes it. For a Toggle's binding:
	/// `$parts[contains: part]`.
	subscript( contains member: Element ) -> Bool {
		get { contains( member ) }
		set {
			if newValue { insert( member ) } else { remove( member ) }
		}
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
	/// Its diameter (wider for two digits).
	static let size: CGFloat = 18

	let count : Int
	var color : Color = .accentColor

	@Environment( \.backgroundProminence ) private var prominence
	@Environment( \.sidebarRowSelected ) private var rowSelected

	var body: some View {
		let selected = prominence == .increased || rowSelected
		Text( "\(count)" )
			.font( .caption.weight( .bold ).monospacedDigit() )
			.foregroundStyle( selected ? color : .white )
			.frame( minWidth: Self.size, minHeight: Self.size )
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
					.sidebarSlot()
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
		padding( .trailing, 15.5 )   // measured against the header's count
	}

	/// A sidebar row's right-hand item (ⓘ, arrow, dot, ✕) in a badge-wide slot, centered, so
	/// its center lines up with the counts'.
	func sidebarSlot() -> some View {
		frame( minWidth: SidebarBadge.size )
	}
}

/// An icon button with no border that shows a faint rounded background on hover and a
/// darker one while pressed, so it reads as clickable (the zoom buttons).
struct HoverButtonStyle: ButtonStyle {
	func makeBody( configuration: Configuration ) -> some View {
		HoverButtonBody( configuration: configuration )
	}

	/// The label with its hover and press background.
	private struct HoverButtonBody: View {
		let configuration: ButtonStyleConfiguration

		@State private var hovering = false
		@Environment( \.isEnabled ) private var isEnabled

		var body: some View {
			configuration.label
				.padding( 4 )
				.background {
					RoundedRectangle( cornerRadius: 5, style: .continuous )
						.fill( Color.primary.opacity( !isEnabled ? 0 : configuration.isPressed ? 0.16 : hovering ? 0.08 : 0 ) )
				}
				.contentShape( RoundedRectangle( cornerRadius: 5, style: .continuous ) )
				.onHover { hovering = $0 }
				.animation( .easeOut( duration: 0.12 ), value: hovering )
		}
	}
}
