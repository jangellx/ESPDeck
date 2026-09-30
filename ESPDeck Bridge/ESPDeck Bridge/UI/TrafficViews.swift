//
//  TrafficViews.swift
//  ESPDeck Bridge
//
//  The Log tab (every frame to and from a device, timestamped), and the transfer status
//  under the simulated deck.
//

import SwiftUI

/// The Log page: a device's traffic, newest first, with a filter, Copy and Clear.
struct TrafficLogView: View {
	let device: DeckDevice

	@State private var filter = ""

	private static let time: Date.FormatStyle = .dateTime.hour( .twoDigits( amPM: .omitted ) ).minute( .twoDigits ).second( .twoDigits ).secondFraction( .fractional( 3 ) )

	var body: some View {
		let entries = device.log.reversed().filter { filter.isEmpty || $0.summary.localizedStandardContains( filter ) || $0.detail.localizedStandardContains( filter ) }

		VStack( spacing: 0 ) {
			HStack {
				TextField( "Filter", text: $filter, prompt: Text( "Filter (e.g. pressed, image, keyDown)" ) )
					.textFieldStyle( .roundedBorder )
					.frame( maxWidth: 320 )
				Spacer()
				Text( "\(device.log.count) entries" )
					.secondaryCaption()
				Button( "Copy" ) { UIPasteboard.general.string = text( entries ) }
					.disabled( entries.isEmpty )
				Button( "Clear" ) { device.log.removeAll() }
					.disabled( device.log.isEmpty )
			}
			.padding( 12 )

			Divider()

			if entries.isEmpty {
				ContentUnavailableView( "No Traffic", systemImage: "arrow.up.arrow.down",
										description: Text( device.isOnline ? "Messages to and from this device appear here." : "The device is offline." ) )
			} else {
				List( entries ) { entry in
					HStack( alignment: .firstTextBaseline, spacing: 10 ) {
						Text( entry.date, format: Self.time )
							.monospacedDigit()
							.foregroundStyle( .secondary )
						Image( systemName: Self.symbol( entry.direction ) )
							.foregroundStyle( Self.color( entry.direction ) )
							.accessibilityLabel( Self.name( entry.direction ) )
						VStack( alignment: .leading, spacing: 2 ) {
							Text( entry.summary )
								.lineLimit( 2 )
								.fontWeight( entry.direction == .event ? .semibold : .regular )
							if !entry.detail.isEmpty {
								Text( entry.detail )
									.font( .caption.monospaced() )
									.foregroundStyle( .secondary )
									.lineLimit( 2 )
							}
						}
						.textSelection( .enabled )
						Spacer( minLength: 8 )
						if entry.bytes > 0 {
							Text( ByteCountFormatter.string( fromByteCount: Int64( entry.bytes ), countStyle: .file ) )
								.monospacedDigit()
								.foregroundStyle( .secondary )
						}
					}
					.font( .callout )
				}
				.listStyle( .plain )
			}
		}
	}

	/// The entries as plain text, oldest first, for Copy.
	private func text( _ entries: [TrafficEntry] ) -> String {
		entries.reversed().map { entry in
			let arrow = entry.direction == .sent ? "→" : entry.direction == .received ? "←" : "•"
			let detail = [ entry.detail, entry.bytes > 0 ? "(\(entry.bytes) B)" : "" ].filter { !$0.isEmpty }.joined( separator: "  " )
			return "\(entry.date.formatted( Self.time ))  \(arrow)  \(entry.summary)" + ( detail.isEmpty ? "" : "\n                 \(detail)" )
		}.joined( separator: "\n" )
	}

	/// Each direction's symbol.
	private static func symbol( _ direction: TrafficEntry.Direction ) -> String {
		switch direction {
			case .sent:     "arrow.up.circle.fill"
			case .received: "arrow.down.circle.fill"
			case .event:    "bolt.circle.fill"
		}
	}

	/// Each direction's colour.
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

/// Under the simulated deck: how far the physical deck is through its updates. Nothing once
/// it's caught up (the sidebar and the Log page already say so).
struct TransferStatusView: View {
	let device: DeckDevice

	var body: some View {
		VStack( alignment: .leading, spacing: 6 ) {
			if !device.isOnline {
				Label( "Offline", systemImage: "wifi.slash" )
					.foregroundStyle( .secondary )
			} else if !device.pendingShows.isEmpty {
				let total = max( device.batchTotal, device.pendingShows.count )
				let done  = total - device.pendingShows.count
				ProgressView( value: Double( done ), total: Double( total ) ) {
					Text( "Updating the deck: \(done) of \(total) \(total == 1 ? "key" : "keys")" )
				} currentValueLabel: {
					if let last = device.log.last {
						Text( "\(last.direction == .sent ? "↑" : last.direction == .received ? "↓" : "•") \(last.summary)" )
							.lineLimit( 1 )
					}
				}
			}
		}
		.font( .caption )
		.frame( maxWidth: .infinity, alignment: .leading )
	}
}
