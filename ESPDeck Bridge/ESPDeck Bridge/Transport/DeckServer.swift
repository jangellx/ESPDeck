//
//  DeckServer.swift
//  ESPDeck Bridge
//
//  WebSocket server the ESP32s connect to, advertised over Bonjour as _deckbridge._tcp.
//  Any number of clients; DeckController maps them to devices once they authenticate.
//  Before that, only handshake messages pass in either direction; after it, every frame
//  carries a MAC (PROTOCOL.md, Security).
//  Connections that haven't authenticated are limited, so nothing else on the network can
//  tie the app up: how many there are (per host and in all), how long they may take to say
//  hello and to finish the handshake, and how large and how frequent their frames are.
//  Network callbacks are delivered on the main queue, so each one asserts main-actor
//  isolation.
//

import Foundation
import Network
import Observation

/// One connection, for as long as it's open.
typealias ClientID = UUID

/// The WebSocket server; see the file comment.
@Observable
final class DeckServer {
	/// Connections run here, not on the main thread, so the network stack answers the
	/// devices' pings (autoReplyPing) even while the main thread is busy: a stall of 10 s used
	/// to drop every deck. What they report is handled on the main thread, in order.
	private static let networkQueue = DispatchQueue( label: "com.tmproductions.espdeck.server" )

	static let serviceType = "_deckbridge._tcp"
	static let port: NWEndpoint.Port = 48620
	/// PROTOCOL.md's version, advertised in the Bonjour TXT record.
	static let protocolVersion = 4

	// Unauthenticated connections
	static let maxUnauthenticated        = 8
	static let maxUnauthenticatedPerHost = 2
	static let helloTimeout              : TimeInterval = 15
	/// A hello lists the device's cached images (up to about 480 hashes, ~18 KB).
	static let maxHelloSize              = 32 * 1024
	static let maxHandshakeFrameSize     = 4 * 1024
	/// Frames per rateWindow before the connection is closed.
	static let maxHandshakeFrames        = 12
	static let rateWindow                : TimeInterval = 10

	/// Whether devices can connect, for the status line.
	enum ListenerState: Equatable {
		case stopped
		case listening
		case failed( String )
	}

	private(set) var listenerState = ListenerState.stopped

	/// A connection that had opened closed, for whatever reason.
	@ObservationIgnored var onDisconnect : ( ( ClientID ) -> Void )?
	/// The message, and the exact frame payload it came from (for the hello proof).
	@ObservationIgnored var onMessage    : ( ( ClientID, DeviceMessage, Data ) -> Void )?
	/// Every frame sent or received, summarized, for the traffic log.
	@ObservationIgnored var onTraffic    : ( ( ClientID, TrafficEntry ) -> Void )?

	/// An authenticated connection's key, and each direction's frame counter.
	private struct Session {
		let key         : Data
		var sendCounter : UInt64 = 0
		var recvCounter : UInt64 = 0
	}

	/// A connection, and what the limits on unauthenticated ones need to know.
	private struct Client {
		let connection  : NWConnection
		/// The remote address, for the per-host limit.
		let host        : String
		let accepted    = Date()
		var ready       = false
		var endpoint    : String?
		var session     : Session?
		var helloSeen   = false
		/// Closed if it hasn't authenticated by then; nil while it waits for the user.
		var deadline    : Date?
		var pairing     = false
		/// Frames since windowStart, for the rate limit.
		var windowStart = Date()
		var frames      = 0
	}

	@ObservationIgnored private var listener    : NWListener?
	@ObservationIgnored private var clients     : [ClientID: Client] = [:]
	@ObservationIgnored private var restartTask : Task<Void, Never>?
	@ObservationIgnored private var sweepTask   : Task<Void, Never>?

	/// Advertised in the Bonjour TXT record so paired devices find their own bridge.
	@ObservationIgnored private var bridgeID = ""

	/// Listens and advertises as `bridgeID`; tried again every few seconds if it fails.
	func start( bridgeID: String ) {
		self.bridgeID = bridgeID
		guard listener == nil else { return }

		let tcp = NWProtocolTCP.Options()
		// Notice an ESP32 that lost power without closing the socket.
		tcp.enableKeepalive   = true
		tcp.keepaliveIdle     = 10
		tcp.keepaliveInterval = 5
		tcp.keepaliveCount    = 3

		let webSocket = NWProtocolWebSocket.Options()
		webSocket.autoReplyPing      = true
		webSocket.maximumMessageSize = 64 * 1024

		let parameters = NWParameters( tls: nil, tcp: tcp )
		parameters.defaultProtocolStack.applicationProtocols.insert( webSocket, at: 0 )
		parameters.allowLocalEndpointReuse = true

		do {
			let listener = try NWListener( using: parameters, on: Self.port )
			let txt = NWTXTRecord( [ "id": bridgeID, "proto": "\(Self.protocolVersion)" ] )
			listener.service = NWListener.Service( name: "ESPDeck Bridge", type: Self.serviceType, domain: nil, txtRecord: txt )
			listener.stateUpdateHandler = { [weak self] state in
				DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerStateChanged( state ) } }
			}
			listener.newConnectionHandler = { [weak self] connection in
				DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept( connection ) } }
			}
			listener.start( queue: Self.networkQueue )
			self.listener = listener
			startSweeping()
		} catch {
			listenerState = .failed( error.localizedDescription )
			scheduleRestart()
		}
	}

	/// Stops listening and closes every connection.
	func stop() {
		restartTask?.cancel()
		sweepTask?.cancel()
		sweepTask = nil
		// Its last state changes mustn't reach a listener started after it (a bridge imported
		// from another Mac starts over at once; see DeckController.restartAsReplacedBridge).
		listener?.stateUpdateHandler   = nil
		listener?.newConnectionHandler = nil
		listener?.cancel()
		listener = nil
		for id in Array( clients.keys ) {
			drop( id )
		}
		listenerState = .stopped
	}

	/// The client's address, once its connection is ready.
	func endpoint( of client: ClientID ) -> String? {
		clients[client]?.endpoint
	}

	/// Whether the client has a session: only then does anything but the handshake pass.
	func isAuthenticated( _ client: ClientID ) -> Bool {
		clients[client]?.session != nil
	}

	/// Switches a client to MAC'd frames with session key `key`.
	func establishSession( _ client: ClientID, key: Data ) {
		clients[client]?.session  = Session( key: key )
		clients[client]?.deadline = nil
		clients[client]?.pairing  = false
	}

	/// How long an unauthenticated client has left to authenticate: `seconds` from now, or
	/// no limit (nil) while it waits for the user. A pairing client isn't closed to make room
	/// for new connections.
	func setDeadline( _ client: ClientID, in seconds: TimeInterval?, pairing: Bool = false ) {
		guard clients[client]?.session == nil else { return }
		clients[client]?.deadline = seconds.map { Date( timeIntervalSinceNow: $0 ) }
		clients[client]?.pairing  = pairing
	}

	/// Tracks the listener, starting it again after a failure.
	private func listenerStateChanged( _ state: NWListener.State ) {
		switch state {
			case .ready:
				listenerState = .listening
			case .failed( let error ):
				print( "[DeckServer] Listener failed: \(error)" )
				listenerState = .failed( error.localizedDescription )
				listener?.cancel()
				listener = nil
				scheduleRestart()
			case .cancelled:
				if listenerState == .listening { listenerState = .stopped }
			default:
				break
		}
	}

	/// Starts listening again in 5 seconds.
	private func scheduleRestart() {
		restartTask?.cancel()
		restartTask = Task { [weak self] in
			try? await Task.sleep( for: .seconds( 5 ) )
			guard !Task.isCancelled, let self else { return }
			start( bridgeID: bridgeID )
		}
	}

	// MARK: - Clients

	/// A new connection: refused, or let in with a deadline for its hello, within the limits
	/// on unauthenticated ones.
	private func accept( _ connection: NWConnection ) {
		let host    = Self.describe( connection.endpoint )
		let waiting = clients.filter { $0.value.session == nil }
		guard waiting.values.filter( { $0.host == host } ).count < Self.maxUnauthenticatedPerHost else {
			print( "[DeckServer] Refusing another unauthenticated connection from \(host)" )
			connection.cancel()
			return
		}
		if waiting.count >= Self.maxUnauthenticated {
			// Make room: the oldest one that isn't pairing goes.
			guard let oldest = waiting.filter( { !$0.value.pairing } ).min( by: { $0.value.accepted < $1.value.accepted } )?.key else {
				print( "[DeckServer] Refusing a connection from \(host): too many unauthenticated ones" )
				connection.cancel()
				return
			}
			print( "[DeckServer] Too many unauthenticated connections; closing the oldest" )
			drop( oldest )
		}

		let id = ClientID()
		var client = Client( connection: connection, host: host )
		client.deadline = Date( timeIntervalSinceNow: Self.helloTimeout )
		clients[id] = client
		connection.stateUpdateHandler = { [weak self] state in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionStateChanged( state, client: id ) } }
		}
		connection.start( queue: Self.networkQueue )
	}

	/// Starts reading once a connection is ready; drops it when it fails or closes.
	private func connectionStateChanged( _ state: NWConnection.State, client id: ClientID ) {
		guard let client = clients[id] else { return }
		switch state {
			case .ready:
				clients[id]?.ready    = true
				clients[id]?.endpoint = Self.describe( client.connection.endpoint )
				print( "[DeckServer] Connected: \(clients[id]?.endpoint ?? "?")" )
				receive( from: id )
			case .failed( let error ):
				print( "[DeckServer] Connection failed: \(error)" )
				drop( id )
			case .cancelled:
				drop( id )
			default:
				break
		}
	}

	/// Closes a client's connection, e.g. an older one from a device that reconnected.
	func drop( _ id: ClientID ) {
		guard let client = clients.removeValue( forKey: id ) else { return }
		client.connection.stateUpdateHandler = nil
		client.connection.cancel()
		if client.ready {
			onDisconnect?( id )
		}
	}

	/// Closes unauthenticated clients whose deadline has passed, once a second.
	private func startSweeping() {
		guard sweepTask == nil else { return }
		sweepTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep( for: .seconds( 1 ) )
				guard let self else { return }
				let now = Date()
				for ( id, client ) in clients where client.session == nil && client.deadline.map( { $0 < now } ) == true {
					print( "[DeckServer] \(client.host) didn't authenticate in time; closing" )
					drop( id )
				}
			}
		}
	}

	/// Waits for the client's next message.
	private func receive( from id: ClientID ) {
		guard let connection = clients[id]?.connection else { return }
		connection.receiveMessage { [weak self] data, context, _, error in
			DispatchQueue.main.async {
				MainActor.assumeIsolated { self?.received( data, context: context, error: error, from: id ) }
			}
		}
	}

	/// A message arrived: checked against the limits and the session's MAC, then passed on.
	/// Reading continues unless the connection was dropped.
	private func received( _ data: Data?, context: NWConnection.ContentContext?, error: NWError?, from id: ClientID ) {
		guard clients[id] != nil else { return }

		if let error {
			print( "[DeckServer] Receive failed: \(error)" )
			drop( id )
			return
		}

		let metadata = context?.protocolMetadata( definition: NWProtocolWebSocket.definition ) as? NWProtocolWebSocket.Metadata
		switch metadata?.opcode {
			case .text, .binary:
				let frame = data ?? Data()
				let text  = metadata?.opcode == .text
				if clients[id]?.session == nil, let problem = handshakeProblem( frame, text: text, from: id ) {
					print( "[DeckServer] \(problem) from \(clients[id]?.host ?? "?"); closing" )
					drop( id )
					return
				}
				guard let payload = verify( frame, text: text, from: id ) else {
					print( "[DeckServer] Bad MAC from \(clients[id]?.endpoint ?? "?"); closing" )
					drop( id )
					return
				}
				guard text, let message = DeviceMessage( json: payload ) else {
					print( "[DeckServer] Unrecognized message: \(String( decoding: payload.prefix( 200 ), as: UTF8.self ))" )
					break
				}
				if clients[id]?.session == nil {
					guard message.isHandshake else {
						print( "[DeckServer] Ignoring a message before authentication" )
						break
					}
					if case .hello = message {
						// One hello per connection; a second one would restart the handshake.
						guard clients[id]?.helloSeen == false else {
							print( "[DeckServer] A second hello before authentication; closing" )
							drop( id )
							return
						}
						clients[id]?.helloSeen = true
					}
				}
				onMessage?( id, message, payload )
				onTraffic?( id, .frame( json: payload, direction: .received ) )
			case .close:
				drop( id )
				return
			default:
				break
		}
		guard clients[id] != nil else { return }
		receive( from: id )
	}

	/// Why an unauthenticated frame closes the connection, or nil if it may be read: binary
	/// frames, frames larger than a handshake needs, and more of them than it needs.
	private func handshakeProblem( _ frame: Data, text: Bool, from id: ClientID ) -> String? {
		guard var client = clients[id] else { return "Unknown client" }
		guard text else { return "Binary data before authentication" }
		let limit = client.helloSeen ? Self.maxHandshakeFrameSize : Self.maxHelloSize
		guard frame.count <= limit else { return "A \(frame.count) byte frame before authentication" }

		if Date().timeIntervalSince( client.windowStart ) > Self.rateWindow {
			client.windowStart = Date()
			client.frames      = 0
		}
		client.frames += 1
		clients[id] = client
		return client.frames > Self.maxHandshakeFrames ? "Too many frames before authentication" : nil
	}

	/// Checks and strips an authenticated frame's MAC; unauthenticated frames pass as is.
	private func verify( _ frame: Data, text: Bool, from id: ClientID ) -> Data? {
		guard var session = clients[id]?.session else { return frame }

		let mac: Data
		let payload: Data
		if text {
			guard frame.count >= DeckCrypto.macSize * 2, let decoded = Data( hex: String( decoding: frame.prefix( DeckCrypto.macSize * 2 ), as: UTF8.self ) ) else { return nil }
			mac     = decoded
			payload = frame.dropFirst( DeckCrypto.macSize * 2 )
		} else {
			guard frame.count >= DeckCrypto.macSize else { return nil }
			mac     = frame.prefix( DeckCrypto.macSize )
			payload = frame.dropFirst( DeckCrypto.macSize )
		}

		let expected = DeckCrypto.frameMAC( session: session.key, direction: .toBridge, counter: session.recvCounter, payload: Data( payload ) )
		guard DeckCrypto.equal( mac, expected ) else { return nil }
		session.recvCounter += 1
		clients[id]?.session = session
		return Data( payload )
	}

	// MARK: - Sending

	/// Sends a control message; outside a session, only handshake messages go.
	func send( _ message: HostMessage, to id: ClientID ) {
		guard let data = try? JSONEncoder().encode( message ) else { return }
		guard message.isHandshake || isAuthenticated( id ) else {
			print( "[DeckServer] Not sending \(String( decoding: data.prefix( 40 ), as: UTF8.self )) before authentication" )
			return
		}
		send( data, opcode: .text, to: id )
	}

	/// devOTA, with the password's SHA-256 sealed for the frame that carries it (its counter is
	/// the nonce), or turning uploads off. Needs the session.
	func sendDevOTA( passwordHash: Data?, to id: ClientID ) {
		guard let session = clients[id]?.session else { return }
		var sealed: Data?
		if let passwordHash {
			// Nothing else goes out between this and the send below, so this frame gets this counter.
			guard let box = DeckCrypto.sealDevOTA( session: session.key, counter: session.sendCounter, passwordHash: passwordHash ) else { return }
			sealed = box
		}
		send( .devOTA( sealedHash: sealed ), to: id )
	}

	/// `keys`: the keys it's for (from 0), for the log; the frame itself only carries the hash.
	func sendImage( hash: String, image: Data, keys: [Int] = [], to id: ClientID ) {
		guard isAuthenticated( id ), let frame = HostMessage.imageFrame( hash: hash, image: image ) else { return }
		send( frame, opcode: .binary, to: id, entry: .frame( binary: frame, imageKeys: keys ) )
	}

	/// `total`: the size of the whole image, for the log.
	func sendFirmwareChunk( offset: Int, chunk: Data, total: Int, to id: ClientID ) {
		guard isAuthenticated( id ) else { return }
		let frame = HostMessage.firmwareFrame( offset: offset, chunk: chunk )
		send( frame, opcode: .binary, to: id, entry: .frame( binary: frame, firmwareTotal: total ) )
	}

	/// `entry`: what the log records, when it knows more than the frame does.
	private func send( _ payload: Data, opcode: NWProtocolWebSocket.Opcode, to id: ClientID, entry: TrafficEntry? = nil ) {
		guard let connection = clients[id]?.connection else { return }
		onTraffic?( id, entry ?? ( opcode == .text ? .frame( json: payload, direction: .sent ) : .frame( binary: payload ) ) )

		// Inside a session, prefix the MAC: hex for text frames, raw for binary ones.
		var data = payload
		if var session = clients[id]?.session {
			let mac = DeckCrypto.frameMAC( session: session.key, direction: .toDevice, counter: session.sendCounter, payload: payload )
			data    = ( opcode == .text ? Data( mac.hex.utf8 ) : mac ) + payload
			session.sendCounter += 1
			clients[id]?.session = session
		}

		let metadata = NWProtocolWebSocket.Metadata( opcode: opcode )
		let context  = NWConnection.ContentContext( identifier: "message", metadata: [ metadata ] )
		connection.send( content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
			if let error { print( "[DeckServer] Send failed: \(error)" ) }
		} )
	}

	/// The address alone, without the port.
	private static func describe( _ endpoint: NWEndpoint ) -> String {
		switch endpoint {
			case .hostPort( let host, _ ):
				switch host {
					case .ipv4( let address ): "\(address)"
					case .ipv6( let address ): "\(address)"
					case .name( let name, _ ): name
					@unknown default:          "\(host)"
				}
			default:
				"\(endpoint)"
		}
	}
}
