//
//  DockBrowser.swift
//  ESPDeck Bridge
//
//  Finds Stream Deck Network Docks on the network, for the Network Docks page. A dock
//  advertises two _elg._tcp services: itself (TXT dt=215, on port 5343) and the Stream Deck
//  plugged into it (dt=213). Only the dock's own is listed. Each one found is asked once who
//  it is and what's plugged in (DockLink's probe), as Elgato's app does, so it can be shown
//  by name and model before anyone adds it. Nothing is changed on a dock until it's added.
//

import Foundation
import Network
import Observation

/// A dock on the network, and what it said about itself.
struct FoundDock: Identifiable, Equatable {
	/// Its Bonjour service name, which is how it's found again.
	let serviceName : String
	var serial      : String?
	var firmware    : String?
	/// The Stream Deck plugged into it, as the dock names it; nil if none.
	var deckModel   : String?
	/// Whether ESPDeck Bridge can drive that Stream Deck through a dock.
	var supported   = true
	/// It didn't answer, and why.
	var problem     : String?

	var id: String { serviceName }
	/// Its device ID once it's added, when it's said its serial number.
	var deviceID: String? { serial.map( DockDeck.deviceID( serial: ) ) }
}

/// Browses for docks while turned on; see the file comment.
@Observable
final class DockBrowser {
	static let serviceType = "_elg._tcp"
	/// The TXT record's device type for a dock itself.
	private static let dockType = "215"

	/// Docks on the network now, by name.
	private(set) var found: [FoundDock] = []
	/// Whether it's looking, for the page's spinner.
	private(set) var browsing = false
	/// Why it can't look (local network access turned off, say).
	private(set) var problem: String?

	@ObservationIgnored private var browser : NWBrowser?
	@ObservationIgnored private var probes  : [String: DockLink] = [:]

	/// Starts looking.
	func start() {
		guard browser == nil else { return }
		let browser = NWBrowser( for: .bonjourWithTXTRecord( type: Self.serviceType, domain: nil ), using: NWParameters() )
		browser.stateUpdateHandler = { [weak self] state in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.stateChanged( state ) } }
		}
		browser.browseResultsChangedHandler = { [weak self] results, _ in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.resultsChanged( results ) } }
		}
		browser.start( queue: .main )
		self.browser = browser
		browsing = true
	}

	/// Stops looking, and forgets what it found.
	func stop() {
		browser?.cancel()
		browser = nil
		browsing = false
		problem  = nil
		for probe in probes.values { probe.stop() }
		probes = [:]
		found  = []
	}

	/// Asks a dock again who it is (one that didn't answer the first time).
	func probeAgain( _ serviceName: String ) {
		guard let index = found.firstIndex( where: { $0.serviceName == serviceName } ) else { return }
		found[index] = FoundDock( serviceName: serviceName )
		probe( serviceName )
	}

	private func stateChanged( _ state: NWBrowser.State ) {
		switch state {
			case .ready:
				problem = nil
			case .failed( let error ), .waiting( let error ):
				problem = error.localizedDescription
			default:
				break
		}
	}

	private func resultsChanged( _ results: Set<NWBrowser.Result> ) {
		var names: [String] = []
		for result in results {
			guard case .service( let name, _, _, _ ) = result.endpoint else { continue }
			if case .bonjour( let txt ) = result.metadata, let type = txt["dt"], type != Self.dockType { continue }
			names.append( name )
		}
		// Gone from the network.
		for dock in found where !names.contains( dock.serviceName ) {
			probes.removeValue( forKey: dock.serviceName )?.stop()
		}
		found.removeAll { !names.contains( $0.serviceName ) }
		// New on it.
		for name in names.sorted() where !found.contains( where: { $0.serviceName == name } ) {
			found.append( FoundDock( serviceName: name ) )
			probe( name )
		}
	}

	/// Asks a dock who it is and what's plugged into it, then disconnects.
	private func probe( _ name: String ) {
		probes[name]?.stop()
		let link = DockLink( endpoint: DockDeck.endpoint( serviceName: name ), probe: true )
		probes[name] = link
		link.onIdentity = { [weak self] identity in
			self?.update( name ) { $0.serial = identity.serial; $0.firmware = identity.firmware }
		}
		link.onCapabilities = { [weak self] value in
			self?.update( name ) { dock in
				dock.deckModel = value.connected ? ( value.model.isEmpty ? "Stream Deck" : value.model ) : nil
				dock.supported = !value.connected || DockModel.model( productID: value.productID ) != nil
			}
			self?.probes[name] = nil
		}
		link.onClosed = { [weak self] reason in
			self?.update( name ) { $0.problem = reason }
			self?.probes[name] = nil
		}
		link.start()
	}

	private func update( _ name: String, _ change: ( inout FoundDock ) -> Void ) {
		guard let index = found.firstIndex( where: { $0.serviceName == name } ) else { return }
		change( &found[index] )
	}
}
