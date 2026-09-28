//
//  PartsView.swift
//  ESPDeck Bridge
//
//  The Getting Started page, sheets like a product manual's: "What You Need" (the parts, as
//  the "in the box" page), "Putting It Together" (the parts assembled), and "Find Your
//  Device" (devices waiting to be set up, as they appear). The illustrations
//  are two-colour line drawings (ink and the app icon's amber) drawn in code, so they stay
//  sharp and follow light and dark mode.
//

import SwiftUI

struct PartsView: View {
	let controller          : DeckController
	@Binding var selection  : String?

	fileprivate enum Sheet: String, CaseIterable, Identifiable {
		case parts    = "What You Need"
		case assembly = "Putting It Together"
		case find     = "Find Your Device"

		var id: Self { self }

		var previous: Sheet? { Self.allCases.firstIndex( of: self ).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil } }
		var next: Sheet?     { Self.allCases.firstIndex( of: self ).flatMap { $0 + 1 < Self.allCases.count ? Self.allCases[$0 + 1] : nil } }
	}

	@State private var sheet = Sheet.parts

	var body: some View {
		VStack( spacing: 0 ) {
			// Outside the scroll view, so it stays put while the sheet scrolls.
			Picker( "Sheet", selection: $sheet ) {
				ForEach( Sheet.allCases ) { sheet in
					Text( sheet.rawValue ).tag( sheet )
				}
			}
			.pickerStyle( .segmented )
			.labelsHidden()
			.fixedSize()
			.padding( .vertical, 12 )

			Divider()

			ScrollView {
				VStack( alignment: .leading, spacing: 28 ) {
					page( sheet )
					pager
				}
				.padding( 28 )
				.frame( maxWidth: 900, alignment: .leading )
			}
			.id( sheet )   // each sheet starts at the top
		}
	}

	@ViewBuilder
	fileprivate func page( _ sheet: Sheet ) -> some View {
		switch sheet {
			case .parts:    parts
			case .assembly: assembly
			case .find:     FindDevicesSheet( controller: controller, selection: $selection )
		}
	}

	/// Previous and next sheet, at the end of each one.
	private var pager: some View {
		HStack {
			if let previous = sheet.previous {
				Button {
					sheet = previous
				} label: {
					Label( previous.rawValue, systemImage: "chevron.left" )
				}
			}
			Spacer()
			if let next = sheet.next {
				Button {
					sheet = next
				} label: {
					HStack( spacing: 6 ) {
						Text( next.rawValue )
						Image( systemName: "chevron.right" )
					}
				}
				.buttonStyle( .borderedProminent )
			}
		}
		.padding( .top, 8 )
	}

	private var parts: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			VStack( alignment: .leading, spacing: 6 ) {
				Text( "What You Need" )
					.font( .largeTitle.weight( .bold ) )
				Text( "Everything for one ESPDeck. The Stream Deck plugs into the ESP32-S3 dev kit, which talks to this Mac over Wi-Fi." )
					.foregroundStyle( .secondary )
			}

			LazyVGrid( columns: [ GridItem( .adaptive( minimum: 230 ), spacing: 22, alignment: .top ) ], alignment: .leading, spacing: 30 ) {
				ForEach( Part.all ) { part in
					PartCard( part: part )
				}
			}

			VStack( alignment: .leading, spacing: 8 ) {
				Text( "Also Needed" )
					.font( .headline )
				Label( "A Mac that stays on and logged in, signed in to an iCloud account that's a member of the Home.", systemImage: "desktopcomputer" )
				Label( "A 2.4 GHz Wi-Fi network that the Mac and the ESP32-S3 share.", systemImage: "wifi" )
			}
			.foregroundStyle( .secondary )
		}
	}

	private static let steps = [
		"Plug the OTG adapter into the dev kit's port labelled **USB** (not the one labelled UART or COM).",
		"Plug the Stream Deck into the OTG adapter's USB-A socket. If the deck's cable ends in USB-C, put the USB-A to USB-C adapter in between.",
		"Connect the power supply to the OTG adapter's USB-C socket with the USB-C cable. The Stream Deck lights up.",
		"Set up the dev kit's Wi-Fi (from USB Setup here, or from the setup codes on the deck). It then finds ESPDeck Bridge on this Mac, and you pair it.",
	]

	private var assembly: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			VStack( alignment: .leading, spacing: 6 ) {
				Text( "Putting It Together" )
					.font( .largeTitle.weight( .bold ) )
				Text( "The dev kit sits between the Stream Deck and the power supply, and reaches this Mac over Wi-Fi." )
					.foregroundStyle( .secondary )
			}

			PartIllustration( space: CGSize( width: 640, height: 350 ), draw: Sketch.assembly )
				.aspectRatio( 640 / 350, contentMode: .fit )
				.padding( 18 )
				.background( RoundedRectangle( cornerRadius: 14, style: .continuous ).fill( .quaternary.opacity( 0.5 ) ) )

			VStack( alignment: .leading, spacing: 12 ) {
				ForEach( Array( Self.steps.enumerated() ), id: \.offset ) { index, step in
					HStack( alignment: .firstTextBaseline, spacing: 10 ) {
						Text( "\( index + 1 )" )
							.font( .headline.monospacedDigit() )
							.foregroundStyle( PartIllustration.accent )
						Text( LocalizedStringKey( step ) )
							.fixedSize( horizontal: false, vertical: true )
					}
				}
			}
		}
	}
}

/// Devices that still need setting up: ESPDeck devices on the network waiting to be paired,
/// and (on the Mac) boards plugged in over USB that aren't one of this Mac's devices yet.
private struct FindDevicesSheet: View {
	let controller          : DeckController
	@Binding var selection  : String?

	private var usbBoards: [USBSetup.Board] {
		guard controller.usbSetup.isAvailable, controller.usbSetup.scanning else { return [] }
		let known = Set( controller.devices.compactMap { controller.settings( $0.id )?.name } )
		return controller.usbSetup.boards.filter { board in
			board.espDeck.map { !known.contains( $0.name ) } ?? true
		}
	}

	var body: some View {
		VStack( alignment: .leading, spacing: 24 ) {
			VStack( alignment: .leading, spacing: 6 ) {
				Text( "Find Your Device" )
					.font( .largeTitle.weight( .bold ) )
				Text( "Once the dev kit is on your Wi-Fi, it finds ESPDeck Bridge and shows up here to be paired. A new dev kit needs Wi-Fi first: plug it into this Mac and set it up over USB, or scan the setup codes on the deck." )
					.foregroundStyle( .secondary )
			}

			HStack( spacing: 10 ) {
				ProgressView()
					.controlSize( .small )
				Text( "Looking for ESPDeck devices…" )
					.foregroundStyle( .secondary )
			}

			if !controller.newDevices.isEmpty {
				VStack( alignment: .leading, spacing: 10 ) {
					Text( "On Your Network" )
						.font( .headline )
					ForEach( controller.newDevices ) { device in
						row( icon: "lock.shield", title: device.hello.name,
							 detail: device.reason.detail, action: device.reason.action ) {
							selection = SidebarItem.newDevice( device.client )
						}
					}
				}
			}

			if !usbBoards.isEmpty {
				VStack( alignment: .leading, spacing: 10 ) {
					Text( "Plugged In over USB" )
						.font( .headline )
					ForEach( usbBoards ) { board in
						row( icon: "cable.connector", title: board.espDeck?.name ?? board.port.title,
							 detail: board.espDeck.map { "ESPDeck \($0.version), not set up on this Mac yet" } ?? "Needs ESPDeck installed",
							 action: "Set Up…" ) {
							selection = SidebarItem.usbSetup
						}
					}
				}
			}

			if controller.newDevices.isEmpty && usbBoards.isEmpty {
				VStack( alignment: .leading, spacing: 10 ) {
					Text( "Nothing yet. Make sure the dev kit is powered, and on the same Wi-Fi network as this Mac." )
						.foregroundStyle( .secondary )
					if controller.usbSetup.isAvailable {
						Button( "Open USB Setup" ) { selection = SidebarItem.usbSetup }
					}
				}
			}
		}
	}

	private func row( icon: String, title: String, detail: String, action: String, perform: @escaping () -> Void ) -> some View {
		HStack( spacing: 12 ) {
			Image( systemName: icon )
				.font( .title2 )
				.foregroundStyle( .tint )
				.frame( width: 30 )
			VStack( alignment: .leading, spacing: 2 ) {
				Text( title )
					.font( .headline )
				Text( detail )
					.font( .callout )
					.foregroundStyle( .secondary )
			}
			Spacer()
			Button( action, action: perform )
				.buttonStyle( .borderedProminent )
		}
		.padding( 14 )
		.background( RoundedRectangle( cornerRadius: 14, style: .continuous ).fill( .quaternary.opacity( 0.5 ) ) )
	}
}

private struct PartCard: View {
	let part: Part

	var body: some View {
		VStack( alignment: .leading, spacing: 10 ) {
			PartIllustration( draw: part.draw )
				.frame( height: 150 )
				.frame( maxWidth: .infinity )
				.background( RoundedRectangle( cornerRadius: 14, style: .continuous ).fill( .quaternary.opacity( 0.5 ) ) )

			HStack( alignment: .firstTextBaseline, spacing: 8 ) {
				Text( "\( part.number )" )
					.font( .headline.monospacedDigit() )
					.foregroundStyle( PartIllustration.accent )
				Text( part.title )
					.font( .headline )
			}
			Text( LocalizedStringKey( part.detail ) )   // **bold** marks what to look for when buying
				.font( .callout )
				.foregroundStyle( .secondary )
				.fixedSize( horizontal: false, vertical: true )
			if let note = part.note {
				Text( note )
					.font( .caption.weight( .semibold ) )
					.foregroundStyle( PartIllustration.accent )
			}
		}
	}
}

// MARK: - Parts

private struct Part: Identifiable {
	let number : Int
	let title  : String
	let detail : String
	var note   : String? = nil
	let draw   : ( inout Sketch ) -> Void

	var id: Int { number }

	static let all: [Part] = [
		Part( number: 1, title: "Stream Deck",
			  detail: "Any model with keys: Mini, Original, MK.2, XL, Neo, +, Pedal, or a module.",
			  draw: Sketch.streamDeck ),
		Part( number: 2, title: "ESP32-S3 Dev Kit",
			  detail: "ESP32-S3-DevKitC-1 **N16R8** (16 MB flash, 8 MB PSRAM), or a clone of it. It has two USB-C ports: the Stream Deck uses the one labelled **USB**, not the one labelled UART (or COM on many clones).",
			  draw: Sketch.devKit ),
		Part( number: 3, title: "USB-C OTG Adapter",
			  detail: "Passive, with a USB-C plug for the dev kit, a USB-A port for the Stream Deck, and a USB-C port for power. Adapters that need USB-PD may never power the deck.",
			  draw: Sketch.otgAdapter ),
		Part( number: 4, title: "USB-A to USB-C Adapter",
			  detail: "USB-A plug to USB-C socket, labelled for **charging and data** (not charge-only).",
			  note: "Only if your Stream Deck's cable ends in USB-C",
			  draw: Sketch.aToCAdapter ),
		Part( number: 5, title: "5 V Power Supply",
			  detail: "A USB-C power supply rated 2 A or more. Through the OTG adapter, it powers both the ESP32-S3 and the Stream Deck.",
			  draw: Sketch.powerSupply ),
		Part( number: 6, title: "USB-C Cable",
			  detail: "Connects the power supply to the OTG adapter. It also connects the dev kit to this Mac for installing firmware, so it must carry data; charge-only cables won't work.",
			  draw: Sketch.dataCable ),
	]
}

// MARK: - Drawing

/// Draws a sketch in its own coordinate space (200 × 140 for a part), scaled to fit and centred.
struct PartIllustration: View {
	static let accent = Sketch.accentColor

	fileprivate var space = CGSize( width: 200, height: 140 )
	fileprivate let draw: ( inout Sketch ) -> Void

	var body: some View {
		Canvas { context, size in
			let scale = min( size.width / space.width, size.height / space.height )
			context.translateBy( x: ( size.width - space.width * scale ) / 2, y: ( size.height - space.height * scale ) / 2 )
			context.scaleBy( x: scale, y: scale )
			var sketch = Sketch( context: context )
			draw( &sketch )
		}
		.accessibilityHidden( true )
	}
}

/// The two colours: ink outlines and amber highlights. Nonisolated: Canvas draws off the
/// main actor.
fileprivate nonisolated struct Sketch {
	static let accentColor = Color( red: 1, green: 0.62, blue: 0.04 )

	var context: GraphicsContext

	private let ink    = GraphicsContext.Shading.style( .primary )
	private let accent = GraphicsContext.Shading.color( Sketch.accentColor )
	private let line   = StrokeStyle( lineWidth: 2.2, lineCap: .round, lineJoin: .round )

	func stroke( _ path: Path ) { context.stroke( path, with: ink, style: line ) }
	func thin( _ path: Path )   { context.stroke( path, with: ink, style: StrokeStyle( lineWidth: 1.3, lineCap: .round, lineJoin: .round ) ) }
	func fill( _ path: Path )   { context.fill( path, with: accent ) }
	func solid( _ path: Path )  { context.fill( path, with: ink ) }
	func dot( _ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 1.6 ) { solid( Path( ellipseIn: CGRect( x: x - r, y: y - r, width: r * 2, height: r * 2 ) ) ) }

	/// Filled with the background and outlined, so it covers whatever it's drawn over.
	func opaque( _ path: Path ) {
		context.fill( path, with: .style( .background ) )
		stroke( path )
	}

	/// Filled amber with an ink outline.
	func highlight( _ path: Path ) {
		fill( path )
		stroke( path )
	}

	/// Centred on the point; "\n" starts a new, also centred, line.
	func label( _ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 9 ) {
		let lines = text.split( separator: "\n" )
		let top   = y - CGFloat( lines.count - 1 ) * size * 0.6
		for ( index, line ) in lines.enumerated() {
			context.draw( Text( line ).font( .system( size: size, weight: .semibold ) ).foregroundStyle( .secondary ), at: CGPoint( x: x, y: top + CGFloat( index ) * size * 1.2 ) )
		}
	}

	static func box( _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0 ) -> Path {
		Path( roundedRect: CGRect( x: x, y: y, width: w, height: h ), cornerRadius: r, style: .continuous )
	}

	/// This sketch with its origin moved to `point`, turned by `degrees` (0 points right,
	/// 90 down, 180 left, -90 up) and scaled.
	func placed( at point: CGPoint, degrees: Double = 0, scale: CGFloat = 1 ) -> Sketch {
		var copy = self
		copy.context.translateBy( x: point.x, y: point.y )
		copy.context.rotate( by: .degrees( degrees ) )
		copy.context.scaleBy( x: scale, y: scale )
		return copy
	}

	// MARK: Connectors
	//
	// Everything is seen from above. Plugs point right with the tip at the origin and return
	// the x where the cable joins; sockets sit on a device's edge, opening to the right, with
	// the edge at the origin (turn the sketch for other edges).

	/// USB-C plug: the flat metal shell, the moulded grip, and the strain relief. Seated in a
	/// socket, the shell is hidden and the grip starts at the origin.
	@discardableResult
	func usbCPlug( seated: Bool = false ) -> CGFloat {
		let shell: CGFloat = seated ? 0 : 10
		if !seated { highlight( Self.box( -10, -4.2, 10, 8.4, 2.5 ) ) }
		stroke( Self.box( -shell - 16, -6.5, 16, 13, 4 ) )
		stroke( Self.box( -shell - 21, -3.5, 5, 7, 2 ) )
		return -shell - 21
	}

	/// USB-A plug: the wider shell with its two latch windows, then the grip and strain relief
	/// unless it comes straight out of an adapter's body.
	/// Seated in a socket, the shell is hidden and the grip starts at the origin.
	@discardableResult
	func usbAPlug( grip: Bool = true, seated: Bool = false ) -> CGFloat {
		let shell: CGFloat = seated ? 0 : 15
		if !seated {
			highlight( Self.box( -15, -6.5, 15, 13, 1 ) )
			solid( Self.box( -10.5, -4, 4, 2.5, 0.5 ) )
			solid( Self.box( -10.5, 1.5, 4, 2.5, 0.5 ) )
		}
		guard grip else { return -shell }
		stroke( Self.box( -shell - 16, -8, 16, 16, 4 ) )
		stroke( Self.box( -shell - 21, -3.5, 5, 7, 2 ) )
		return -shell - 21
	}

	/// USB-C socket: its shell, just proud of the edge. Unaccented, it's filled with the
	/// background so the edge behind it doesn't show through.
	func usbCSocket( accented: Bool = true ) {
		let shell = Self.box( -7, -5.5, 8.5, 11, 2.5 )
		if accented {
			highlight( shell )
		} else {
			opaque( shell )
		}
	}

	/// USB-A socket: the deeper, wider shell, flush with the edge.
	func usbASocket() {
		highlight( Self.box( -15, -6.5, 15.5, 13, 1 ) )
	}

	// MARK: Parts

	static func streamDeck( _ s: inout Sketch ) {
		deckBody( s )

		// Its cable, out of the back and round to a USB-A plug.
		let scale: CGFloat = 0.62
		let end = s.placed( at: CGPoint( x: 196, y: 12 ), scale: scale ).usbAPlug()
		var cable = Path()
		cable.move( to: CGPoint( x: 150, y: 30 ) )
		cable.addCurve( to: CGPoint( x: 196 + end * scale, y: 12 ), control1: CGPoint( x: 150, y: 14 ), control2: CGPoint( x: 158, y: 12 ) )
		s.stroke( cable )
	}

	/// Body, the recessed faceplate, and 15 keys (5 × 3) set close together, in (22, 30)–(178, 126).
	static func deckBody( _ s: Sketch ) {
		s.stroke( box( 22, 30, 156, 96, 14 ) )
		s.thin( box( 28, 36, 144, 84, 9 ) )
		let key: CGFloat = 22, gap: CGFloat = 5.5
		let x0 = 22 + ( 156 - ( key * 5 + gap * 4 ) ) / 2, y0 = 30 + ( 96 - ( key * 3 + gap * 2 ) ) / 2
		for row in 0..<3 {
			for col in 0..<5 {
				let keyPath = box( x0 + CGFloat( col ) * ( key + gap ), y0 + CGFloat( row ) * ( key + gap ), key, key, 4.5 )
				if row == 1 && col == 2 { s.highlight( keyPath ) } else { s.stroke( keyPath ) }
			}
		}
	}

	static func devKit( _ s: inout Sketch ) {
		s.stroke( box( 16, 36, 172, 70, 4 ) )

		// Pin headers along both long edges.
		for x in stride( from: 44 as CGFloat, through: 180, by: 7 ) {
			s.dot( x, 42 )
			s.dot( x, 100 )
		}

		// The two USB-C sockets on the left edge; USB is the one that matters.
		s.placed( at: CGPoint( x: 16, y: 56 ), degrees: 180, scale: 1.3 ).usbCSocket()
		s.placed( at: CGPoint( x: 16, y: 86 ), degrees: 180, scale: 1.3 ).usbCSocket( accented: false )
		s.label( "USB", 42, 56 )
		s.label( "UART/COM", 54, 86, size: 8.5 )

		// BOOT and RST buttons.
		s.stroke( box( 88, 58, 12, 9, 2 ) )
		s.stroke( box( 88, 72, 12, 9, 2 ) )

		// The module: shielding can and antenna.
		s.stroke( box( 112, 50, 68, 42, 3 ) )
		s.stroke( box( 116, 54, 44, 34, 2 ) )
		var antenna = Path()
		antenna.move( to: CGPoint( x: 165, y: 58 ) )
		for step in 0..<5 {
			let y = 58 + CGFloat( step ) * 6
			antenna.addLine( to: CGPoint( x: step.isMultiple( of: 2 ) ? 176 : 165, y: y + 3 ) )
		}
		s.thin( antenna )
		s.label( "S3", 138, 71, size: 10 )
	}

	static func otgAdapter( _ s: inout Sketch ) {
		// Body, with the USB-C plug for the dev kit on a short lead to the left.
		s.stroke( box( 80, 48, 72, 48, 12 ) )
		let scale: CGFloat = 0.9
		let end = s.placed( at: CGPoint( x: 16, y: 72 ), degrees: 180, scale: scale ).usbCPlug()
		var lead = Path()
		lead.move( to: CGPoint( x: 16 - end * scale, y: 72 ) )
		lead.addLine( to: CGPoint( x: 80, y: 72 ) )
		s.stroke( lead )
		s.label( "USB-C plug\n(dev kit)", 36, 98 )

		// USB-A socket for the Stream Deck in the right edge, USB-C for power in the top edge.
		s.placed( at: CGPoint( x: 152, y: 72 ) ).usbASocket()
		s.label( "USB-A socket\n(Stream Deck)", 160, 114 )
		s.placed( at: CGPoint( x: 116, y: 48 ), degrees: -90, scale: 1.2 ).usbCSocket()

		var bolt = Path()
		bolt.move( to: CGPoint( x: 120, y: 8 ) )
		bolt.addLine( to: CGPoint( x: 111, y: 22 ) )
		bolt.addLine( to: CGPoint( x: 118, y: 22 ) )
		bolt.addLine( to: CGPoint( x: 113, y: 34 ) )
		bolt.addLine( to: CGPoint( x: 125, y: 18 ) )
		bolt.addLine( to: CGPoint( x: 118, y: 18 ) )
		bolt.closeSubpath()
		s.highlight( bolt )
		s.label( "USB-C socket\n(power)", 162, 26 )
	}

	static func aToCAdapter( _ s: inout Sketch ) {
		// USB-A plug out of the left of the body, USB-C socket in its right end.
		let scale: CGFloat = 1.4
		let body = 52 - s.placed( at: CGPoint( x: 52, y: 70 ), degrees: 180, scale: scale ).usbAPlug( grip: false ) * scale
		s.stroke( box( body, 54, 42, 32, 9 ) )
		s.placed( at: CGPoint( x: body + 42, y: 70 ), scale: 1.3 ).usbCSocket()

		s.label( "USB-A\nplug", 66, 106 )
		s.label( "USB-C\nsocket", body + 42, 106 )
	}

	static func powerSupply( _ s: inout Sketch ) {
		// The brick, its wall prongs (over its edge), and its USB-C socket in the bottom edge.
		s.stroke( box( 66, 30, 68, 76, 12 ) )
		s.opaque( box( 86, 16, 6, 18, 1 ) )
		s.opaque( box( 108, 16, 6, 18, 1 ) )
		s.label( "5V ⎓ 2A", 100, 62, size: 10 )
		s.placed( at: CGPoint( x: 100, y: 106 ), degrees: 90, scale: 1.2 ).usbCSocket()
		s.label( "USB-C socket", 100, 124 )
	}

	static func dataCable( _ s: inout Sketch ) {
		// A loose coil between two USB-C plugs.
		for ( index, offset ) in [ -12 as CGFloat, 0, 12 ].enumerated() {
			s.stroke( Path( ellipseIn: CGRect( x: 66 + offset, y: 44 + CGFloat( index ) * 4, width: 68, height: 44 ) ) )
		}
		let scale: CGFloat = 0.9
		let left  = s.placed( at: CGPoint( x: 8, y: 72 ), degrees: 180, scale: scale ).usbCPlug()
		let right = s.placed( at: CGPoint( x: 192, y: 72 ), scale: scale ).usbCPlug()
		var leads = Path()
		leads.move( to: CGPoint( x: 8 - left * scale, y: 72 ) )
		leads.addLine( to: CGPoint( x: 56, y: 72 ) )
		leads.move( to: CGPoint( x: 145, y: 72 ) )
		leads.addLine( to: CGPoint( x: 192 + right * scale, y: 72 ) )
		s.stroke( leads )
		s.label( "USB-C", 100, 116 )
	}

	// MARK: Assembly

	/// Everything connected, in a 640 × 350 space.
	static func assembly( _ s: inout Sketch ) {
		// The dev kit on the right; its USB socket lands at (406, 166).
		var kit = s.placed( at: CGPoint( x: 390, y: 110 ) )
		devKit( &kit )
		s.label( "ESP32-S3 dev kit", 492, 134 )

		// The OTG adapter: its lead seated in the dev kit's USB port, USB-A socket on the left,
		// USB-C socket for power on top. Plugs are seated, so only the cables show.
		s.stroke( box( 286, 142, 64, 48, 12 ) )
		let plugScale: CGFloat = 0.9
		let plugEnd = s.placed( at: CGPoint( x: 404, y: 166 ), scale: plugScale ).usbCPlug( seated: true )
		var lead = Path()
		lead.move( to: CGPoint( x: 404 + plugEnd * plugScale, y: 166 ) )
		lead.addLine( to: CGPoint( x: 350, y: 166 ) )
		s.stroke( lead )
		s.placed( at: CGPoint( x: 286, y: 166 ), degrees: 180 ).usbASocket()
		s.placed( at: CGPoint( x: 318, y: 142 ), degrees: -90, scale: 1.2 ).usbCSocket()
		s.label( "OTG adapter", 318, 206 )

		// The power supply, top left, cabled down into the adapter's USB-C socket.
		s.stroke( box( 178, 34, 64, 64, 12 ) )
		s.opaque( box( 196, 22, 5, 16, 1 ) )
		s.opaque( box( 216, 22, 5, 16, 1 ) )
		s.label( "5V ⎓ 2A", 210, 60, size: 10 )
		s.placed( at: CGPoint( x: 210, y: 98 ), degrees: 90, scale: 1.2 ).usbCSocket()
		s.label( "Power supply", 120, 66 )

		let cableScale: CGFloat = 0.9
		let top    = s.placed( at: CGPoint( x: 210, y: 100 ), degrees: -90, scale: cableScale ).usbCPlug( seated: true )
		let bottom = s.placed( at: CGPoint( x: 318, y: 140 ), degrees: 90, scale: cableScale ).usbCPlug( seated: true )
		var power = Path()
		power.move( to: CGPoint( x: 210, y: 100 - top * cableScale ) )
		power.addCurve( to: CGPoint( x: 318, y: 140 + bottom * cableScale ), control1: CGPoint( x: 210, y: 150 ), control2: CGPoint( x: 318, y: 80 ) )
		s.stroke( power )
		s.label( "USB-C cable", 282, 84 )

		// The Stream Deck, bottom left, its cable into the adapter's USB-A socket.
		let deckScale: CGFloat = 0.85
		deckBody( s.placed( at: CGPoint( x: -8, y: 150 ), scale: deckScale ) )
		s.label( "Stream Deck", 66, 272 )
		let aScale: CGFloat = 0.75
		let aEnd = s.placed( at: CGPoint( x: 285, y: 166 ), scale: aScale ).usbAPlug( seated: true )
		var deckCable = Path()
		deckCable.move( to: CGPoint( x: 120, y: 175 ) )
		deckCable.addCurve( to: CGPoint( x: 285 + aEnd * aScale, y: 166 ), control1: CGPoint( x: 120, y: 150 ), control2: CGPoint( x: 220, y: 166 ) )
		s.stroke( deckCable )

		// Straight down from the plug's grip to the note, which is centred under it.
		let grip = 285 - 8 * aScale
		var leader = Path()
		leader.move( to: CGPoint( x: grip, y: 180 ) )
		leader.addLine( to: CGPoint( x: grip, y: 272 ) )
		s.context.stroke( leader, with: .style( .secondary ), style: StrokeStyle( lineWidth: 1, dash: [ 3, 3 ] ) )
		s.label( "If the deck's cable is USB-C,\nthe USB-A to USB-C adapter goes here", grip, 286, size: 8.5 )

		// Wi-Fi from the dev kit to the Mac.
		for radius in [ 7 as CGFloat, 13, 19 ] {
			var arc = Path()
			arc.addArc( center: CGPoint( x: 495, y: 252 ), radius: radius, startAngle: .degrees( -135 ), endAngle: .degrees( -45 ), clockwise: false )
			s.context.stroke( arc, with: .color( accentColor ), style: StrokeStyle( lineWidth: 2.6, lineCap: .round ) )
		}
		s.context.fill( Path( ellipseIn: CGRect( x: 492, y: 249, width: 6, height: 6 ) ), with: .color( accentColor ) )

		// The Mac running ESPDeck Bridge.
		// A MacBook: thin-bezelled lid, and a flat base with the opening notch.
		s.stroke( UnevenRoundedRectangle( topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous ).path( in: CGRect( x: 452, y: 262, width: 86, height: 56 ) ) )
		s.thin( UnevenRoundedRectangle( topLeadingRadius: 2, topTrailingRadius: 2, style: .continuous ).path( in: CGRect( x: 457, y: 267, width: 76, height: 46 ) ) )
		s.stroke( box( 440, 318, 110, 7, 2.5 ) )
		// The recess for opening the lid: square along the top, rounded at the bottom.
		s.thin( UnevenRoundedRectangle( bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5, style: .continuous ).path( in: CGRect( x: 483, y: 318, width: 24, height: 3.5 ) ) )
		s.label( "ESPDeck\nBridge", 495, 290 )
		s.label( "Mac", 495, 340 )
	}
}
