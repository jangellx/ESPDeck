//
//  ConfigurationView.swift
//  ESPDeck Bridge
//
//  Devices in the sidebar; each device has a Keys page (simulated deck plus the
//  selected key's settings) and a Device page. New devices waiting to be paired, and
//  the app's Updates and About pages, are in the sidebar too.
//

import HomeKit
import SwiftUI

/// Sidebar selections that aren't device IDs.
enum SidebarItem {
	static let updates   = "app:updates"
	static let about     = "app:about"
	static let newPrefix = "new:"

	static func newDevice( _ client: ClientID ) -> String { newPrefix + client.uuidString }
}

struct ConfigurationView: View {
	let controller: DeckController

	@State private var selectedDevice: String?

	var body: some View {
		NavigationSplitView {
			Sidebar( controller: controller, selection: $selectedDevice )
				.navigationSplitViewColumnWidth( min: 220, ideal: 250, max: 320 )
		} detail: {
			if selectedDevice == SidebarItem.updates {
				UpdatesView( controller: controller )
			} else if selectedDevice == SidebarItem.about {
				AboutView( controller: controller )
			} else if let selection = selectedDevice, selection.hasPrefix( SidebarItem.newPrefix ),
					  let client = UUID( uuidString: String( selection.dropFirst( SidebarItem.newPrefix.count ) ) ) {
				NewDeviceView( controller: controller, client: client )
					.id( client )
			} else if let id = selectedDevice, controller.device( id ) != nil {
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
						AddDemoDeckMenu( controller: controller, selection: $selectedDevice )
					}
				}
			}
		}
		.onAppear {
			if selectedDevice == nil { selectedDevice = controller.devices.first?.id }
		}
		.onChange( of: controller.devices.map( \.id ) ) { old, new in
			// Follow a device that just finished pairing.
			if let added = new.first( where: { !old.contains( $0 ) } ), selectedDevice?.hasPrefix( SidebarItem.newPrefix ) == true {
				selectedDevice = added
			} else if selectedDevice == nil || ( controller.device( selectedDevice ?? "" ) == nil && !( selectedDevice ?? "" ).contains( ":" ) ) {
				selectedDevice = controller.devices.first?.id
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
						VStack( alignment: .leading, spacing: 1 ) {
							Text( controller.settings( device.id )?.name ?? device.id )
							Text( status.text.components( separatedBy: ": " ).last ?? "" )
								.font( .caption )
								.foregroundStyle( .secondary )
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
			}

			Section( "Status" ) {
				ForEach( [ controller.serverStatus, controller.homeStatus ].compactMap { $0 }, id: \.self ) { item in
					Label {
						Text( item.text )
					} icon: {
						StatusIndicator( level: item.level )
					}
				}
				if controller.home.homes.count > 1 {
					Picker( "Home", selection: homeBinding ) {
						ForEach( controller.home.homes, id: \.uniqueIdentifier ) { home in
							Text( home.name ).tag( Optional( home.uniqueIdentifier ) )
						}
					}
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

	private var homeBinding: Binding<UUID?> {
		Binding {
			controller.home.home?.uniqueIdentifier
		} set: {
			controller.setHome( $0 )
		}
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

	private enum Page: String, CaseIterable, Identifiable {
		case keys   = "Keys"
		case device = "Device"
		case log    = "Log"
		var id: String { rawValue }
	}

	@State private var page        = Page.keys
	@State private var selectedKey = 0

	var body: some View {
		VStack( spacing: 0 ) {
			Picker( "Page", selection: $page ) {
				ForEach( Page.allCases ) { page in
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
								DeckGridView( controller: controller, deviceID: deviceID, selection: $selectedKey )
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
			selectedKey = min( selectedKey, controller.layout( deviceID ).keyCount - 1 )
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
