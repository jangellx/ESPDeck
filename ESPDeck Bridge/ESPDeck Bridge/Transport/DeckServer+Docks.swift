//
//  DeckServer+Docks.swift
//  ESPDeck Bridge
//
//  Network Docks as DeckServer connections. A DockDeck speaks the same messages as an
//  ESP32 (see its file comment), so each of its sessions gets a ClientID like a socket
//  would, and DeckController drives it the same way. It's on the Mac, so there's nothing to
//  authenticate: its sessions count as authenticated from their hello on.
//

import Foundation

extension DeckServer {
	/// Passes a dock's sessions and messages on as a connection's. DeckController sets its
	/// onEvent.
	func attach( _ dock: DockDeck ) {
		dock.onConnect = { [weak self, weak dock] hello, json in
			guard let self, let dock else { return }
			let client = ClientID()
			dockSessions[client] = dock
			onMessage?( client, .hello( hello ), json )
			onTraffic?( client, .frame( json: json, direction: .received ) )
		}
		dock.onMessage = { [weak self, weak dock] json in
			guard let self, let dock, let client = session( of: dock ) else { return }
			if let message = DeviceMessage( json: json ) {
				onMessage?( client, message, json )
			}
			onTraffic?( client, .frame( json: json, direction: .received ) )
		}
		dock.onDisconnect = { [weak self, weak dock] in
			guard let self, let dock, let client = session( of: dock ) else { return }
			dockSessions[client] = nil
			onDisconnect?( client )
		}
	}

	/// Whether the connection is a dock's session.
	func isDock( _ client: ClientID ) -> Bool {
		dockSessions[client] != nil
	}

	/// The dock's current session, if it has one.
	private func session( of dock: DockDeck ) -> ClientID? {
		dockSessions.first { $0.value === dock }?.key
	}

	/// Ends a dock's session (its link reconnects by itself); false if it isn't a dock's.
	func dropDock( _ client: ClientID ) -> Bool {
		guard let dock = dockSessions[client] else { return false }
		dock.disconnect()
		return true
	}
}
