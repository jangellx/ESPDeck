//
//  DockLink.swift
//  ESPDeck Bridge
//
//  The connections to one Network Dock (CoraProtocol.swift): the dock's own port, which says
//  who the dock is and where its Stream Deck is, and the Stream Deck's port, which carries
//  images out and key states back. Both are kept open and their keepalives answered, as
//  Elgato's app does. Key images go out one at a time: the dock acknowledges each once the
//  deck has it, and the next waits for that.
//
//  A link that fails closes both connections and says so once (onClosed); DockDeck decides
//  when to try again. With `probe`, it only asks who the dock is and what's plugged in, then
//  closes (DockBrowser, to list docks found on the network).
//
//  Network callbacks are delivered on the main queue, as DeckServer's are.
//

import Foundation
import Network

/// The connections to one dock; see the file comment.
final class DockLink {
	/// Who the dock is.
	struct Identity: Equatable {
		var serial   : String
		var firmware : String?
	}

	private static let queue          = DispatchQueue( label: "com.tmproductions.espdeck.docks" )
	/// The dock's own port answers within this, or the link gives up.
	private static let answerTimeout  : TimeInterval = 8
	/// Docks send keepalives every few seconds; this long without anything means it's gone.
	private static let silenceTimeout : TimeInterval = 20
	/// How long an image waits for the dock's acknowledgment before the next one goes anyway.
	private static let ackTimeout     : Duration = .seconds( 2 )

	/// The dock answered who it is (once per link).
	var onIdentity     : ( ( Identity ) -> Void )?
	/// What's plugged into the dock: when the link starts, and whenever it changes.
	var onCapabilities : ( ( DockCapabilities ) -> Void )?
	/// The Stream Deck's port is open: images can go out.
	var onDeckReady    : ( () -> Void )?
	/// The Stream Deck's port closed (it was unplugged, say) while the dock's stayed open.
	var onDeckLost     : ( () -> Void )?
	/// Which keys are down, in the deck's own order.
	var onKeys         : ( ( [Bool] ) -> Void )?
	/// The link is down, and why, in a few words. Called once; nothing else follows.
	var onClosed       : ( ( String ) -> Void )?

	let endpoint : NWEndpoint
	private let probe: Bool

	private var dock         : NWConnection?
	private var deck         : NWConnection?
	private var dockReader   = CoraFrameReader()
	private var deckReader   = CoraFrameReader()
	private var identity     : Identity?
	private var serial       : String?
	private var firmware     : String?
	private var capabilities : DockCapabilities?
	/// The deck's port, while its connection is open or opening.
	private var deckPort     : UInt16?
	private var deckReady    = false
	private var closed       = false
	private var lastHeard    = Date()
	private var watchdog     : Task<Void, Never>?
	private var nextMessageID: UInt32 = 1

	/// Images waiting to go out, oldest first; one per key (a newer image replaces it).
	private var imageQueue   : [( key: Int, image: Data, done: () -> Void )] = []
	/// The message ID whose acknowledgment the image in flight waits for.
	private var awaitingAck  : UInt32?
	private var ackTimer     : Task<Void, Never>?
	private var inFlightDone : ( () -> Void )?

	init( endpoint: NWEndpoint, probe: Bool = false ) {
		self.endpoint = endpoint
		self.probe    = probe
	}

	/// The dock's address, once connected.
	var address: String? {
		guard case .hostPort( let host, _ )? = dock?.currentPath?.remoteEndpoint else { return nil }
		switch host {
			case .ipv4( let address ): return "\(address)"
			case .ipv6( let address ): return "\(address)"
			case .name( let name, _ ): return name
			@unknown default:          return "\(host)"
		}
	}

	// MARK: - Opening and closing

	/// Connects to the dock's own port.
	func start() {
		guard dock == nil, !closed else { return }
		let connection = NWConnection( to: endpoint, using: Self.parameters() )
		dock = connection
		connection.stateUpdateHandler = { [weak self] state in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.dockStateChanged( state ) } }
		}
		connection.start( queue: Self.queue )
		lastHeard = Date()
		watchdog = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep( for: .seconds( 2 ) )
				guard let self, !Task.isCancelled else { return }
				let quiet = Date().timeIntervalSince( lastHeard )
				if identity == nil && quiet > Self.answerTimeout {
					fail( "the dock didn't answer" )
				} else if quiet > Self.silenceTimeout {
					fail( "the dock stopped answering" )
				}
			}
		}
	}

	/// Closes both connections, without calling onClosed.
	func stop() {
		onClosed = nil
		fail( "stopped" )
	}

	/// TCP without Nagle's delay (keys and acknowledgments are small), with keepalives.
	private static func parameters() -> NWParameters {
		let tcp = NWProtocolTCP.Options()
		tcp.noDelay           = true
		tcp.enableKeepalive   = true
		tcp.keepaliveIdle     = 10
		tcp.keepaliveInterval = 5
		tcp.keepaliveCount    = 3
		return NWParameters( tls: nil, tcp: tcp )
	}

	/// Closes everything and reports why, once.
	private func fail( _ reason: String ) {
		guard !closed else { return }
		closed = true
		watchdog?.cancel()
		ackTimer?.cancel()
		for connection in [ dock, deck ].compactMap( { $0 } ) {
			connection.stateUpdateHandler = nil
			connection.cancel()
		}
		dock = nil
		deck = nil
		let pending = imageQueue.map( \.done ) + [ inFlightDone ].compactMap { $0 }
		imageQueue   = []
		inFlightDone = nil
		awaitingAck  = nil
		pending.forEach { $0() }
		onClosed?( reason )
	}

	// MARK: - The dock's own port

	private func dockStateChanged( _ state: NWConnection.State ) {
		switch state {
			case .ready:
				for report in [ DockMessage.firmwareReport, DockMessage.serialReport, DockMessage.capabilitiesReport ] {
					send( DockMessage.question( report ), on: dock )
				}
				receive( on: dock, isDeck: false )
			case .failed( let error ):
				fail( "couldn't reach the dock (\(error.localizedDescription))" )
			case .waiting( let error ):
				fail( "couldn't reach the dock (\(error.localizedDescription))" )
			case .cancelled:
				fail( "the dock closed the connection" )
			default:
				break
		}
	}

	private func handleDock( _ frame: CoraFrame ) {
		let payload = frame.payload
		if let connection = DockMessage.keepalive( payload ) {
			send( DockMessage.keepaliveAck( connection: connection ), on: dock )
		} else if let value = DockMessage.firmware( payload ) {
			firmware = value
		} else if let value = DockMessage.serial( payload ) {
			serial = value
		} else if let value = DockCapabilities( payload: payload ) {
			capabilities = value
			if identity != nil { capabilitiesChanged( value ) }
		}

		// Who it is, once it's said its serial number and what's plugged in.
		if identity == nil, let serial, let capabilities {
			let found = Identity( serial: serial, firmware: firmware )
			identity = found
			onIdentity?( found )
			guard !closed else { return }   // not the dock that was wanted
			if probe {
				onCapabilities?( capabilities )
				stop()
				return
			}
			capabilitiesChanged( capabilities )
		}
	}

	/// Opens the deck's port when a deck is plugged in (or moves), and closes it when not.
	private func capabilitiesChanged( _ value: DockCapabilities ) {
		onCapabilities?( value )
		let port = value.connected && value.port != 0 ? value.port : nil
		guard port != deckPort else { return }
		closeDeck()
		if let port { openDeck( port: port ) }
	}

	// MARK: - The Stream Deck's port

	/// Connects to the deck's port, on the address the dock's own connection reached.
	private func openDeck( port: UInt16 ) {
		guard case .hostPort( let host, _ )? = dock?.currentPath?.remoteEndpoint, let nwPort = NWEndpoint.Port( rawValue: port ) else {
			fail( "couldn't tell the dock's address" )
			return
		}
		deckPort   = port
		deckReader = CoraFrameReader()
		let connection = NWConnection( to: .hostPort( host: host, port: nwPort ), using: Self.parameters() )
		deck = connection
		connection.stateUpdateHandler = { [weak self, weak connection] state in
			DispatchQueue.main.async { MainActor.assumeIsolated {
				guard let self, let connection, connection === self.deck else { return }
				self.deckStateChanged( state )
			} }
		}
		connection.start( queue: Self.queue )
	}

	/// Closes the deck's port and drops what was waiting to go to it.
	private func closeDeck() {
		let wasReady = deckReady
		deck?.stateUpdateHandler = nil
		deck?.cancel()
		deck      = nil
		deckPort  = nil
		deckReady = false
		ackTimer?.cancel()
		let pending = imageQueue.map( \.done ) + [ inFlightDone ].compactMap { $0 }
		imageQueue   = []
		inFlightDone = nil
		awaitingAck  = nil
		pending.forEach { $0() }
		if wasReady { onDeckLost?() }
	}

	private func deckStateChanged( _ state: NWConnection.State ) {
		switch state {
			case .ready:
				// As Elgato's app opens: the deck's firmware, serial number and device info.
				for report: UInt8 in [ 0x05, 0x06, 0x0B ] {
					send( DeckReport.getReport( report, messageID: takeMessageID() ), on: deck )
				}
				deckReady = true
				receive( on: deck, isDeck: true )
				onDeckReady?()
			case .failed, .cancelled, .waiting:
				// The dock's own port says whether a deck is still plugged in; ask again.
				closeDeck()
				send( DockMessage.question( DockMessage.capabilitiesReport ), on: dock )
			default:
				break
		}
	}

	private func handleDeck( _ frame: CoraFrame ) {
		let payload = frame.payload
		if let connection = DockMessage.keepalive( payload ) {
			send( DockMessage.keepaliveAck( connection: connection ), on: deck )
		} else if frame.flags.contains( .ackNak ) {
			if frame.messageID == awaitingAck { imageAcknowledged() }
		} else if let states = DeckReport.keyStates( payload ) {
			onKeys?( states )
		}
	}

	// MARK: - Sending

	/// Sets the deck's backlight, 0 to 100.
	func setBrightness( _ percent: Int ) {
		guard deckReady else { return }
		send( DeckReport.brightness( percent, messageID: takeMessageID() ), on: deck )
	}

	/// Sends a key's image (JPEG, already sized and turned for the deck); `done` runs once the
	/// deck has it, or it's been dropped (a newer image for the key, the link closing).
	func sendImage( _ image: Data, key: Int, done: @escaping () -> Void ) {
		guard deckReady else { done(); return }
		if let index = imageQueue.firstIndex( where: { $0.key == key } ) {
			imageQueue[index].done()
			imageQueue.remove( at: index )
		}
		imageQueue.append( ( key, image, done ) )
		sendNextImage()
	}

	/// The next image, unless one is waiting for its acknowledgment.
	private func sendNextImage() {
		guard awaitingAck == nil, deckReady, !imageQueue.isEmpty else { return }
		let next      = imageQueue.removeFirst()
		let messageID = takeMessageID()
		var data      = Data()
		for frame in DeckReport.imageFrames( key: next.key, image: next.image, messageID: messageID ) {
			data.append( frame.encoded )
		}
		awaitingAck  = messageID
		inFlightDone = next.done
		deck?.send( content: data, completion: .contentProcessed { _ in } )
		ackTimer?.cancel()
		ackTimer = Task { [weak self] in
			try? await Task.sleep( for: Self.ackTimeout )
			guard !Task.isCancelled, let self, awaitingAck == messageID else { return }
			imageAcknowledged()   // late or lost: carry on
		}
	}

	private func imageAcknowledged() {
		ackTimer?.cancel()
		awaitingAck = nil
		let done = inFlightDone
		inFlightDone = nil
		done?()
		sendNextImage()
	}

	private func takeMessageID() -> UInt32 {
		defer { nextMessageID = nextMessageID == UInt32.max ? 1 : nextMessageID + 1 }
		return nextMessageID
	}

	private func send( _ frame: CoraFrame, on connection: NWConnection? ) {
		connection?.send( content: frame.encoded, completion: .contentProcessed { _ in } )
	}

	// MARK: - Receiving

	private func receive( on connection: NWConnection?, isDeck: Bool ) {
		connection?.receive( minimumIncompleteLength: 1, maximumLength: 64 * 1024 ) { [weak self, weak connection] data, _, isComplete, error in
			DispatchQueue.main.async { MainActor.assumeIsolated {
				guard let self, let connection else { return }
				self.received( data, isComplete: isComplete, error: error, on: connection, isDeck: isDeck )
			} }
		}
	}

	private func received( _ data: Data?, isComplete: Bool, error: NWError?, on connection: NWConnection, isDeck: Bool ) {
		// A connection replaced or closed since.
		guard connection === ( isDeck ? deck : dock ) else { return }
		if let data, !data.isEmpty {
			lastHeard = Date()
			if isDeck {
				for frame in deckReader.append( data ) { handleDeck( frame ) }
			} else {
				for frame in dockReader.append( data ) { handleDock( frame ) }
			}
		}
		guard connection === ( isDeck ? deck : dock ) else { return }
		if error != nil || isComplete {
			if isDeck {
				closeDeck()
				send( DockMessage.question( DockMessage.capabilitiesReport ), on: dock )
			} else {
				fail( "the dock closed the connection" )
			}
			return
		}
		receive( on: connection, isDeck: isDeck )
	}
}
