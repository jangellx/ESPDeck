//
//  DeckServer.swift
//  ESPDeck Bridge
//
//  WebSocket server the ESP32s connect to, advertised over Bonjour as _deckbridge._tcp.
//  Any number of clients; DeckController maps them to devices once they authenticate.
//  Before that, only handshake messages pass in either direction; after it, every frame
//  carries a MAC (PROTOCOL.md, Security).
//  Network callbacks are delivered on the main queue, so each one asserts main-actor
//  isolation.
//

import Foundation
import Network
import Observation

typealias ClientID = UUID

@Observable
final class DeckServer {
	static let serviceType = "_deckbridge._tcp"
	static let port: NWEndpoint.Port = 48620

	enum ListenerState: Equatable {
		case stopped
		case listening
		case failed( String )
	}

	private(set) var listenerState = ListenerState.stopped

	@ObservationIgnored var onConnect    : ( ( ClientID ) -> Void )?
	@ObservationIgnored var onDisconnect : ( ( ClientID ) -> Void )?
	/// The message, and the exact frame payload it came from (for the hello proof).
	@ObservationIgnored var onMessage    : ( ( ClientID, DeviceMessage, Data ) -> Void )?
	/// Every frame sent or received, summarized, for the traffic log.
	@ObservationIgnored var onTraffic    : ( ( ClientID, TrafficEntry ) -> Void )?

	private struct Session {
		let key         : Data
		var sendCounter : UInt64 = 0
		var recvCounter : UInt64 = 0
	}

	private struct Client {
		let connection : NWConnection
		var endpoint   : String?
		var session    : Session?
	}

	@ObservationIgnored private var listener    : NWListener?
	@ObservationIgnored private var clients     : [ClientID: Client] = [:]
	@ObservationIgnored private var restartTask : Task<Void, Never>?

	/// Advertised in the Bonjour TXT record so paired devices find their own bridge.
	@ObservationIgnored private var bridgeID = ""

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
			let txt = NWTXTRecord( [ "id": bridgeID, "proto": "3" ] )
			listener.service = NWListener.Service( name: "ESPDeck Bridge", type: Self.serviceType, domain: nil, txtRecord: txt )
			listener.stateUpdateHandler = { [weak self] state in
				MainActor.assumeIsolated { self?.listenerStateChanged( state ) }
			}
			listener.newConnectionHandler = { [weak self] connection in
				MainActor.assumeIsolated { self?.accept( connection ) }
			}
			listener.start( queue: .main )
			self.listener = listener
		} catch {
			listenerState = .failed( error.localizedDescription )
			scheduleRestart()
		}
	}

	func stop() {
		restartTask?.cancel()
		listener?.cancel()
		listener = nil
		for id in Array( clients.keys ) {
			drop( id )
		}
		listenerState = .stopped
	}

	func endpoint( of client: ClientID ) -> String? {
		clients[client]?.endpoint
	}

	func isAuthenticated( _ client: ClientID ) -> Bool {
		clients[client]?.session != nil
	}

	/// Switches a client to MAC'd frames with session key `key`.
	func establishSession( _ client: ClientID, key: Data ) {
		clients[client]?.session = Session( key: key )
	}

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

	private func scheduleRestart() {
		restartTask?.cancel()
		restartTask = Task { [weak self] in
			try? await Task.sleep( for: .seconds( 5 ) )
			guard !Task.isCancelled, let self else { return }
			start( bridgeID: bridgeID )
		}
	}

	// MARK: - Clients

	private func accept( _ connection: NWConnection ) {
		let id = ClientID()
		clients[id] = Client( connection: connection )
		connection.stateUpdateHandler = { [weak self] state in
			MainActor.assumeIsolated { self?.connectionStateChanged( state, client: id ) }
		}
		connection.start( queue: .main )
	}

	private func connectionStateChanged( _ state: NWConnection.State, client id: ClientID ) {
		guard let client = clients[id] else { return }
		switch state {
			case .ready:
				clients[id]?.endpoint = Self.describe( client.connection.endpoint )
				print( "[DeckServer] Connected: \(clients[id]?.endpoint ?? "?")" )
				receive( from: id )
				onConnect?( id )
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
		if client.endpoint != nil {
			onDisconnect?( id )
		}
	}

	private func receive( from id: ClientID ) {
		guard let connection = clients[id]?.connection else { return }
		connection.receiveMessage { [weak self] data, context, _, error in
			MainActor.assumeIsolated {
				self?.received( data, context: context, error: error, from: id )
			}
		}
	}

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
				guard let payload = verify( data ?? Data(), text: metadata?.opcode == .text, from: id ) else {
					print( "[DeckServer] Bad MAC from \(clients[id]?.endpoint ?? "?"); closing" )
					drop( id )
					return
				}
				guard metadata?.opcode == .text, let message = DeviceMessage( json: payload ) else {
					print( "[DeckServer] Unrecognized message: \(String( decoding: payload.prefix( 200 ), as: UTF8.self ))" )
					break
				}
				if clients[id]?.session == nil && !message.isHandshake {
					print( "[DeckServer] Ignoring a message before authentication" )
					break
				}
				onMessage?( id, message, payload )
				onTraffic?( id, TrafficEntry( direction: .received, summary: TrafficEntry.describe( json: payload ), bytes: payload.count ) )
			case .close:
				drop( id )
				return
			default:
				break
		}
		guard clients[id] != nil else { return }
		receive( from: id )
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

	func send( _ message: HostMessage, to id: ClientID ) {
		guard let data = try? JSONEncoder().encode( message ) else { return }
		guard message.isHandshake || isAuthenticated( id ) else {
			print( "[DeckServer] Not sending \(String( decoding: data.prefix( 40 ), as: UTF8.self )) before authentication" )
			return
		}
		send( data, opcode: .text, to: id )
	}

	func sendImage( hash: String, image: Data, to id: ClientID ) {
		guard isAuthenticated( id ), let frame = HostMessage.imageFrame( hash: hash, image: image ) else { return }
		send( frame, opcode: .binary, to: id )
	}

	func sendFirmwareChunk( offset: Int, chunk: Data, to id: ClientID ) {
		guard isAuthenticated( id ) else { return }
		send( HostMessage.firmwareFrame( offset: offset, chunk: chunk ), opcode: .binary, to: id )
	}

	private func send( _ payload: Data, opcode: NWProtocolWebSocket.Opcode, to id: ClientID ) {
		guard let connection = clients[id]?.connection else { return }
		let summary = opcode == .text ? TrafficEntry.describe( json: payload ) : TrafficEntry.describe( binary: payload )
		onTraffic?( id, TrafficEntry( direction: .sent, summary: summary, bytes: payload.count ) )

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
