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

	/// Decks needing unpairing whose keys and settings were asked for anyway.
	@State private var showingStuckDevice: Set<String> = []

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
				if let stuck = controller.stuckConnection( for: id ), controller.device( id )?.isOnline != true, !showingStuckDevice.contains( id ) {
					NeedsUnpairingView( controller: controller, deviceID: id, stuck: stuck ) { showingStuckDevice.insert( id ) }
						.id( id )
				} else if controller.stuckConnection( for: id ) != nil, controller.device( id )?.isOnline != true {
					// Its keys and settings, asked for from the unpairing page: a way back to it.
					VStack( spacing: 0 ) {
						HStack {
							Label( "Needs unpairing on the deck first", systemImage: "exclamationmark.circle.fill" )
								.foregroundStyle( .red )
							Spacer()
							Button( "How to Unpair…" ) { showingStuckDevice.remove( id ) }
						}
						.padding( .horizontal, 16 )
						.padding( .vertical, 8 )
						Divider()
						DeviceDetailView( controller: controller, deviceID: id )
					}
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
						  ? "Plug a Stream Deck into an ESPDeck and power it up. A new device shows QR codes on its keys: scan them to join its Wi-Fi network and set it up. It appears here once it's on your network.\n\nNo deck yet? Add a demo deck to lay out keys now and copy them to a real device later."
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
			Text( "This Mac forgets every device's pairing, the devices and their key layouts, icons, triggers and commands, and the developer password, and starts over as a new bridge. Your decks then need unpairing on their setup pages before they can pair again. To keep them working on another Mac instead, export the bridge first." )
		}
		.sheet( item: Bindable( window ).bridgeTransfer ) { sheet in
			switch sheet {
				case .export: ExportBridgeSheet( controller: controller )
				case .import: ImportBridgeSheet( controller: controller )
			}
		}
		.onAppear {
			window.isShowing = true
			if window.selection == nil { window.selection = controller.devices.first?.id }
		}
		.onDisappear { window.isShowing = false }
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
		.onChange( of: controller.devices.map( \.id ) ) { old, new in
			// Follow a device that just finished pairing.
			let current = window.selection
			if let added = new.first( where: { !old.contains( $0 ) } ), current?.hasPrefix( SidebarItem.newPrefix ) == true {
				window.selection = added
			} else if current == nil || ( controller.device( current ?? "" ) == nil && !( current ?? "" ).contains( ":" ) ) {
				window.selection = controller.devices.first?.id
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

	/// Connected decks, and demo decks (never connected, always usable).
	private var connectedDevices: [DeckDevice] {
		controller.devices.filter { $0.isOnline || controller.settings( $0.id )?.isDemo == true }
	}

	/// Real decks that aren't connected, listed under Not Connected.
	private var notConnectedDevices: [DeckDevice] {
		controller.devices.filter { !$0.isOnline && controller.settings( $0.id )?.isDemo != true }
	}

	/// The selection, ignoring the list's own changes while held (holdSelectionUntil).
	private var listSelection: Binding<String?> {
		Binding { selection } set: { item in
			guard Date() >= holdSelectionUntil else { return }
			selection = item
		}
	}

	var body: some View {
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
								.foregroundStyle( .tint )
						}
						.tag( SidebarItem.newDevice( device.client ) )
					}
				} header: {
					SectionHeader( "New Devices", sidebar: true )
				}
			}

			Section {
				if connectedDevices.isEmpty {
					Text( controller.devices.isEmpty ? "No devices yet" : "None connected" )
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
				Section( isExpanded: $showNotConnected ) {
					ForEach( away ) { device in
						deviceRow( device )
					}
				} header: {
					HStack {
						SectionHeader( "Not Connected", sidebar: true )
						Spacer()
						Text( "\(away.count)" )
							.font( .subheadline )
							.foregroundStyle( Color.secondary )
							.textCase( nil )
					}
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
								Text( "\(count)" )
									.font( .caption.weight( .bold ).monospacedDigit() )
									.foregroundStyle( .white )
									.frame( minWidth: 18, minHeight: 18 )
									.padding( .horizontal, count > 9 ? 3 : 0 )
									.background( Capsule().fill( Color.accentColor ) )
									.help( count == 1 ? "1 board found; looking for more" : "\(count) boards found; looking for more" )
									.accessibilityLabel( count == 1 ? "1 board plugged in" : "\(count) boards plugged in" )
							} else if controller.usbSetup.scanning {
								Spacer()
								Image( systemName: "magnifyingglass.circle" )
									.foregroundStyle( .tint )
									.help( "Looking for boards plugged in over USB" )
									.accessibilityLabel( "Looking for boards" )
							}
						}
					} icon: {
						Image( systemName: "cable.connector" )
					}
					.tag( SidebarItem.usbSetup )
				}

				Label {
					HStack {
						Text( "Updates" )
						if !controller.updates.statusItems.isEmpty {
							Spacer()
							Circle().fill( Color.accentColor ).frame( width: 8, height: 8 )
						}
					}
				} icon: {
					Image( systemName: "arrow.down.circle" )
				}
				.tag( SidebarItem.updates )

				Label( "About", systemImage: "info.circle" )
					.tag( SidebarItem.about )
			} header: {
				SectionHeader( "ESPDeck Bridge", sidebar: true )
			}

			Section {
				ForEach( [ controller.serverStatus, controller.homeStatus ].compactMap { $0 }, id: \.self ) { item in
					Label {
						Text( item.text )
					} icon: {
						StatusIndicator( level: item.level )
					}
				}
				if controller.macBridge != nil {
					LaunchAtLoginRow( controller: controller )
				}
				if let error = controller.lastError {
					WarningLabel( error )
						.font( .caption )
				}
				if let file = controller.config.unreadableSettings {
					WarningLabel( "The settings couldn't be read, so ESPDeck Bridge started over. The old file is kept as \(file) in its Application Support folder." )
						.font( .caption )
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
					}
					if controller.updates.firmwareUpdateAvailable( for: device ), let latest = controller.updates.latestFirmware {
						Button {
							holdSelectionUntil = Date( timeIntervalSinceNow: 0.5 )
							selection          = SidebarItem.updates
						} label: {
							Image( systemName: "arrow.up.circle.fill" )
								.foregroundStyle( .tint )
						}
						.buttonStyle( .borderless )
						.help( "Firmware \(latest.version.description) is available. Click to open Updates." )
						.accessibilityLabel( "Firmware update available" )
					}
				}
				// Firmware, then the state.
				Text( device.firmware.map { "\($0) · \(status.stateText)" } ?? status.stateText )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
		} icon: {
			StatusIndicator( level: status.level )
		}
		.tag( device.id )
	}
}

/// A checkmark row that turns Launch at Login on and off, orange while it's off, with
/// an explanation in a popover.
private struct LaunchAtLoginRow: View {
	let controller : DeckController

	var body: some View {
		let state = controller.launchAtLogin
		HStack {
			Button {
				controller.setLaunchAtLogin( state != .on )
			} label: {
				Label {
					Text( state == .needsApproval ? "Launch at Login (needs approval)" : "Launch at Login" )
				} icon: {
					Image( systemName: state == .on ? "checkmark.circle.fill" : "circle" )
				}
				.foregroundStyle( state == .on ? AnyShapeStyle( .primary ) : AnyShapeStyle( .orange ) )
			}
			.buttonStyle( .plain )

			Spacer()

			InfoButton( help: "About Launch at Login",
						text: "ESPDeck Bridge is what connects your decks to HomeKit. If it isn't running, the keys can't control anything and the decks show Connecting. Launching at login keeps it running after a restart." )
		}
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

			switch page {
				case .keys:
					KeysPageView( controller: controller, deviceID: deviceID, selection: keyBinding )
				case .device:
					DeviceSettingsView( controller: controller, deviceID: deviceID )
				case .log:
					if let device = controller.device( deviceID ) {
						TrafficLogView( device: device )
					}
			}
		}
		.navigationTitle( controller.settings( deviceID )?.name ?? "ESPDeck" )
		.onAppear { updateFocus() }
		.onChange( of: selectedKey ) { updateFocus() }
		.onChange( of: page ) { updateFocus() }
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
	/// Under the device's name in the sidebar.
	var status: String {
		switch self {
			case .unpaired:                     "waiting to be paired"
			case .oldFirmware:                  "needs a firmware update"
			case .pairedElsewhere, .keyMissing: "needs unpairing on the deck first"
		}
	}

	/// In Find Your Device.
	var detail: String {
		switch self {
			case .unpaired:                     "Waiting to be paired"
			case .oldFirmware:                  "Needs a firmware update before it can be paired"
			case .pairedElsewhere, .keyMissing: "Needs unpairing on the deck first"
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
