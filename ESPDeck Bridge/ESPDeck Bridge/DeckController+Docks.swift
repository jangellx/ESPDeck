//
//  DeckController+Docks.swift
//  ESPDeck Bridge
//
//  Stream Deck Network Docks, an experimental way to use a Stream Deck without an ESP32:
//  ESPDeck Bridge drives the Stream Deck plugged into an Elgato Network Dock directly.
//  Turned on from the Network Docks page, which lists the docks found on the network. A
//  dock is only connected to once it's added there (someone may be using it with Elgato's
//  app), and from then on it's a device like any other: DockDeck makes it look like one, and
//  DeckServer passes its sessions on as connections.
//

import Foundation

extension DeckController {
	static let networkDocksDefault = "networkDocksEnabled"

	/// Starts looking for docks and connecting to the added ones, if docks are turned on.
	func startNetworkDocks() {
		guard networkDocksEnabled else { return }
		dockBrowser.start()
		syncDocks()
	}

	/// Turns Network Docks on or off.
	func setNetworkDocks( enabled: Bool ) {
		guard enabled != networkDocksEnabled else { return }
		networkDocksEnabled = enabled
		UserDefaults.standard.set( enabled, forKey: Self.networkDocksDefault )
		if enabled {
			dockBrowser.start()
		} else {
			dockBrowser.stop()
		}
		syncDocks()
	}

	/// Whether the device is a Network Dock.
	func isDock( _ id: String ) -> Bool {
		settings( id )?.isDock == true
	}

	/// The added dock this found one is, if it's been added.
	func addedDock( _ found: FoundDock ) -> String? {
		guard let id = found.deviceID, isDock( id ) else { return nil }
		return id
	}

	/// Adds a dock found on the network as a device, connects to it, and shows it.
	func addDock( _ found: FoundDock ) {
		guard let id = found.deviceID else { return }
		if config.settings.deviceIndex( id ) == nil {
			let suffix   = String( ( found.serial ?? "" ).suffix( 4 ) ).uppercased()
			var settings = DeviceSettings( id: id, name: suffix.isEmpty ? "Network Dock" : "Network Dock \(suffix)" )
			settings.dockService = found.serviceName
			if let model = DockModel.all.first( where: { $0.name == found.deckModel } ) {
				settings.layout = DeckLayout( model: model.name, rows: model.rows, cols: model.cols, keySize: max( model.keySize, 72 ),
											  format: model.format, transform: model.transform )
			}
			addDevice( settings )
		} else if let index = config.settings.deviceIndex( id ) {
			// Found under a new name on the network.
			config.settings.devices[index].dockService = found.serviceName
			dockDecks.removeValue( forKey: id )?.stop()
		}
		syncDocks()
		window.selection = id
	}

	/// Connects each added dock while docks are turned on, and disconnects the rest (forgotten
	/// ones, or all of them when docks are turned off).
	func syncDocks() {
		var wanted: [String: DeviceSettings] = [:]
		if networkDocksEnabled {
			for settings in config.settings.devices where settings.isDock { wanted[settings.id] = settings }
		}
		for ( id, dock ) in dockDecks where wanted[id] == nil {
			dock.stop()
			dockDecks[id] = nil
		}
		for ( id, settings ) in wanted where dockDecks[id] == nil {
			guard let service = settings.dockService else { continue }
			let dock = DockDeck( id: id, serviceName: service,
								 settings: DockDeck.Settings( name: settings.name, brightness: settings.brightness,
															  orientation: settings.orientation, sleepTimeout: settings.sleepTimeout ) )
			server.attach( dock )
			dock.onEvent = { [weak self] text in self?.logEvent( text, device: id ) }
			dockDecks[id] = dock
			dock.start()
		}
	}

	/// Tries an offline dock again now.
	func retryDock( _ id: String ) {
		dockDecks[id]?.retryNow()
	}

	/// For a dock that isn't working normally: what's wrong and how to fix it.
	func dockExplanation( _ device: DeckDevice ) -> String? {
		guard networkDocksEnabled else {
			return "Network Docks are turned off. Turn them on from the Network Docks page to use this dock."
		}
		guard device.isOnline else {
			return "ESPDeck Bridge can't reach this Network Dock. Check that it has power and is on the same network as this Mac.\n\nA dock works with one app at a time: if Elgato's Stream Deck app is using it, quit that app or remove the dock from it."
		}
		if !device.deck.connected {
			return "The Network Dock is connected, but no Stream Deck that ESPDeck Bridge can drive through a dock is plugged into it. The Mini and the original Stream Deck aren't supported on a dock yet. The Log page says what the dock reported."
		}
		return nil
	}
}
