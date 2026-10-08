//
//  TrafficViews.swift
//  ESPDeck Bridge
//
//  The Log tab (every frame to and from a device, timestamped), and the transfer status
//  under the simulated deck.
//

import SwiftUI

/// The Log page: a device's traffic, newest first, with a filter, Copy and Clear. Rows can be
/// selected, several at once (Cmd-click, Shift-click), and copied with Cmd-C, the Copy
/// button, or a right-click. The selection is kept here rather than by the List, whose own
/// selection ignores Cmd and Shift on Catalyst.
struct TrafficLogView: View {
	let device    : DeckDevice
	let window    : WindowState
	/// The Log page is the one showing. It stays alive behind the others (to keep its scroll
	/// position), and doesn't follow the log while it's hidden.
	let isShowing : Bool

	@State private var filter = ""
	/// The entries that pass the filter, newest first. Kept, and worked out again a few times
	/// a second at most while entries arrive: laying out the list for every single entry held
	/// up the main thread, and with it the key presses still coming in.
	@State private var shown: [TrafficEntry] = []
	/// A refresh is on its way.
	@State private var refreshPending = false

	/// How long new entries wait to be shown together.
	private static let refreshInterval: Duration = .milliseconds( 250 )
	/// The row last clicked without Shift, which a Shift-click selects from.
	@State private var anchor: TrafficEntry.ID?

	var body: some View {
		let selected = window.logSelection.count

		VStack( spacing: 0 ) {
			HStack {
				TextField( "Filter", text: $filter, prompt: Text( "Filter (e.g. pressed, image, keyDown)" ) )
					.textFieldStyle( .roundedBorder )
					.frame( maxWidth: 320 )
				Spacer()
				LogCount( device: device, selected: selected )
				Button( selected == 0 ? "Copy All" : "Copy Selected" ) { copy( selected == 0 ? nil : window.logSelection ) }
					.disabled( shown.isEmpty )
				ClearLogButton( device: device )
			}
			.padding( 12 )

			Divider()

			if shown.isEmpty {
				ContentUnavailableView( "No Traffic", systemImage: "arrow.up.arrow.down",
										description: Text( device.isOnline ? "Messages to and from this device appear here." : "The device is offline." ) )
					// Fills the page as the list does, so the filter bar stays at the top and the
					// footer at the bottom.
					.frame( maxWidth: .infinity, maxHeight: .infinity )
			} else {
				List( shown ) { entry in
					let selected = window.logSelection.contains( entry.id )
					LogRow( entry: entry, selected: selected ) { copy( [ entry.id ] ) }
						.onTapGesture { click( entry ) }
						// On a selected row, the selection; on any other, that row.
						.contextMenu {
							let ids = selected ? window.logSelection : [ entry.id ]
							Button( ids.count == 1 ? "Copy Entry" : "Copy \(ids.count) Entries" ) { copy( ids ) }
						}
						// No lines between entries, and only as tall as their text.
						.listRowSeparator( .hidden )
						.listRowInsets( EdgeInsets( top: 2, leading: 12, bottom: 2, trailing: 12 ) )
						// The selection in the full accent color, with the row in white on it.
						.listRowBackground( selected ? Color.accentColor : Color.clear )
				}
				.listStyle( .plain )
				.environment( \.defaultMinListRowHeight, 0 )
			}

			// While the deck is catching up on key images: how far it's got.
			TransferProgressFooter( device: device )
		}
		// The page itself doesn't read the log (LogFollower, LogCount and ClearLogButton do),
		// so an entry arriving doesn't run this whole body.
		.modifier( LogFollower( device: device, changed: refreshSoon ) )
		.onChange( of: filter ) { refresh() }
		.onChange( of: isShowing, initial: true ) { if isShowing { refresh() } }
	}

	/// Shows the entries that have arrived, together, after refreshInterval; nothing while
	/// the page is hidden (it catches up when it's shown).
	private func refreshSoon() {
		guard isShowing, !refreshPending else { return }
		refreshPending = true
		Task {
			try? await Task.sleep( for: Self.refreshInterval )
			refreshPending = false
			if isShowing { refresh() }
		}
	}

	/// Filters the log again, and drops entries that are no longer shown from the selection.
	private func refresh() {
		shown = device.log.reversed().filter { filter.isEmpty || $0.summary.localizedStandardContains( filter ) || $0.detail.localizedStandardContains( filter ) }
		let ids = Set( shown.map( \.id ) )
		if !window.logSelection.isSubset( of: ids ) {
			window.logSelection.formIntersection( ids )
		}
	}

	/// A click on a row, as in a Mac list: alone it selects just that row; with Cmd it adds or
	/// removes the row; with Shift it selects from the last row clicked to this one (added to
	/// the selection with Cmd too).
	private func click( _ entry: TrafficEntry ) {
		let modifiers = window.clickModifiers
		if modifiers.contains( .shift ), let anchor,
		   let from = shown.firstIndex( where: { $0.id == anchor } ), let to = shown.firstIndex( where: { $0.id == entry.id } ) {
			let range = Set( shown[min( from, to )...max( from, to )].map( \.id ) )
			window.logSelection = modifiers.contains( .command ) ? window.logSelection.union( range ) : range
		} else if modifiers.contains( .command ) {
			window.logSelection[contains: entry.id].toggle()
			anchor = entry.id
		} else {
			window.logSelection = [ entry.id ]
			anchor = entry.id
		}
	}

	/// Copies the shown entries with these IDs (all of them for nil) as text, oldest first.
	private func copy( _ ids: Set<TrafficEntry.ID>? ) {
		UIPasteboard.general.string = TrafficEntry.plainText( shown.reversed().filter { ids?.contains( $0.id ) ?? true } )
	}
}

/// Calls `changed` when the device's log gains an entry or is cleared. On its own, so that
/// only this (and not the page it's on) is run again for each entry.
private struct LogFollower: ViewModifier {
	let device  : DeckDevice
	let changed : () -> Void

	func body( content: Content ) -> some View {
		content
			.onChange( of: device.log.last?.id ) { changed() }
			.onChange( of: device.log.count ) { changed() }   // Clear leaves no newest entry to change
	}
}

/// "N entries", or how many of them are selected.
private struct LogCount: View {
	let device   : DeckDevice
	let selected : Int

	var body: some View {
		Text( selected == 0 ? "\(device.log.count) entries" : "\(selected) of \(device.log.count) selected" )
			.secondaryCaption()
	}
}

/// Clear, which empties the device's log.
private struct ClearLogButton: View {
	let device: DeckDevice

	var body: some View {
		Button( "Clear" ) { device.log.removeAll() }
			.disabled( device.log.isEmpty )
	}
}

/// A log entry's row: the time, the direction, what happened over the frame itself, and its
/// size, then a copy button at the right edge that shows while the pointer is over the row.
/// The button's space is always there, so nothing moves.
private struct LogRow: View {
	let entry    : TrafficEntry
	/// On the selection's accent color, where the direction's own color would be lost.
	let selected : Bool
	let copy     : () -> Void

	@State private var hovering = false

	/// The secondary text's color: gray, or pale white on the selection.
	private var dim: Color { selected ? Color.white.opacity( 0.8 ) : Color.secondary }

	var body: some View {
		HStack( alignment: .firstTextBaseline, spacing: 10 ) {
			Text( entry.date, format: TrafficEntry.timeFormat )
				.monospacedDigit()
				.foregroundStyle( dim )
			Image( systemName: Self.symbol( entry.direction ) )
				.foregroundStyle( selected ? Color.white : Self.color( entry.direction ) )
				.accessibilityLabel( Self.name( entry.direction ) )
			VStack( alignment: .leading, spacing: 1 ) {
				Text( entry.summary )
					.fontWeight( entry.direction == .event ? .semibold : .regular )
					.foregroundStyle( selected ? Color.white : Color.primary )
					.lineLimit( 2 )
				if !entry.detail.isEmpty {
					Text( entry.detail )
						.font( .caption.monospaced() )
						.foregroundStyle( dim )
						.lineLimit( 2 )
				}
			}
			Spacer( minLength: 8 )
			if entry.bytes > 0 {
				Text( ByteCountFormatter.string( fromByteCount: Int64( entry.bytes ), countStyle: .file ) )
					.monospacedDigit()
					.foregroundStyle( dim )
			}
			Button( action: copy ) {
				Image( systemName: "doc.on.doc" )
			}
			.buttonStyle( .borderless )
			.tint( selected ? Color.white : nil )
			.help( "Copy this entry" )
			.accessibilityLabel( "Copy entry" )
			.opacity( hovering ? 1 : 0 )
		}
		.font( .callout )
		.contentShape( Rectangle() )
		.onHover { hovering = $0 }
	}

	/// Each direction's symbol.
	private static func symbol( _ direction: TrafficEntry.Direction ) -> String {
		switch direction {
			case .sent:     "arrow.up.circle.fill"
			case .received: "arrow.down.circle.fill"
			case .event:    "bolt.circle.fill"
		}
	}

	/// Each direction's color.
	private static func color( _ direction: TrafficEntry.Direction ) -> Color {
		switch direction {
			case .sent:     .accentColor
			case .received: .green
			case .event:    .orange
		}
	}

	/// Each direction's name, for VoiceOver.
	private static func name( _ direction: TrafficEntry.Direction ) -> String {
		switch direction {
			case .sent:     "Sent"
			case .received: "Received"
			case .event:    "Event"
		}
	}
}

/// Under the Log: how far this deck is through the key images being sent to it, as a ring
/// that fills, with the count beside it; a solid gray dot and Idle (or Offline) when nothing
/// is. Always there, so the list doesn't jump. A diagnostic, so it lives here rather than
/// with the keys.
struct TransferProgressFooter: View {
	let device: DeckDevice

	/// The ring's (and the idle dot's) diameter.
	private static let size: CGFloat = 14

	var body: some View {
		let busy  = device.isOnline && !device.pendingShows.isEmpty
		let total = busy ? max( device.batchTotal, device.pendingShows.count ) : 1
		let done  = busy ? total - device.pendingShows.count : 0
		VStack( spacing: 0 ) {
			Divider()
			HStack( spacing: 8 ) {
				if busy {
					ProgressRing( fraction: Double( done ) / Double( total ) )
						.frame( width: Self.size, height: Self.size )
				} else {
					// A dot, not an empty ring: the ring doesn't run backward when an update ends.
					Circle()
						.fill( .tertiary )
						.frame( width: Self.size, height: Self.size )
				}
				Text( busy ? "Updating the deck: \(done) of \(total) \(total == 1 ? "key" : "keys")"
						   : device.isOnline ? "Idle" : "Offline" )
					.font( .caption )
					.foregroundStyle( busy ? .primary : .secondary )
				Spacer( minLength: 0 )
			}
			.padding( 12 )
			.accessibilityElement( children: .combine )
		}
	}
}

/// A ring that fills clockwise from the top. Drawn here: Catalyst's circular ProgressView
/// only spins, whatever its value.
private struct ProgressRing: View {
	/// 0 to 1.
	let fraction: Double

	var body: some View {
		ZStack {
			Circle()
				.stroke( .quaternary, lineWidth: 3 )
			Circle()
				.trim( from: 0, to: min( max( fraction, 0 ), 1 ) )
				.stroke( Color.accentColor, style: StrokeStyle( lineWidth: 3, lineCap: .round ) )
				.rotationEffect( .degrees( -90 ) )
				.animation( .easeOut( duration: 0.15 ), value: fraction )
		}
		.padding( 1.5 )   // the stroke straddles the circle's edge
	}
}
