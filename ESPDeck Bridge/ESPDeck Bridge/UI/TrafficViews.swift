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
/// button, or a right-click.
struct TrafficLogView: View {
	let device : DeckDevice
	let window : WindowState

	@State private var filter = ""
	/// The entries that pass the filter, newest first. Kept, and only worked out again when the
	/// log or the filter changes (see Source), not each time a selection redraws the page.
	@State private var shown: [TrafficEntry] = []

	/// What `shown` was made from.
	private struct Source: Equatable {
		let filter : String
		let newest : TrafficEntry.ID?
		let count  : Int
	}

	var body: some View {
		@Bindable var window = window
		let selected = window.logSelection.count

		VStack( spacing: 0 ) {
			HStack {
				TextField( "Filter", text: $filter, prompt: Text( "Filter (e.g. pressed, image, keyDown)" ) )
					.textFieldStyle( .roundedBorder )
					.frame( maxWidth: 320 )
				Spacer()
				Text( selected == 0 ? "\(device.log.count) entries" : "\(selected) of \(device.log.count) selected" )
					.secondaryCaption()
				Button( selected == 0 ? "Copy All" : "Copy Selected" ) { copy( selected == 0 ? nil : window.logSelection ) }
					.disabled( shown.isEmpty )
				Button( "Clear" ) { device.log.removeAll() }
					.disabled( device.log.isEmpty )
			}
			.padding( 12 )

			Divider()

			if shown.isEmpty {
				ContentUnavailableView( "No Traffic", systemImage: "arrow.up.arrow.down",
										description: Text( device.isOnline ? "Messages to and from this device appear here." : "The device is offline." ) )
			} else {
				List( shown, selection: $window.logSelection ) { entry in
					LogRow( entry: entry ) { copy( [ entry.id ] ) }
						// No lines between entries, and only as tall as their text.
						.listRowSeparator( .hidden )
						.listRowInsets( EdgeInsets( top: 2, leading: 12, bottom: 2, trailing: 12 ) )
						// A tint of our own for the selection, which the row's colors stay readable on.
						.listRowBackground( window.logSelection.contains( entry.id ) ? Color.accentColor.opacity( 0.22 ) : Color.clear )
				}
				.listStyle( .plain )
				.environment( \.defaultMinListRowHeight, 0 )
				.contextMenu( forSelectionType: TrafficEntry.ID.self ) { ids in
					if !ids.isEmpty {
						Button( ids.count == 1 ? "Copy Entry" : "Copy \(ids.count) Entries" ) { copy( ids ) }
					}
				}
			}

			// While the deck is catching up on key images: how far it's got.
			TransferProgressFooter( device: device )
		}
		.onChange( of: Source( filter: filter, newest: device.log.last?.id, count: device.log.count ), initial: true ) { refresh() }
	}

	/// Filters the log again, and drops entries that are no longer shown from the selection.
	private func refresh() {
		shown = device.log.reversed().filter { filter.isEmpty || $0.summary.localizedStandardContains( filter ) || $0.detail.localizedStandardContains( filter ) }
		let ids = Set( shown.map( \.id ) )
		if !window.logSelection.isSubset( of: ids ) {
			window.logSelection.formIntersection( ids )
		}
	}

	/// Copies the shown entries with these IDs (all of them for nil) as text, oldest first.
	private func copy( _ ids: Set<TrafficEntry.ID>? ) {
		UIPasteboard.general.string = TrafficEntry.plainText( shown.reversed().filter { ids?.contains( $0.id ) ?? true } )
	}
}

/// A log entry's row: the time, the direction, what happened over the frame itself, and its
/// size, then a copy button at the right edge that shows while the pointer is over the row.
/// The button's space is always there, so nothing moves.
private struct LogRow: View {
	let entry : TrafficEntry
	let copy  : () -> Void

	@State private var hovering = false

	/// On the Mac the button waits for the pointer; on iPad, with nothing to hover, it stays.
	private static var hasPointer: Bool {
		#if targetEnvironment( macCatalyst )
		true
		#else
		false
		#endif
	}

	var body: some View {
		HStack( alignment: .firstTextBaseline, spacing: 10 ) {
			Text( entry.date, format: TrafficEntry.timeFormat )
				.monospacedDigit()
				.foregroundStyle( .secondary )
			Image( systemName: Self.symbol( entry.direction ) )
				.foregroundStyle( Self.color( entry.direction ) )
				.accessibilityLabel( Self.name( entry.direction ) )
			VStack( alignment: .leading, spacing: 1 ) {
				Text( entry.summary )
					.fontWeight( entry.direction == .event ? .semibold : .regular )
					.lineLimit( 2 )
				if !entry.detail.isEmpty {
					Text( entry.detail )
						.font( .caption.monospaced() )
						.foregroundStyle( .secondary )
						.lineLimit( 2 )
				}
			}
			Spacer( minLength: 8 )
			if entry.bytes > 0 {
				Text( ByteCountFormatter.string( fromByteCount: Int64( entry.bytes ), countStyle: .file ) )
					.monospacedDigit()
					.foregroundStyle( .secondary )
			}
			Button( action: copy ) {
				Image( systemName: "doc.on.doc" )
			}
			.buttonStyle( .borderless )
			.help( "Copy this entry" )
			.accessibilityLabel( "Copy entry" )
			.opacity( hovering || !Self.hasPointer ? 1 : 0 )
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
						.fill( Color.secondary.opacity( 0.5 ) )
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
				.stroke( Color.secondary.opacity( 0.25 ), lineWidth: 3 )
			Circle()
				.trim( from: 0, to: min( max( fraction, 0 ), 1 ) )
				.stroke( Color.accentColor, style: StrokeStyle( lineWidth: 3, lineCap: .round ) )
				.rotationEffect( .degrees( -90 ) )
				.animation( .easeOut( duration: 0.15 ), value: fraction )
		}
		.padding( 1.5 )   // the stroke straddles the circle's edge
	}
}
