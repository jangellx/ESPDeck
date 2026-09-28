//
//  ConfigurationView.swift
//  ESPDeck Bridge
//
//  Devices in the sidebar; each device has a Keys page (simulated deck plus the
//  selected key's settings) and a Device page. New devices waiting to be paired, and
//  the app's USB Setup (Mac only), Updates, Hardware and About pages, and the
//  Status section with Launch at Login, are in the sidebar too. The selection lives in
//  the controller's WindowState, which the app's menus also drive.
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

	static func newDevice( _ client: ClientID ) -> String { newPrefix + client.uuidString }
}

struct ConfigurationView: View {
	let controller: DeckController

	private var window: WindowState { controller.window }

	private var selection: Binding<String?> {
		Binding { controller.window.selection } set: { controller.window.selection = $0 }
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
				PartsView()
			} else if window.selection == SidebarItem.about {
				AboutView( controller: controller )
			} else if let item = window.selection, item.hasPrefix( SidebarItem.newPrefix ),
					  let client = UUID( uuidString: String( item.dropFirst( SidebarItem.newPrefix.count ) ) ) {
				NewDeviceView( controller: controller, client: client )
					.id( client )
			} else if let id = window.selection, controller.device( id ) != nil {
				DeviceDetailView( controller: controller, deviceID: id )
					.id( id )
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
					}
				}
			}
		}
		.onAppear {
			window.isShowing = true
			if window.selection == nil { window.selection = controller.devices.first?.id }
		}
		.onDisappear { window.isShowing = false }
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

private struct Sidebar: View {
	let controller          : DeckController
	@Binding var selection  : String?

	var body: some View {
		List( selection: $selection ) {
			if !controller.newDevices.isEmpty {
				Section( "New Devices" ) {
					ForEach( controller.newDevices ) { device in
						Label {
							VStack( alignment: .leading, spacing: 1 ) {
								Text( device.hello.name )
								Text( device.reason == .oldFirmware ? "needs a firmware update" : "waiting to be paired" )
									.font( .caption )
									.foregroundStyle( .secondary )
							}
						} icon: {
							Image( systemName: "lock.shield" )
								.foregroundStyle( .tint )
						}
						.tag( SidebarItem.newDevice( device.client ) )
					}
				}
			}

			Section( "Devices" ) {
				if controller.devices.isEmpty {
					Text( "No devices yet" )
						.foregroundStyle( .secondary )
				}
				ForEach( controller.devices ) { device in
					let status = controller.status( device: device )
					Label {
						HStack {
							VStack( alignment: .leading, spacing: 1 ) {
								Text( controller.settings( device.id )?.name ?? device.id )
								Text( status.text.components( separatedBy: ": " ).last ?? "" )
									.font( .caption )
									.foregroundStyle( .secondary )
							}
							Spacer( minLength: 4 )
							if controller.updates.firmwareUpdateAvailable( for: device ), let latest = controller.updates.latestFirmware {
								Button {
									selection = SidebarItem.updates
								} label: {
									Image( systemName: "arrow.up.circle.fill" )
										.foregroundStyle( .tint )
								}
								.buttonStyle( .borderless )
								.help( "Firmware \(latest.version.description) is available. Click to open Updates." )
								.accessibilityLabel( "Firmware update available" )
							}
						}
					} icon: {
						StatusIndicator( level: status.level )
					}
					.tag( device.id )
				}
			}

			Section {
				AddDemoDeckMenu( controller: controller, selection: $selection )
					.buttonStyle( .borderless )
			}

			Section( "ESPDeck Bridge" ) {
				if controller.usbSetup.isAvailable {
					Label {
						HStack {
							Text( "USB Setup" )
							if controller.usbSetup.boardCount > 0 {
								Spacer()
								Text( "\(controller.usbSetup.boardCount)" )
									.font( .caption.weight( .semibold ).monospacedDigit() )
									.foregroundStyle( .secondary )
									.padding( .horizontal, 6 )
									.padding( .vertical, 1 )
									.background( Capsule().fill( Color.secondary.opacity( 0.18 ) ) )
									.accessibilityLabel( controller.usbSetup.boardCount == 1 ? "1 board plugged in" : "\(controller.usbSetup.boardCount) boards plugged in" )
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

				Label( "Hardware", systemImage: "shippingbox" )
					.tag( SidebarItem.parts )

				Label( "About", systemImage: "info.circle" )
					.tag( SidebarItem.about )
			}

			Section( "Status" ) {
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
					Label( error, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
						.font( .caption )
				}
			}
		}
		.listStyle( .sidebar )
	}
}

/// A checkmark row that turns Launch at Login on and off, orange while it's off, with
/// an explanation in a popover.
private struct LaunchAtLoginRow: View {
	let controller : DeckController

	@State private var explaining = false

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

			Button {
				explaining = true
			} label: {
				Image( systemName: "info.circle" )
			}
			.buttonStyle( .borderless )
			.help( "About Launch at Login" )
			.popover( isPresented: $explaining ) {
				Text( "ESPDeck Bridge is what connects your decks to HomeKit. If it isn't running, the keys can't control anything and the decks show Connecting. Launching at login keeps it running after a restart." )
					.frame( width: 280 )
					.fixedSize( horizontal: false, vertical: true )
					.padding()
			}
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

private struct DeviceDetailView: View {
	let controller : DeckController
	let deviceID   : String

	// Shared with the View and Key menus.
	private var page: WindowState.Page { controller.window.page }
	private var selectedKey: Int { controller.window.selectedKey }

	private var pageBinding: Binding<WindowState.Page> {
		Binding { controller.window.page } set: { controller.window.page = $0 }
	}

	private var keyBinding: Binding<Int> {
		Binding { controller.window.selectedKey } set: { controller.window.selectedKey = $0 }
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

			switch page {
				case .keys:
					HStack( spacing: 0 ) {
						ScrollView( [ .vertical, .horizontal ] ) {
							VStack( spacing: 14 ) {
								DeckGridView( controller: controller, deviceID: deviceID, selection: keyBinding )
								LabelPositionControl( controller: controller, deviceID: deviceID )
								if let device = controller.device( deviceID ), controller.settings( deviceID )?.isDemo != true {
									TransferStatusView( device: device )
										.frame( maxWidth: 520 )
								}
							}
							.padding( 24 )
						}
						.frame( minWidth: 380, idealWidth: 580, maxWidth: 600 )

						Divider()

						KeyInspectorView( controller: controller, deviceID: deviceID, key: selectedKey )
							.frame( minWidth: 380, maxWidth: .infinity, maxHeight: .infinity )
					}
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

/// Under the deck preview, since it applies to every key on the deck.
private struct LabelPositionControl: View {
	let controller : DeckController
	let deviceID   : String

	var body: some View {
		HStack( spacing: 10 ) {
			Text( "Key Labels" )
				.foregroundStyle( .secondary )
			Picker( "Key Labels", selection: Binding {
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
