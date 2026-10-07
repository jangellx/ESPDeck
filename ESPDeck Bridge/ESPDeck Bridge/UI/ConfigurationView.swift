//
//  ConfigurationView.swift
//  ESPDeck Bridge
//
//  Devices in the sidebar; each device has a Keys page (simulated deck plus the
//  selected key's settings) and a Device page. New devices waiting to be paired, and
//  the app's Getting Started, USB Setup (Mac only), Updates and About pages, and the
//  Status section with Launch at Login, are in the sidebar too. The selection lives in
//  the controller's WindowState, which the app's menus also drive, as they do the Export
//  and Import Bridge sheets shown here.
//

import HomeKit
import SwiftUI

/// Sidebar selections that aren't device IDs.
enum SidebarItem {
	static let usbSetup  = "app:usb"
	static let updates   = "app:updates"
	static let parts     = "app:parts"
	static let about     = "app:about"
	static let newPrefix = "new:"

	/// The selection for a new device, by its connection.
	static func newDevice( _ client: ClientID ) -> String { newPrefix + client.uuidString }
}

/// The configuration window: the sidebar, and the page for what's selected in it.
struct ConfigurationView: View {
	let controller: DeckController

	/// In-app links in explanation text: "[USB Setup](espdeck:usb-setup)".
	static let linkScheme   = "espdeck"
	static let usbSetupLink = "espdeck:usb-setup"
	/// Getting Started's Set Up over Wi-Fi, which says how to start setup mode (hold two keys).
	static let setupModeLink = "espdeck:setup-mode"

	/// Decks needing unpairing whose keys and settings were asked for anyway.
	@State private var showingStuckDevice: Set<String> = []
	/// Known decks whose unauthenticated connection just went away: they usually reconnect in
	/// a moment (after unpairing, a rename, a Stream Deck plugged in), so their page waits for
	/// that rather than showing their keys in between.
	@State private var reconnecting: Set<String> = []

	/// How long a deck's page waits for it to reconnect before showing its keys.
	private static let reconnectGrace: Duration = .seconds( 10 )

	private var window: WindowState { controller.window }

	/// The window's sidebar selection, which the menus change too.
	private var selection: Binding<String?> {
		Bindable( controller.window ).selection
	}

	var body: some View {
		NavigationSplitView {
			Sidebar( controller: controller, selection: selection )
				.navigationSplitViewColumnWidth( min: 220, ideal: 250, max: 320 )
		} detail: {
			if window.selection == SidebarItem.usbSetup {
				USBSetupView( controller: controller, selection: selection )
			} else if window.selection == SidebarItem.updates {
				UpdatesView( controller: controller )
			} else if window.selection == SidebarItem.parts {
				PartsView( controller: controller, selection: selection )
			} else if window.selection == SidebarItem.about {
				AboutView( controller: controller )
			} else if let item = window.selection, item.hasPrefix( SidebarItem.newPrefix ),
					  let client = UUID( uuidString: String( item.dropFirst( SidebarItem.newPrefix.count ) ) ) {
				NewDeviceView( controller: controller, client: client )
					.id( client )
			} else if let id = window.selection, controller.device( id ) != nil {
				// Connected again but unpaired: pairing it, as for a new device.
				if let waiting = controller.waitingConnection( for: id ), controller.device( id )?.isOnline != true {
					NewDeviceView( controller: controller, client: waiting.client )
						.id( waiting.client )
				} else if let stuck = controller.stuckConnection( for: id ), controller.device( id )?.isOnline != true, !showingStuckDevice.contains( id ) {
					NeedsUnpairingView( controller: controller, deviceID: id, stuck: stuck ) { showingStuckDevice.insert( id ) }
						.id( id )
				} else if let stuck = controller.stuckConnection( for: id ), controller.device( id )?.isOnline != true {
					// Its keys and settings, asked for from the unpairing page: a way back to it.
					VStack( spacing: 0 ) {
						HStack {
							Label( stuck.reason.detail, systemImage: "exclamationmark.circle.fill" )
								.foregroundStyle( .red )
							Spacer()
							Button {
								showingStuckDevice.remove( id )
							} label: {
								ForwardLabel( title: "How to Unpair" )
							}
							.prominentButtonStyle()
						}
						.padding( .horizontal, 16 )
						.padding( .vertical, 8 )
						Divider()
						DeviceDetailView( controller: controller, deviceID: id )
					}
					.id( id )
				} else if reconnecting.contains( id ), controller.device( id )?.isOnline != true {
					ProgressView( "Waiting for the deck to reconnect…" )
						.frame( maxWidth: .infinity, maxHeight: .infinity )
						.id( id )
				} else {
					DeviceDetailView( controller: controller, deviceID: id )
						.id( id )
				}
			} else {
				ContentUnavailableView {
					Label( "No Device Selected", systemImage: "square.grid.3x2" )
				} description: {
					Text( controller.devices.isEmpty
						  ? "Plug a Stream Deck into an ESPDeck and power it up. A new device shows QR codes on its keys: scan them to join its Wi-Fi network and set it up. It will appear here once it's on your network.\n\nNo deck yet? Add a demo deck to lay out keys now and copy them to a real device later."
						  : "Choose a device in the sidebar." )
				} actions: {
					if controller.devices.isEmpty {
						AddDemoDeckMenu( controller: controller, selection: selection )
						// Setting up this Mac in place of another one.
						Button( "Import Bridge from Another Mac…" ) {
							window.bridgeTransfer = .import
						}
						.buttonStyle( .borderless )
					}
				}
			}
		}
		.confirmationDialog( "Reset Bridge?", isPresented: Bindable( window ).confirmingResetBridge, titleVisibility: .visible ) {
			Button( "Reset Bridge", role: .destructive ) { controller.removeBridge() }
			Button( "Export First…" ) { window.bridgeTransfer = .export }
		} message: {
			Text( "This Mac will forget every device's pairing, the devices and their key layouts, icons, triggers and commands, and the developer password, and start over as a new bridge. Your decks will then need unpairing on their setup pages before they can pair again. To keep them working on another Mac instead, export the bridge first." )
		}
		.sheet( item: Bindable( window ).bridgeTransfer ) { sheet in
			switch sheet {
				case .export: ExportBridgeSheet( controller: controller )
				case .import: ImportBridgeSheet( controller: controller )
			}
		}
		.onAppear {
			window.isShowing = true
			// With no decks at all, Getting Started is the place to begin.
			if window.selection == nil { window.selection = controller.devices.first?.id ?? SidebarItem.parts }
		}
		.onDisappear { window.isShowing = false }
		// In-app links in explanations, like [USB Setup](espdeck:usb-setup).
		.environment( \.openURL, OpenURLAction { url in
			guard url.scheme == Self.linkScheme else { return .systemAction }
			switch url.absoluteString {
				case Self.usbSetupLink:
					window.selection = SidebarItem.usbSetup
				case Self.setupModeLink:
					window.guidePath  = .wifi
					window.guideSheet = .wifi
					window.selection  = SidebarItem.parts
				default:
					break
			}
			return .handled
		} )
		// Choosing a deck again shows its unpairing page again.
		.onChange( of: window.selection ) { showingStuckDevice = [] }
		.onChange( of: controller.newDevices.map { "\($0.client) \($0.hello.id)" } ) { old, _ in
			// A new device that reconnected (with a new name, say) is listed again under a new
			// connection: keep it selected.
			guard let item = window.selection, item.hasPrefix( SidebarItem.newPrefix ),
				  !controller.newDevices.contains( where: { SidebarItem.newDevice( $0.client ) == item } ),
				  let entry = old.first( where: { $0.hasPrefix( item.dropFirst( SidebarItem.newPrefix.count ) ) } ),
				  let id = entry.split( separator: " " ).last,
				  let again = controller.newDevices.first( where: { $0.hello.id == id } ) else { return }
			// A known device it turned out to be shows on its own row.
			window.selection = controller.listedNewDevices.contains( where: { $0.client == again.client } ) ? SidebarItem.newDevice( again.client ) : String( id )
		}
		.onChange( of: controller.newDevices.map( \.hello.id ) ) { old, new in
			// A known deck that was waiting (to pair, or to be unpaired) and has dropped off:
			// give it a moment to come back before its page falls back to its keys.
			for id in Set( old ).subtracting( new ) where controller.device( id ).map( { !$0.isOnline } ) == true {
				reconnecting.insert( id )
				Task {
					try? await Task.sleep( for: Self.reconnectGrace )
					reconnecting.remove( id )
				}
			}
			reconnecting.subtract( new )
		}
		.onChange( of: controller.devices.map( \.id ) ) { old, new in
			// Follow a device that just finished pairing.
			let current = window.selection
			if let added = new.first( where: { !old.contains( $0 ) } ), current?.hasPrefix( SidebarItem.newPrefix ) == true {
				window.selection = added
			} else if current == nil || ( controller.device( current ?? "" ) == nil && !( current ?? "" ).contains( ":" ) ) {
				window.selection = controller.devices.first?.id ?? SidebarItem.parts   // the last deck is gone
			}
		}
	}
}

/// Devices, new devices, the app's own pages, and the bridge's status.
private struct Sidebar: View {
	let controller          : DeckController
	@Binding var selection  : String?

	/// Until then, the list's own selection changes are ignored: clicking a button in a row
	/// also selects the row, before or after the button's action.
	@State private var holdSelectionUntil = Date.distantPast
	@State private var showNotConnected   = false

	/// Connected decks, ones connected and waiting to be paired again, and demo decks (never
	/// connected, always usable).
	private var connectedDevices: [DeckDevice] {
		controller.devices.filter { $0.isOnline || controller.settings( $0.id )?.isDemo == true || controller.waitingConnection( for: $0.id ) != nil }
	}

	/// The rest, listed under Not Connected (decks needing unpairing included).
	private var notConnectedDevices: [DeckDevice] {
		let shown = Set( connectedDevices.map( \.id ) )
		return controller.devices.filter { !shown.contains( $0.id ) }
	}

	/// The selection, ignoring the list's own changes while held (holdSelectionUntil).
	private var listSelection: Binding<String?> {
		Binding { selection } set: { item in
			guard Date() >= holdSelectionUntil else { return }
			selection = item
		}
	}

	/// Shows Getting Started, where a first deck begins. Only with no decks: with any, the rows
	/// that call this aren't buttons.
	private func showGettingStarted() {
		guard controller.devices.isEmpty else { return }
		selection = SidebarItem.parts
	}

	/// The problem row's id, to scroll to it.
	fileprivate static let problemRowID = "status-problem"

	/// Whether the problem row is on screen (onOnScreenChange).
	@State private var problemShowing = false

	var body: some View {
		ScrollViewReader { proxy in
			sidebarList
				.problemBar( problemShowing ? nil : controller.lastError ) {
					withAnimation { proxy.scrollTo( Self.problemRowID, anchor: .bottom ) }
				}
				.onChange( of: controller.window.scrollToProblem, initial: true ) {
					guard controller.window.scrollToProblem else { return }
					controller.window.scrollToProblem = false
					// A window the notification just opened lays out first.
					Task {
						try? await Task.sleep( for: .milliseconds( 300 ) )
						withAnimation { proxy.scrollTo( Self.problemRowID, anchor: .bottom ) }
					}
				}
		}
	}

	/// The sidebar's sections.
	private var sidebarList: some View {
		List( selection: listSelection ) {
			if !controller.listedNewDevices.isEmpty {
				Section {
					ForEach( controller.listedNewDevices ) { device in
						Label {
							// `.secondary`, not CaptionedText's Color.secondary: it lightens on the selected row.
							VStack( alignment: .leading, spacing: 1 ) {
								Text( device.hello.name )
								Text( device.reason.status )
									.font( .caption )
									.foregroundStyle( .secondary )
							}
						} icon: {
							Image( systemName: "lock.shield" )
								.sidebarAccent()
						}
						.tag( SidebarItem.newDevice( device.client ) )
						.environment( \.sidebarRowSelected, selection == SidebarItem.newDevice( device.client ) )
					}
				} header: {
					SectionHeader( "New Devices", sidebar: true )
				}
			}

			Section {
				if controller.devices.isEmpty {
					// With no decks at all, this leads back to the first-run page.
					Button( "No devices yet", action: showGettingStarted )
						.buttonStyle( .plain )
						.foregroundStyle( .secondary )
						.help( "Show how to add a device" )
				} else if connectedDevices.isEmpty {
					Text( "None connected" )
						.foregroundStyle( .secondary )
				}
				ForEach( connectedDevices ) { device in
					deviceRow( device )
				}
			} header: {
				SectionHeader( "Devices", sidebar: true )
			}

			// Decks that aren't connected, to look at or copy from; closed at first.
			let away = notConnectedDevices
			if !away.isEmpty {
				// The system's disclosure arrow is at the far right; the count sits just left of it,
				// in line with the rows' badges and buttons (sidebarTrailingInset). The whole
				// header toggles it.
				Section( isExpanded: $showNotConnected ) {
					ForEach( away ) { device in
						deviceRow( device )
					}
				} header: {
					HStack {
						SectionHeader( "Not Connected", sidebar: true )
						Spacer()
						SidebarBadge( count: away.count, color: .orange )
					}
					.contentShape( Rectangle() )
					.onTapGesture { withAnimation { showNotConnected.toggle() } }
					.accessibilityAddTraits( .isButton )
					.accessibilityHint( showNotConnected ? "Hides the decks that aren't connected" : "Shows the decks that aren't connected" )
				}
			}

			Section {
				AddDemoDeckMenu( controller: controller, selection: $selection )
					.buttonStyle( .borderless )
			}

			Section {
				Label( "Getting Started", systemImage: "shippingbox" )
					.tag( SidebarItem.parts )

				if controller.usbSetup.isAvailable {
					Label {
						HStack {
							Text( "USB Setup" )
							// White count on blue with boards found; a blue magnifying glass while
							// looking. No animation, so it doesn't pull the eye.
							let count = controller.usbSetup.boards.count
							if count > 0 {
								Spacer()
								SidebarBadge( count: count )
									.help( count == 1 ? "1 board found; looking for more" : "\(count) boards found; looking for more" )
									.accessibilityLabel( count == 1 ? "1 board plugged in" : "\(count) boards plugged in" )
							} else if controller.usbSetup.scanning {
								Spacer()
								Image( systemName: "magnifyingglass.circle" )
									.sidebarAccent()
									.sidebarSlot()
									.help( "Looking for boards plugged in over USB" )
									.accessibilityLabel( "Looking for boards" )
							}
						}
						.sidebarTrailingInset()
					} icon: {
						Image( systemName: "cable.connector" )
					}
					.tag( SidebarItem.usbSetup )
					.environment( \.sidebarRowSelected, selection == SidebarItem.usbSetup )
				}

				Label {
					HStack {
						Text( "Updates" )
						if !controller.updates.statusItems.isEmpty {
							Spacer()
							Circle().frame( width: 8, height: 8 ).sidebarAccent().sidebarSlot()
						}
					}
					.sidebarTrailingInset()
				} icon: {
					Image( systemName: "arrow.down.circle" )
				}
				.tag( SidebarItem.updates )
				.environment( \.sidebarRowSelected, selection == SidebarItem.updates )

				Label( "About", systemImage: "info.circle" )
					.tag( SidebarItem.about )
			} header: {
				SectionHeader( "ESPDeck Bridge", sidebar: true )
			}

			Section {
				ForEach( [ controller.serverStatus, controller.homeStatus ].compactMap { $0 }, id: \.self ) { item in
					let row = Label {
						Text( item.text )
					} icon: {
						StatusIndicator( level: item.level )
					}
					// "Waiting for an ESP32-S3…" with no decks at all: back to the first-run page.
					if item.level == .waiting && controller.devices.isEmpty {
						Button( action: showGettingStarted ) { row }
							.buttonStyle( .plain )
							.help( "Show how to add a device" )
					} else {
						row
					}
				}
				if controller.macBridge != nil {
					LaunchAtLoginRow( controller: controller )
				}
				// A ForEach, so the list knows the row by its id even before it's built (it builds
				// rows as they scroll into view): the problem bar can scroll to it.
				// Over the problem itself, so each row is exactly one view (a row that may be none
				// takes the list off its fast path), under an ID that's the same for any problem.
				ForEach( controller.lastError.map { [ $0 ] } ?? [], id: \.sidebarRowID ) { problem in
					ProblemRow( problem: problem ) { controller.lastError = nil }
						.onOnScreenChange { problemShowing = $0 }
				}
				if let file = controller.config.unreadableSettings {
					ProblemRow( problem: BridgeProblem( "Settings Reset", "The settings couldn't be read, so ESPDeck Bridge started over. The old file is kept as \(file) in its Application Support folder." ) )
				}
			} header: {
				SectionHeader( "Status", sidebar: true )
			}
		}
		.listStyle( .sidebar )
	}

	/// A device's name (and an update arrow), its firmware and state, and its status indicator.
	@ViewBuilder
	private func deviceRow( _ device: DeckDevice ) -> some View {
		let status = controller.status( device: device )
		Label {
			VStack( alignment: .leading, spacing: 1 ) {
				// The update arrow and the ⓘ for a state that needs fixing on the name's line,
				// so the state under it can use the row's width.
				HStack {
					Text( controller.settings( device.id )?.name ?? device.id )
					Spacer( minLength: 4 )
					if let explanation = controller.statusExplanation( device: device ) {
						InfoButton( help: "About \(status.stateText)", text: explanation )
							.sidebarSlot()
					}
					if controller.updates.firmwareUpdateAvailable( for: device ), let latest = controller.updates.latestFirmware {
						Button {
							holdSelectionUntil = Date( timeIntervalSinceNow: 0.5 )
							selection          = SidebarItem.updates
						} label: {
							Image( systemName: "arrow.up.circle.fill" )
								.sidebarAccent()
						}
						.buttonStyle( .borderless )
						.sidebarSlot()
						.help( "Firmware \(latest.version.description) is available. Click to open Updates." )
						.accessibilityLabel( "Firmware update available" )
					}
				}
				.sidebarTrailingInset()
				// Firmware, then the state.
				// One line even when selection makes it bold: smaller, not taller.
				Text( device.firmware.map { "\($0) · \(status.stateText)" } ?? status.stateText )
					.font( .caption )
					.foregroundStyle( .secondary )
					.lineLimit( 1 )
					.minimumScaleFactor( 0.8 )
			}
		} icon: {
			StatusIndicator( level: status.level )
		}
		.tag( device.id )
		.environment( \.sidebarRowSelected, selection == device.id )
	}
}

/// Launch at Login, orange while it's off: its circle (only) turns it on and off, with an
/// explanation in a popover.
private struct LaunchAtLoginRow: View {
	let controller : DeckController

	var body: some View {
		let state = controller.launchAtLogin
		HStack {
			// Only the circle toggles it, not the whole row: turning it off should be deliberate.
			Label {
				Text( state == .needsApproval ? "Launch at Login (needs approval)" : "Launch at Login" )
			} icon: {
				Button {
					controller.setLaunchAtLogin( state != .on )
				} label: {
					Image( systemName: state == .on ? "checkmark.circle.fill" : "circle" )
						.contentShape( Circle() )
				}
				.buttonStyle( .plain )
				.help( state == .on ? "Turn off Launch at Login" : "Turn on Launch at Login" )
				.accessibilityLabel( "Launch at Login" )
				.accessibilityValue( state == .on ? "On" : "Off" )
			}
			.foregroundStyle( state == .on ? AnyShapeStyle( .primary ) : AnyShapeStyle( .orange ) )

			Spacer()

			InfoButton( help: "About Launch at Login",
						text: "ESPDeck Bridge is what connects your decks to HomeKit. If it isn't running, the keys can't control anything and the decks show Connecting. Launching at login keeps it running after a restart." )
				.sidebarSlot()
		}
		.sidebarTrailingInset()
		.onAppear { controller.refreshLaunchAtLogin() }
	}
}

/// Adds a virtual deck of a chosen model, for configuring keys without hardware.
struct AddDemoDeckMenu: View {
	let controller         : DeckController
	@Binding var selection : String?

	var body: some View {
		Menu {
			ForEach( DeckLayout.presets, id: \.model ) { layout in
				Button( "\(layout.model) (\(layout.keyCount) keys)" ) {
					selection = controller.addDemoDevice( layout: layout )
				}
			}
		} label: {
			Label( "Add Demo Deck", systemImage: "plus.rectangle.on.rectangle" )
		}
		.fixedSize()
	}
}

/// A device's Keys, Device and Log pages, under a segmented control.
private struct DeviceDetailView: View {
	let controller : DeckController
	let deviceID   : String

	// Shared with the View and Key menus.
	private var page: WindowState.Page { controller.window.page }
	private var selectedKey: Int { controller.window.selectedKey }

	private var pageBinding: Binding<WindowState.Page> { Bindable( controller.window ).page }
	private var keyBinding: Binding<Int> { Bindable( controller.window ).selectedKey }

	/// The pages opened for this device; see body.
	@State private var opened: Set<WindowState.Page> = []

	/// One page's view.
	@ViewBuilder
	private func content( of tab: WindowState.Page ) -> some View {
		switch tab {
			case .keys:
				KeysPageView( controller: controller, deviceID: deviceID, selection: keyBinding )
			case .device:
				DeviceSettingsView( controller: controller, deviceID: deviceID )
			case .log:
				if let device = controller.device( deviceID ) {
					TrafficLogView( device: device, window: controller.window, isShowing: page == .log )
				}
		}
	}

	var body: some View {
		VStack( spacing: 0 ) {
			Picker( "Page", selection: pageBinding ) {
				ForEach( WindowState.Page.allCases ) { page in
					Text( page.rawValue ).tag( page )
				}
			}
			.pickerStyle( .segmented )
			.labelsHidden()
			.frame( maxWidth: 260 )
			.padding( .vertical, 10 )

			Divider()

			// Every page opened so far stays in place, invisible while another shows, so that
			// coming back to it finds it scrolled where it was left.
			ZStack {
				ForEach( WindowState.Page.allCases ) { tab in
					if tab == page || opened.contains( tab ) {
						content( of: tab )
							.opacity( tab == page ? 1 : 0 )
							.allowsHitTesting( tab == page )
							.accessibilityHidden( tab != page )
					}
				}
			}
		}
		.navigationTitle( controller.settings( deviceID )?.name ?? "ESPDeck" )
		.onAppear { updateFocus() }
		.onChange( of: selectedKey ) { updateFocus() }
		.onChange( of: page, initial: true ) {
			opened.insert( page )
			// A text field on the page being left would otherwise keep the keyboard, unseen.
			ConfigurationHostingController.takeKeyboardFocus()
			updateFocus()
		}
		.onDisappear {
			if controller.focusedKey?.device == deviceID { controller.focusedKey = nil }
		}
		.onChange( of: controller.layout( deviceID ).keyCount ) {
			controller.window.selectedKey = min( selectedKey, controller.layout( deviceID ).keyCount - 1 )
		}
	}

	/// Copy and Paste act on the selected key while the Keys page is showing.
	private func updateFocus() {
		controller.focusedKey = page == .keys ? ( deviceID, selectedKey ) : nil
	}
}

/// Where the deck's labels go, and Copy Keys From: under the deck preview, since they apply
/// to every key on the deck.
struct LabelPositionControl: View {
	let controller : DeckController
	let deviceID   : String

	var body: some View {
		// One line where there's room, else Copy Keys From under Key Labels.
		ViewThatFits( in: .horizontal ) {
			HStack( spacing: 10 ) {
				labels
				Divider()
					.frame( height: 18 )
				copyKeys
			}
			VStack( spacing: 8 ) {
				labels
				copyKeys
			}
		}
	}

	/// Copy Keys From, at its own width.
	private var copyKeys: some View {
		CopyKeysMenu( controller: controller, deviceID: deviceID )
			.fixedSize()
	}

	/// Top or bottom labels, for every key.
	private var labels: some View {
		HStack( spacing: 10 ) {
			Text( "Labels" )
				.foregroundStyle( .secondary )
			Picker( "Labels", selection: Binding {
				controller.settings( deviceID )?.labelPosition ?? .bottom
			} set: { position in
				controller.setLabelPosition( device: deviceID, position )
			} ) {
				ForEach( LabelPosition.allCases ) { position in
					Text( position.title ).tag( position )
				}
			}
			.pickerStyle( .segmented )
			.labelsHidden()
			.fixedSize()
		}
	}
}

extension NewDevice.Reason {
	/// After USB Setup, once the deck has found this bridge.
	var foundBridge: String {
		switch self {
			case .unpaired:        "The deck found ESPDeck Bridge and is waiting to be paired."
			case .oldFirmware:     "The deck found ESPDeck Bridge, but needs a firmware update before it can be paired."
			case .pairedElsewhere: "The deck found ESPDeck Bridge, but it's paired with another Mac, so it needs to be unpaired first."
			case .keyMissing:      "The deck found ESPDeck Bridge, but this Mac lost its pairing key, so the deck needs to be unpaired first."
		}
	}

	/// Under the device's name in the sidebar.
	var status: String {
		switch self {
			case .unpaired:                     "waiting to be paired"
			case .oldFirmware:                  "needs firmware update"
			case .pairedElsewhere:              "paired with another Mac; unpair deck"
			case .keyMissing:                   "bridge lost pairing key; unpair deck"
		}
	}

	/// In Find Your Device.
	var detail: String {
		switch self {
			case .unpaired:                     "Waiting to be paired"
			case .oldFirmware:                  "Needs firmware update before it can be paired"
			case .pairedElsewhere:              "Paired with another Mac; unpair deck"
			case .keyMissing:                   "Bridge lost pairing key; unpair deck"
		}
	}

	/// What Find Your Device's button does: pairing only for a deck that accepts it.
	var action: String {
		switch self {
			case .unpaired:                     "Pair…"
			case .oldFirmware:                  "Update…"
			case .pairedElsewhere, .keyMissing: "Details…"
		}
	}
}

private extension BridgeProblem {
	/// The sidebar's problem row's ID: one row, whatever the problem.
	var sidebarRowID: String { Sidebar.problemRowID }
}
