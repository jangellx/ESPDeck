//
//  PartsView.swift
//  ESPDeck Bridge
//
//  The Getting Started page, sheets like a product manual's: "What You Need" (the parts, as
//  the "in the box" page, and how the dev kit will be set up), "Connect to This Mac" (for
//  setting it up over USB), "Putting It Together" (the parts assembled), "Set Up over
//  Wi-Fi" (the setup codes on the deck, for setting it up from a phone), and "Find Your
//  Device" (devices waiting to be set up, as they appear). The switcher and pager follow
//  the chosen way of setting up. The illustrations are two-color line drawings (ink and
//  the app icon's amber) drawn in code, so they stay sharp and follow light and dark mode.
//

import SwiftUI

/// Getting Started's sheets. The page shows the ones on the chosen GuidePath.
enum GuideSheet: String, CaseIterable, Identifiable {
	case parts    = "What You Need"
	case connect  = "Connect to This Mac"
	case assembly = "Putting It Together"
	case wifi     = "Set Up over Wi-Fi"
	case find     = "Find Your Device"

	var id: Self { self }
}

/// How the dev kit gets its Wi-Fi: from the setup codes on the deck, which it shows once
/// it's put together and powered, or over USB from this Mac (Mac only), which comes before
/// putting it together.
enum GuidePath {
	case wifi
	case usb

	/// The sheets on this path, in order.
	var sheets: [GuideSheet] {
		switch self {
			case .wifi: [ .parts, .assembly, .wifi, .find ]
			case .usb:  [ .parts, .connect, .assembly, .find ]
		}
	}
}

/// The Getting Started page: a switcher over the chosen path's sheets, and the sheet.
struct PartsView: View {
	let controller          : DeckController
	@Binding var selection  : String?

	private var window: WindowState { controller.window }

	/// The chosen path; USB where it's available until one is chosen, and only Wi-Fi without it.
	private var path: GuidePath {
		controller.usbSetup.isAvailable ? window.guidePath ?? .usb : .wifi
	}

	/// The sheet asked for, or the first one when it isn't on this path.
	private var sheet: GuideSheet {
		path.sheets.contains( window.guideSheet ) ? window.guideSheet : .parts
	}

	/// The switcher's sheet; choosing one sets the window's.
	private var sheetBinding: Binding<GuideSheet> {
		Binding { sheet } set: { controller.window.guideSheet = $0 }
	}

	/// After USB Setup, here and at the end of USB Setup.
	static let unplugStep = GuideStep( title: "Unplug the board and put it together.",
									   detail: "When USB Setup says the dev kit has joined your network, unplug it from this Mac and connect it to the Stream Deck and power." )

	var body: some View {
		VStack( spacing: 0 ) {
			// Outside the scroll view, so it stays put while the sheet scrolls.
			Picker( "Sheet", selection: sheetBinding ) {
				ForEach( path.sheets ) { sheet in
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
					// One sheet's content.
					switch sheet {
						case .parts:    PartsSheet( path: path, offersPathChoice: controller.usbSetup.isAvailable, window: window )
						case .connect:  ConnectSheet( selection: $selection )
						case .assembly: AssemblySheet( path: path )
						case .wifi:     WiFiSetupSheet()
						case .find:     FindDevicesSheet( controller: controller, selection: $selection )
					}
					GuidePager( sheet: sheet, path: path, window: window )
				}
				.padding( 28 )
				.frame( maxWidth: 900, alignment: .leading )
			}
			.id( sheet )   // each sheet starts at the top
		}
	}
}

/// Previous and next sheet on the chosen path, at the end of each one.
private struct GuidePager: View {
	let sheet   : GuideSheet
	let path    : GuidePath
	let window  : WindowState

	var body: some View {
		let sheets   = path.sheets
		let index    = sheets.firstIndex( of: sheet ) ?? 0
		let previous = index > 0 ? sheets[index - 1] : nil
		let next     = index + 1 < sheets.count ? sheets[index + 1] : nil
		HStack {
			if let previous {
				Button {
					window.guideSheet = previous
				} label: {
					Label( previous.rawValue, systemImage: "chevron.left" )
				}
			}
			Spacer()
			if let next {
				Button {
					window.guideSheet = next
				} label: {
					ForwardLabel( title: next.rawValue )
				}
				.prominentButtonStyle()
			}
		}
		.padding( .top, 8 )
	}
}

// MARK: - What You Need

/// What You Need: the parts, what else is needed, and the choice of path.
private struct PartsSheet: View {
	let path              : GuidePath
	/// Whether there's a choice to make: only where setting up over USB is available.
	let offersPathChoice  : Bool
	let window            : WindowState

	var body: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			SheetHeading( title: "What You Need",
						  detail: "Everything for one ESPDeck. The Stream Deck plugs into the ESP32-S3 dev kit, which talks to this Mac over Wi-Fi." )

			LazyVGrid( columns: [ GridItem( .adaptive( minimum: 230 ), spacing: 22, alignment: .top ) ], alignment: .leading, spacing: 30 ) {
				ForEach( Part.all ) { part in
					PartCard( part: part )
				}
			}

			VStack( alignment: .leading, spacing: 8 ) {
				Text( "Also Needed" )
					.font( .headline )
				Label( "A Mac that **stays on and logged in**, signed in to an iCloud account that's a **member of the Home**.", systemImage: "desktopcomputer" )
				Label( "A **2.4 GHz Wi-Fi network** that the Mac and the ESP32-S3 share.", systemImage: "wifi" )
			}
			.foregroundStyle( .secondary )

			if offersPathChoice {
				PathChoice( path: path, window: window )
			}
		}
	}
}

/// Over USB or over Wi-Fi: the rest of the sheets follow the choice.
private struct PathChoice: View {
	let path    : GuidePath
	let window  : WindowState

	var body: some View {
		VStack( alignment: .leading, spacing: 12 ) {
			Text( "How Do You Want to Set It Up?" )
				.font( .headline )
			HStack( alignment: .top, spacing: 16 ) {
				PathCard( icon: "cable.connector", title: "Set up over USB from this Mac",
						  detail: "Plug the dev kit into this Mac first. ESPDeck Bridge installs the firmware and gives it your Wi-Fi.",
						  chosen: path == .usb ) {
					window.guidePath = .usb
				}
				PathCard( icon: "qrcode", title: "Set up over Wi-Fi with the codes on the deck",
						  detail: "For a dev kit that already runs ESPDeck: scan the setup codes its keys show to join it and give it your Wi-Fi.",
						  chosen: path == .wifi ) {
					window.guidePath = .wifi
				}
			}
			.fixedSize( horizontal: false, vertical: true )   // both cards as tall as the taller one
		}
	}
}

// MARK: - Connect to This Mac

/// Connect to This Mac: plugging the dev kit in, and the way to USB Setup.
private struct ConnectSheet: View {
	@Binding var selection: String?

	/// The steps up to opening USB Setup; PartsView.unplugStep comes after them.
	private static let connectSteps = [
		GuideStep( title: "Connect the dev kit to this Mac.",
				   detail: "Use the USB-C cable, in the dev kit's port labeled **USB**. The Mac powers the dev kit; nothing else needs to be plugged in yet." ),
		GuideStep( title: "Open USB Setup.",
				   detail: "Once it finds the dev kit, install ESPDeck on it, set your Wi-Fi network, and give it a name." ),
	]

	var body: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			SheetHeading( title: "Connect to This Mac",
						  detail: "Before putting it together, plug the dev kit into this Mac to install ESPDeck and set up its Wi-Fi." )

			USBConnectionIllustration()
				.illustrationCard( USBConnectionIllustration.space )

			GuideSteps( steps: Self.connectSteps )

			// Between the step that opens USB Setup and the one after it.
			Button {
				selection = SidebarItem.usbSetup
			} label: {
				ForwardLabel( title: "Open USB Setup" )
			}
			.prominentButtonStyle()
			.frame( maxWidth: .infinity )

			GuideSteps( steps: [ PartsView.unplugStep ], first: Self.connectSteps.count + 1 )
		}
	}
}

// MARK: - Putting It Together

/// Putting It Together: the parts assembled, and the steps.
private struct AssemblySheet: View {
	let path: GuidePath

	/// The steps that are the same on both paths.
	private static let assemblySteps = [
		GuideStep( title: "Plug the OTG adapter into the dev kit.",
				   detail: "Use the port labeled **USB**, not the one labeled UART or COM." ),
		GuideStep( title: "Plug in the Stream Deck.",
				   detail: "It goes in the OTG adapter's USB-A socket. If the deck's cable ends in USB-C, put the USB-A to USB-C adapter in between." ),
		GuideStep( title: "Connect the power supply.",
				   detail: "Use the USB-C cable, into the OTG adapter's USB-C socket. The Stream Deck lights up." ),
	]

	/// Assembly's last step, which leads on to the chosen path's next sheet.
	private var lastAssemblyStep: GuideStep {
		switch path {
			case .usb:
				GuideStep( title: "Pair it with this Mac.",
						   detail: "It will join the Wi-Fi network you gave it during USB Setup and find ESPDeck Bridge on this Mac. Pair it under New Devices, then hold Confirm on the deck." )
			case .wifi:
				GuideStep( title: "Look for the setup codes.",
						   detail: "A dev kit with no Wi-Fi set up starts in setup mode, and the deck's keys show two QR codes. Set Up over Wi-Fi, next, gives it your network from a phone or tablet." )
		}
	}

	var body: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			SheetHeading( title: "Putting It Together",
						  detail: "The dev kit sits between the Stream Deck and the power supply, and reaches this Mac over Wi-Fi." )

			PartIllustration( space: Sketch.assemblySpace, draw: Sketch.assembly )
				.illustrationCard( Sketch.assemblySpace )

			GuideSteps( steps: Self.assemblySteps + [ lastAssemblyStep ] )
		}
	}
}

// MARK: - Set Up over Wi-Fi

/// Set Up over Wi-Fi: the setup codes, the steps, and what to do when they go wrong.
private struct WiFiSetupSheet: View {
	/// The steps, from joining the deck's network to finding it in ESPDeck Bridge.
	private static let wifiSteps = [
		GuideStep( title: "Join the deck's Wi-Fi network.",
				   detail: "Scan the code on the top-left key with a phone's camera, and join the network it offers. It's named **ESPDeck-XXXX**, ending in the last four characters of the deck's ID, as shown on the top-center key." ),
		GuideStep( title: "Open the setup page.",
				   detail: "Scan the code on the top-right key, or open **http://192.168.4.1** in a web browser. It often opens by itself once the phone has joined." ),
		GuideStep( title: "Choose your Wi-Fi network.",
				   detail: "Pick it on the setup page, enter its password, and tap **Save & Connect**. It needs a 2.4 GHz network, the one this Mac is on. You can name the deck there too." ),
		GuideStep( title: "Find it in ESPDeck Bridge.",
				   detail: "The deck will join your network, leave setup mode, and find ESPDeck Bridge on this Mac. It will then appear under Find Your Device and New Devices, to be paired." ),
	]

	var body: some View {
		VStack( alignment: .leading, spacing: 28 ) {
			SheetHeading( title: "Set Up over Wi-Fi",
						  detail: "Put together and powered, the dev kit shows setup codes on the deck's keys. Scan them with a phone or tablet to join the dev kit's own network and give it your Wi-Fi." )

			PartIllustration( space: Sketch.wifiSetupSpace, draw: Sketch.wifiSetup )
				.illustrationCard( Sketch.wifiSetupSpace )

			// Each tip under the step it's about.
			VStack( alignment: .leading, spacing: 16 ) {
				GuideSteps( steps: Array( Self.wifiSteps[0..<1] ) )
				GuideTip( icon: "square.grid.3x2", title: "Not Showing the Codes?",
						  detail: "A dev kit that already has Wi-Fi starts normally. To enter setup mode, hold the top-left and bottom-right keys together for 5 seconds: after 2 seconds the other keys go dark and a countdown shows. Letting go of either key cancels. A paired deck can also start setup mode from its Device page in ESPDeck Bridge." )
				GuideSteps( steps: Array( Self.wifiSteps[1..<2] ), first: 2 )
				GuideTip( icon: "wifi.exclamationmark", title: "If the Phone Leaves the Deck's Network",
						  detail: "The deck's network has no internet, so a phone may join it and then drop back to your usual Wi-Fi. If that happens, join it directly: in the phone's Wi-Fi settings, choose **ESPDeck-XXXX**, the name on the top-center key. The deck doesn't show the password; it's in the top-left code, and scanning that code saves it on the phone, so if the settings ask for it, scan the code again. The password changes each time setup mode starts (firmware 4.0 and later), so scan again after it restarts. The setup page only opens while the phone is on the deck's network." )
				GuideSteps( steps: Array( Self.wifiSteps[2...] ), first: 3 )
			}
		}
	}
}

/// Something that could go wrong, set off in amber so it's seen.
private struct GuideTip: View {
	let icon    : String
	let title   : String
	let detail  : String

	var body: some View {
		HStack( alignment: .top, spacing: 12 ) {
			Image( systemName: icon )
				.font( .title2 )
				.foregroundStyle( PartIllustration.accent )
				.scaledFrame( width: 30, relativeTo: .title2 )
			VStack( alignment: .leading, spacing: 4 ) {
				Text( title )
					.font( .headline )
				Text( LocalizedStringKey( detail ) )
					.foregroundStyle( .secondary )
					.fixedSize( horizontal: false, vertical: true )
			}
			Spacer( minLength: 0 )
		}
		.padding( 14 )
		.background( RoundedRectangle( cornerRadius: 14 ).fill( PartIllustration.accent.opacity( 0.12 ) ) )
		.overlay( RoundedRectangle( cornerRadius: 14 ).strokeBorder( PartIllustration.accent.opacity( 0.5 ), lineWidth: 1 ) )
	}
}

/// Steps numbered in amber, from `first`, each with its title over the rest.
private struct GuideSteps: View {
	let steps  : [GuideStep]
	/// The first step's number.
	var first  = 1

	var body: some View {
		VStack( alignment: .leading, spacing: 16 ) {
			ForEach( Array( steps.enumerated() ), id: \.offset ) { index, step in
				HStack( alignment: .firstTextBaseline, spacing: 10 ) {
					Text( "\( first + index )" )
						.font( .headline.monospacedDigit() )
						.foregroundStyle( PartIllustration.accent )
					GuideStepText( step: step )
				}
			}
		}
	}
}

/// A step in Getting Started, as in Apple's guides: its first sentence as a short title,
/// the rest under it. **bold** marks what to look for.
struct GuideStep {
	let title  : String
	let detail : String
}

/// A step's title, and the rest under it in the body font.
struct GuideStepText: View {
	let step: GuideStep
	/// The detail in the primary color, not gray (in a form, next to other rows).
	var primaryDetail = false

	var body: some View {
		VStack( alignment: .leading, spacing: 3 ) {
			Text( LocalizedStringKey( step.title ) )
				.font( .headline )
				.fixedSize( horizontal: false, vertical: true )
			Text( LocalizedStringKey( step.detail ) )
				.foregroundStyle( primaryDetail ? Color.primary : Color.secondary )
				.fixedSize( horizontal: false, vertical: true )
		}
	}
}

/// A sheet's title, large, with what it's about under it.
private struct SheetHeading: View {
	let title  : String
	let detail : String

	var body: some View {
		VStack( alignment: .leading, spacing: 6 ) {
			Text( title )
				.font( .largeTitle.weight( .bold ) )
			Text( detail )
				.foregroundStyle( .secondary )
		}
	}
}

/// A button's title with a chevron after it, for going on to another page or sheet.
struct ForwardLabel: View {
	let title: String

	var body: some View {
		HStack( spacing: 6 ) {
			Text( title )
			Image( systemName: "chevron.right" )
		}
	}
}

extension View {
	/// The faint rounded card the Getting Started sheets set things on.
	fileprivate func cardBackground() -> some View {
		background( RoundedRectangle( cornerRadius: 14 ).fill( .quaternary.opacity( 0.5 ) ) )
	}

	/// An illustration at the proportions of its drawing `space`, on a card.
	fileprivate func illustrationCard( _ space: CGSize ) -> some View {
		aspectRatio( space.width / space.height, contentMode: .fit )
			.padding( 18 )
			.cardBackground()
	}
}

/// One way of setting up the dev kit, chosen by clicking it.
private struct PathCard: View {
	let icon    : String
	let title   : String
	let detail  : String
	let chosen  : Bool
	let choose  : () -> Void

	var body: some View {
		Button( action: choose ) {
			HStack( alignment: .top, spacing: 12 ) {
				Image( systemName: icon )
					.font( .title2 )
					.foregroundStyle( .tint )
					.scaledFrame( width: 30, relativeTo: .title2 )
				VStack( alignment: .leading, spacing: 4 ) {
					Text( title )
						.font( .headline )
					Text( detail )
						.font( .callout )
						.foregroundStyle( .secondary )
						.fixedSize( horizontal: false, vertical: true )
				}
				Spacer( minLength: 0 )
				Image( systemName: chosen ? "checkmark.circle.fill" : "circle" )
					.font( .title3 )
					.foregroundStyle( chosen ? Color.accentColor : Color.secondary )
			}
			.padding( 14 )
			.frame( maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading )
			.cardBackground()
			.overlay( RoundedRectangle( cornerRadius: 14 ).strokeBorder( chosen ? Color.accentColor : .clear, lineWidth: 2 ) )
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.accessibilityAddTraits( chosen ? .isSelected : [] )
	}
}

/// Devices that still need setting up: ESPDeck devices on the network waiting to be paired,
/// and (on the Mac) boards plugged in over USB that aren't one of this Mac's devices yet.
private struct FindDevicesSheet: View {
	let controller          : DeckController
	@Binding var selection  : String?

	/// Leaves out boards that are already set up and on the network (USB Setup still shows
	/// them): ones this bridge knows, paired or under New Devices, and ones that say they're
	/// connected to the Wi-Fi network they're set up for.
	private var usbBoards: [USBSetup.Board] {
		guard controller.usbSetup.isAvailable, controller.usbSetup.scanning else { return [] }
		let names = Set( controller.devices.compactMap { controller.settings( $0.id )?.name } + controller.newDevices.map( \.hello.name ) )
		return controller.usbSetup.boards.filter { board in
			if let network = board.espDeck?.network, !network.ssid.isEmpty, network.connected { return false }
			// By its MAC address where the USB port gives it, by name otherwise.
			if let id = board.port.deviceID {
				return controller.device( id ) == nil && !controller.newDevices.contains { $0.hello.id == id }
			}
			return board.espDeck.map { !names.contains( $0.name ) } ?? true
		}
	}

	var body: some View {
		VStack( alignment: .leading, spacing: 24 ) {
			SheetHeading( title: "Find Your Device",
						  detail: "Once the dev kit is on your Wi-Fi, it will find ESPDeck Bridge and show up here to be paired. A new dev kit needs Wi-Fi first: plug it into this Mac and set it up over USB, or scan the setup codes on the deck." )

			// Decks on the network that aren't working with this Mac yet: new ones, and ones it
			// knows that are waiting to be paired again (after a factory reset, say) or can't be.
			let waiting = controller.newDevices

			// Only while there's nothing to show: once a deck is found, it's the answer.
			if waiting.isEmpty && usbBoards.isEmpty {
				HStack( spacing: 10 ) {
					ProgressView()
						.controlSize( .small )
					Text( "Looking for ESPDeck devices…" )
						.foregroundStyle( .secondary )
				}
			}

			if !waiting.isEmpty {
				VStack( alignment: .leading, spacing: 10 ) {
					Text( "On Your Network" )
						.font( .headline )
					ForEach( waiting ) { device in
						// A deck this Mac knows goes on from its own row in the sidebar.
						let known = controller.device( device.hello.id ) != nil
						FoundDeviceRow( icon: "lock.shield",
										title: ( known ? controller.settings( device.hello.id )?.name : nil ) ?? device.hello.name,
										detail: device.reason.detail, action: device.reason.action,
										destination: known ? device.hello.id : SidebarItem.newDevice( device.client ), selection: $selection )
					}
				}
			}

			if !usbBoards.isEmpty {
				VStack( alignment: .leading, spacing: 10 ) {
					Text( "Plugged In over USB" )
						.font( .headline )
					ForEach( usbBoards ) { board in
						FoundDeviceRow( icon: "cable.connector", title: board.espDeck?.name ?? board.port.title,
										detail: board.espDeck.map { "ESPDeck \($0.version), not set up on this Mac yet" } ?? "Needs ESPDeck installed",
										action: "Set Up…", destination: SidebarItem.usbSetup, selection: $selection )
					}
				}
			}

			if waiting.isEmpty && usbBoards.isEmpty {
				Text( "Nothing yet. Make sure the dev kit is powered, and on the same Wi-Fi network as this Mac." )
					.foregroundStyle( .secondary )
			}
		}
	}
}

/// A device or board, what it is, and the button that goes on with it.
private struct FoundDeviceRow: View {
	let icon                : String
	let title               : String
	let detail              : String
	/// The button's title.
	let action              : String
	/// The sidebar selection the button goes to.
	let destination         : String
	@Binding var selection  : String?

	var body: some View {
		HStack( spacing: 12 ) {
			Image( systemName: icon )
				.font( .title2 )
				.foregroundStyle( .tint )
				.scaledFrame( width: 30, relativeTo: .title2 )
			VStack( alignment: .leading, spacing: 2 ) {
				Text( title )
					.font( .headline )
				Text( detail )
					.font( .callout )
					.foregroundStyle( .secondary )
			}
			Spacer()
			Button( action ) {
				selection = destination
			}
			.prominentButtonStyle()
		}
		.padding( 14 )
		.cardBackground()
	}
}

/// A part's picture, number and name, what to look for, and when it's needed.
private struct PartCard: View {
	let part: Part

	var body: some View {
		VStack( alignment: .leading, spacing: 10 ) {
			PartIllustration( draw: part.draw )
				.frame( height: 150 )
				.frame( maxWidth: .infinity )
				.cardBackground()

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

/// One of the parts for an ESPDeck, and how to draw it.
private struct Part: Identifiable {
	let number : Int
	let title  : String
	let detail : String
	var note   : String? = nil
	let draw   : ( inout Sketch ) -> Void

	var id: Int { number }

	static let all: [Part] = [
		Part( number: 1, title: "Stream Deck",
			  detail: "**Any model with keys**: Mini, Original, MK.2, XL, Neo, +, Pedal, or a module.",
			  draw: Sketch.streamDeck ),
		Part( number: 2, title: "ESP32-S3 Dev Kit",
			  detail: "ESP32-S3-DevKitC-1 **N16R8** (**16 MB flash, 8 MB PSRAM**), or a clone of it. It has two USB-C ports: the Stream Deck uses the one labeled **USB**, not the one labeled UART (or COM on many clones).",
			  draw: Sketch.devKit ),
		Part( number: 3, title: "USB-C OTG Adapter",
			  detail: "**Passive**, with a USB-C plug for the dev kit, a USB-A port for the Stream Deck, and a **USB-C port for power**. Adapters that need USB-PD may never power the deck.",
			  draw: Sketch.otgAdapter ),
		Part( number: 4, title: "USB-A to USB-C Adapter",
			  detail: "USB-A plug to USB-C socket, labeled for **charging and data** (not charge-only).",
			  note: "Only if your Stream Deck's cable ends in USB-C",
			  draw: Sketch.aToCAdapter ),
		Part( number: 5, title: "5 V Power Supply",
			  detail: "A USB-C power supply **rated 2 A or more**. Through the OTG adapter, it powers both the ESP32-S3 and the Stream Deck.",
			  draw: Sketch.powerSupply ),
		Part( number: 6, title: "USB-C Cable",
			  detail: "Connects the power supply to the OTG adapter. It also connects the dev kit to this Mac for installing firmware, so it **must carry data**; charge-only cables won't work.",
			  draw: Sketch.dataCable ),
	]
}

// MARK: - Drawing

/// Draws a sketch in its own coordinate space (200 × 140 for a part), scaled to fit and centered.
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

/// A dev kit plugged into this Mac with a USB-C cable, for setting it up over USB.
struct USBConnectionIllustration: View {
	static let space = CGSize( width: 560, height: 186 )

	var body: some View {
		PartIllustration( space: Self.space, draw: Sketch.usbConnection )
	}
}

/// The two colors: ink outlines and amber highlights. Nonisolated: Canvas draws off the
/// main actor.
fileprivate nonisolated struct Sketch {
	static let accentColor = Color( red: 1, green: 0.62, blue: 0.04 )

	var context: GraphicsContext

	private let ink    = GraphicsContext.Shading.style( .primary )
	private let accent = GraphicsContext.Shading.color( Sketch.accentColor )
	private let line   = StrokeStyle( lineWidth: 2.2, lineCap: .round, lineJoin: .round )

	/// Outlined in ink, thin in ink, filled amber, filled ink, and an ink dot.
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

	/// Centered on the point; "\n" starts a new, also centered, line.
	func label( _ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 9 ) {
		let lines = text.split( separator: "\n" )
		let top   = y - CGFloat( lines.count - 1 ) * size * 0.6
		for ( index, line ) in lines.enumerated() {
			context.draw( Text( line ).font( .system( size: size, weight: .semibold ) ).foregroundStyle( .secondary ), at: CGPoint( x: x, y: top + CGFloat( index ) * size * 1.2 ) )
		}
	}

	/// A rectangle with continuous corners of radius `r`.
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

	/// A Stream Deck with its cable and USB-A plug.
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

	/// The ESP32-S3 dev kit from above, its two USB-C ports labeled.
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

	/// The OTG adapter, its plug and sockets labeled.
	static func otgAdapter( _ s: inout Sketch ) {
		// Body, with the USB-C plug for the dev kit on a short lead to the left.
		s.stroke( box( 80, 48, 72, 48, 6 ) )
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

	/// The USB-A to USB-C adapter.
	static func aToCAdapter( _ s: inout Sketch ) {
		// USB-A plug out of the left of the body, USB-C socket in its right end.
		let scale: CGFloat = 1.4
		let body = 52 - s.placed( at: CGPoint( x: 52, y: 70 ), degrees: 180, scale: scale ).usbAPlug( grip: false ) * scale
		s.stroke( box( body, 54, 42, 32, 4.5 ) )
		s.placed( at: CGPoint( x: body + 42, y: 70 ), scale: 1.3 ).usbCSocket()

		s.label( "USB-A\nplug", 66, 106 )
		s.label( "USB-C\nsocket", body + 42, 106 )
	}

	/// A 5 V USB-C power supply.
	static func powerSupply( _ s: inout Sketch ) {
		// The brick, its wall prongs (over its edge), and its USB-C socket in the bottom edge.
		s.stroke( box( 66, 30, 68, 76, 12 ) )
		s.opaque( box( 86, 16, 6, 18, 1 ) )
		s.opaque( box( 108, 16, 6, 18, 1 ) )
		s.label( "5V ⎓ 2A", 100, 62, size: 10 )
		s.placed( at: CGPoint( x: 100, y: 106 ), degrees: 90, scale: 1.2 ).usbCSocket()
		s.label( "USB-C socket", 100, 124 )
	}

	/// A coiled USB-C cable.
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

	static let assemblySpace = CGSize( width: 640, height: 350 )

	/// Everything connected, in an `assemblySpace`.
	static func assembly( _ s: inout Sketch ) {
		// The dev kit on the right; its USB socket lands at (406, 166).
		var kit = s.placed( at: CGPoint( x: 390, y: 110 ) )
		devKit( &kit )
		s.label( "ESP32-S3 dev kit", 492, 134 )

		// The OTG adapter: its lead seated in the dev kit's USB port, USB-A socket on the left,
		// USB-C socket for power on top. Plugs are seated, so only the cables show.
		s.stroke( box( 286, 142, 64, 48, 6 ) )
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

		// Straight down from the plug's grip to the note, which is centered under it.
		let grip = 285 - 8 * aScale
		var leader = Path()
		leader.move( to: CGPoint( x: grip, y: 180 ) )
		leader.addLine( to: CGPoint( x: grip, y: 272 ) )
		s.context.stroke( leader, with: .style( .secondary ), style: StrokeStyle( lineWidth: 1, dash: [ 3, 3 ] ) )
		s.label( "If the deck's cable is USB-C,\nthe USB-A to USB-C adapter goes here", grip, 286, size: 8.5 )

		// Wi-Fi from the dev kit to the Mac.
		wifiWaves( s, at: CGPoint( x: 495, y: 252 ) )

		// The Mac running ESPDeck Bridge.
		macBook( s.placed( at: CGPoint( x: 495, y: 262 ) ) )
		s.label( "Mac", 495, 340 )
	}

	/// The Wi-Fi symbol in amber: three arcs over a dot centered on `center`.
	static func wifiWaves( _ s: Sketch, at center: CGPoint ) {
		for radius in [ 7 as CGFloat, 13, 19 ] {
			var arc = Path()
			arc.addArc( center: center, radius: radius, startAngle: .degrees( -135 ), endAngle: .degrees( -45 ), clockwise: false )
			s.context.stroke( arc, with: .color( accentColor ), style: StrokeStyle( lineWidth: 2.6, lineCap: .round ) )
		}
		s.context.fill( Path( ellipseIn: CGRect( x: center.x - 3, y: center.y - 3, width: 6, height: 6 ) ), with: .color( accentColor ) )
	}

	/// A MacBook running ESPDeck Bridge: thin-bezelled lid, and a flat base with the opening
	/// notch. The origin is the top center of the lid; the base spans x ±55 at y 56–63.
	static func macBook( _ s: Sketch ) {
		s.stroke( UnevenRoundedRectangle( topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous ).path( in: CGRect( x: -43, y: 0, width: 86, height: 56 ) ) )
		s.thin( UnevenRoundedRectangle( topLeadingRadius: 2, topTrailingRadius: 2, style: .continuous ).path( in: CGRect( x: -38, y: 5, width: 76, height: 46 ) ) )
		s.stroke( box( -55, 56, 110, 7, 2.5 ) )
		// The recess for opening the lid: square along the top, rounded at the bottom.
		s.thin( UnevenRoundedRectangle( bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5, style: .continuous ).path( in: CGRect( x: -12, y: 56, width: 24, height: 3.5 ) ) )
		s.label( "ESPDeck\nBridge", 0, 28 )
	}

	// MARK: USB Connection

	/// The dev kit's USB port cabled to the side of a MacBook, in a 560 × 186 space.
	static func usbConnection( _ s: inout Sketch ) {
		// The Mac on the left, its USB-C port in the right end of the base at (macPort, portY).
		let macScale: CGFloat = 1.35
		let mac     = CGPoint( x: 136, y: 26 )
		macBook( s.placed( at: mac, scale: macScale ) )
		s.label( "Mac", mac.x, mac.y + 63 * macScale + 18 )
		let macPort = mac.x + 55 * macScale
		let portY   = mac.y + 59.5 * macScale
		s.placed( at: CGPoint( x: macPort, y: portY ), scale: 0.8 ).usbCSocket()

		// The dev kit on the right; its USB socket lands at (kitPort, kitY).
		var kit = s.placed( at: CGPoint( x: 334, y: 28 ) )
		devKit( &kit )
		s.label( "ESP32-S3 dev kit", 436, 152 )
		let kitPort: CGFloat = 334 + 16, kitY: CGFloat = 28 + 56

		// The cable, seated at both ends.
		let plugScale: CGFloat = 0.8
		let macEnd = s.placed( at: CGPoint( x: macPort + 1.5, y: portY ), degrees: 180, scale: plugScale ).usbCPlug( seated: true )
		let kitEnd = s.placed( at: CGPoint( x: kitPort - 2, y: kitY ), scale: plugScale ).usbCPlug( seated: true )
		let from   = CGPoint( x: macPort + 1.5 - macEnd * plugScale, y: portY )
		let to     = CGPoint( x: kitPort - 2 + kitEnd * plugScale, y: kitY )
		var cable  = Path()
		cable.move( to: from )
		cable.addCurve( to: to, control1: CGPoint( x: from.x + 60, y: from.y ), control2: CGPoint( x: to.x - 60, y: to.y ) )
		s.stroke( cable )
		s.label( "USB-C cable\n(data, not charge-only)", ( from.x + to.x ) / 2, portY + 38 )
	}

	// MARK: Wi-Fi Setup

	static let wifiSetupSpace = CGSize( width: 600, height: 262 )

	/// A Stream Deck Mini in setup mode, keyed as the firmware draws it, and a phone
	/// joining its network, in a `wifiSetupSpace`. Top row: the code that joins the deck's
	/// network, the network's name, and the code that opens the setup page; the bottom row
	/// says which is which, with the middle key dark (Exit setup, once it has Wi-Fi that works).
	static func wifiSetup( _ s: inout Sketch ) {
		// The deck: body, the recessed faceplate, and its 3 × 2 keys.
		s.stroke( box( 24, 22, 272, 196, 24 ) )
		s.thin( box( 32, 30, 256, 180, 17 ) )
		let key: CGFloat = 70, gap: CGFloat = 12
		let x0 = 24 + ( 272 - ( key * 3 + gap * 2 ) ) / 2, y0 = 22 + ( 196 - ( key * 2 + gap ) ) / 2
		func keyFrame( _ index: Int ) -> CGRect {
			CGRect( x: x0 + CGFloat( index % 3 ) * ( key + gap ), y: y0 + CGFloat( index / 3 ) * ( key + gap ), width: key, height: key )
		}
		for index in 0..<6 {
			let frame = keyFrame( index )
			let path  = box( frame.minX, frame.minY, key, key, 8 )
			switch index {
				case 0, 2:
					s.highlight( path )
					qrCode( s, in: frame.insetBy( dx: 7, dy: 7 ), seed: index == 0 ? 0x5EED : 0xC0DE )
				case 4:
					s.thin( path )
				default:
					s.stroke( path )
					let text = [ 1: "Wi-Fi:\nESPDeck-\nXXXX", 3: "1. Scan\nto join\nWi-Fi", 5: "2. Scan\nto open\nsetup" ][index] ?? ""
					s.label( text, frame.midX, frame.midY, size: 10.5 )
			}
		}
		s.label( "Stream Deck Mini in setup mode", 160, 246 )

		// Wi-Fi from the deck to the phone.
		wifiWaves( s, at: CGPoint( x: 364, y: 124 ) )
		s.label( "ESPDeck-XXXX", 364, 142, size: 8.5 )

		// The phone, its camera on the join code and offering the network.
		s.stroke( box( 430, 14, 112, 216, 20 ) )
		s.thin( box( 437, 21, 98, 202, 14 ) )
		s.solid( box( 472, 28, 28, 8, 4 ) )
		let finder = CGRect( x: 459, y: 62, width: 54, height: 54 )
		s.highlight( box( finder.minX + 5, finder.minY + 5, 44, 44, 5 ) )
		qrCode( s, in: finder.insetBy( dx: 9, dy: 9 ), seed: 0x5EED )
		var brackets = Path()
		for ( x, y, dx, dy ) in [ ( finder.minX, finder.minY, 1, 1 ), ( finder.maxX, finder.minY, -1, 1 ),
								  ( finder.minX, finder.maxY, 1, -1 ), ( finder.maxX, finder.maxY, -1, -1 ) ] as [( CGFloat, CGFloat, CGFloat, CGFloat )] {
			brackets.move( to: CGPoint( x: x, y: y + 10 * dy ) )
			brackets.addLine( to: CGPoint( x: x, y: y ) )
			brackets.addLine( to: CGPoint( x: x + 10 * dx, y: y ) )
		}
		s.stroke( brackets )
		s.highlight( box( 440, 146, 92, 30, 15 ) )
		s.label( "Join network\n“ESPDeck-XXXX”", 486, 161, size: 7.5 )
		s.label( "Phone", 486, 246 )
	}

	/// A QR code's look, not a real one: the three finder squares in its corners and a
	/// scatter of modules, 21 × 21 (version 1), in ink.
	static func qrCode( _ s: Sketch, in frame: CGRect, seed: UInt32 ) {
		let count  = 21
		let module = min( frame.width, frame.height ) / CGFloat( count )
		var modules = Path()
		func add( _ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1 ) {
			modules.addRect( CGRect( x: frame.minX + CGFloat( x ) * module, y: frame.minY + CGFloat( y ) * module,
									 width: CGFloat( w ) * module, height: CGFloat( h ) * module ) )
		}

		// Finder squares: a ring seven modules across round a solid three.
		for ( x, y ) in [ ( 0, 0 ), ( count - 7, 0 ), ( 0, count - 7 ) ] {
			add( x, y, 7, 1 )
			add( x, y + 6, 7, 1 )
			add( x, y + 1, 1, 5 )
			add( x + 6, y + 1, 1, 5 )
			add( x + 2, y + 2, 3, 3 )
		}

		// Everything else, clear of the finders and the gap round them, from a fixed sequence.
		var state = seed
		for y in 0..<count {
			for x in 0..<count {
				let nearFinder = ( x < 8 && y < 8 ) || ( x >= count - 8 && y < 8 ) || ( x < 8 && y >= count - 8 )
				guard !nearFinder else { continue }
				state = state &* 1_664_525 &+ 1_013_904_223
				if ( state >> 16 ) & 1 == 1 { add( x, y ) }
			}
		}
		s.solid( modules )
	}
}
