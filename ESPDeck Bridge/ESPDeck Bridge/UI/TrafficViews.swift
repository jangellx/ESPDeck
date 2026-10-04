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
					LogRow( copy: { UIPasteboard.general.string = text( [ entry ] ) } ) {
						Text( entry.date, format: Self.time )
							.monospacedDigit()
							.foregroundStyle( .secondary )
						Image( systemName: Self.symbol( entry.direction ) )
							.foregroundStyle( Self.color( entry.direction ) )
							.accessibilityLabel( Self.name( entry.direction ) )
						// Selectable, in a text view of our own: SwiftUI's selectable Text draws a focus
						// ring around the block on the Mac that can't be turned off.
						VStack( alignment: .leading, spacing: 1 ) {
							SelectableText( entry.summary, font: Self.summaryFont( bold: entry.direction == .event ), color: .label )
							if !entry.detail.isEmpty {
								SelectableText( entry.detail, font: Self.detailFont, color: .secondaryLabel )
							}
						}
						Spacer( minLength: 8 )
						if entry.bytes > 0 {
							Text( ByteCountFormatter.string( fromByteCount: Int64( entry.bytes ), countStyle: .file ) )
								.monospacedDigit()
								.foregroundStyle( .secondary )
						}
					}
					.font( .callout )
					// No lines between entries, and only as tall as their text.
					.listRowSeparator( .hidden )
					.listRowInsets( EdgeInsets( top: 2, leading: 12, bottom: 2, trailing: 12 ) )
				}
				.listStyle( .plain )
				.environment( \.defaultMinListRowHeight, 0 )
			}

			// While the deck is catching up on key images: how far it's got.
			TransferProgressFooter( device: device )
		}
	}

	/// The summary's font: the callout size, semibold for events.
	private static func summaryFont( bold: Bool ) -> UIFont {
		let size = UIFont.preferredFont( forTextStyle: .callout ).pointSize
		return .systemFont( ofSize: size, weight: bold ? .semibold : .regular )
	}

	/// The raw message's font: caption-sized, monospaced.
	private static let detailFont = UIFont.monospacedSystemFont( ofSize: UIFont.preferredFont( forTextStyle: .caption1 ).pointSize, weight: .regular )

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

/// Text that can be selected with the mouse, up to two lines, without the focus ring the
/// Mac draws around SwiftUI's selectable Text: a read-only UITextView with no focus effect.
private struct SelectableText: UIViewRepresentable {
	let text  : String
	let font  : UIFont
	let color : UIColor

	init( _ text: String, font: UIFont, color: UIColor ) {
		self.text  = text
		self.font  = font
		self.color = color
	}

	func makeUIView( context: Context ) -> UITextView {
		let view = UITextView()
		view.isEditable      = false
		view.isSelectable    = true
		view.isScrollEnabled = false   // so it sizes to its text
		view.backgroundColor = .clear
		view.focusEffect     = nil     // no ring when a selection gives it focus
		view.textContainerInset                    = .zero
		view.textContainer.lineFragmentPadding     = 0
		view.textContainer.maximumNumberOfLines    = 2
		view.textContainer.lineBreakMode           = .byTruncatingTail
		view.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
		return view
	}

	func updateUIView( _ view: UITextView, context: Context ) {
		if view.text != text { view.text = text }
		view.font      = font
		view.textColor = color
	}

	/// As wide as its text, up to the width offered; as tall as that takes.
	func sizeThatFits( _ proposal: ProposedViewSize, uiView: UITextView, context: Context ) -> CGSize? {
		let width = proposal.width ?? .greatestFiniteMagnitude
		let size  = uiView.sizeThatFits( CGSize( width: width, height: .greatestFiniteMagnitude ) )
		return CGSize( width: min( size.width, width ), height: size.height )
	}
}

/// A log entry's row: its content, then a copy button at the right edge that shows while the
/// pointer is over the row. Its space is always there, so nothing moves.
private struct LogRow<Content: View>: View {
	let copy: () -> Void
	@ViewBuilder let content: Content

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
			content
			Button( action: copy ) {
				Image( systemName: "doc.on.doc" )
			}
			.buttonStyle( .borderless )
			.help( "Copy this entry" )
			.accessibilityLabel( "Copy entry" )
			.opacity( hovering || !Self.hasPointer ? 1 : 0 )
		}
		.contentShape( Rectangle() )
		.onHover { hovering = $0 }
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
