//
//  DeckController+Pairing.swift
//  ESPDeck Bridge
//
//  The unauthenticated part of a connection: the authentication handshake for paired
//  devices, and pairing for new ones (PROTOCOL.md, Security).
//
//  Pairing (protocol 4) compares a code shown on the Mac and on the deck. The deck commits
//  to its key and nonce before it sees the Mac's nonce, so nobody in between can choose keys
//  that make the two codes match. The pairing key is stored only after the user confirmed
//  on both sides and the deck has proved it holds the same key.
//

import CryptoKit
import Foundation

/// A connected device that hasn't authenticated.
struct NewDevice: Identifiable {
	/// Why it hasn't authenticated.
	enum Reason {
		case unpaired
		case pairedElsewhere
		/// It says it's paired with this Mac, but this Mac has no key for it.
		case keyMissing
		case oldFirmware

		/// What's wrong and what to do about it, for the device's page.
		var explanation: String {
			switch self {
				case .unpaired:        "Not paired yet."
				case .pairedElsewhere: "This deck is paired with another Mac's ESPDeck Bridge. Unpair it: it will then show up here as a new device, ready to pair."
				case .keyMissing:      "This Mac lost its pairing key for this deck, so they can't connect securely. Unpair the deck: it will then show up here as a new device, ready to pair again."
				case .oldFirmware:     "Deck firmware is too old to pair with this version of ESPDeck Bridge. Update it over USB."
			}
		}

		/// For a deck that needs unpairing: the way to using it again, step by step.
		var steps: String? {
			switch self {
				case .pairedElsewhere:
					"**To use it here:**\n1. Unpair the deck: [over USB](espdeck:usb-setup), or from its own setup page, or by forgetting it on the other Mac.\n2. Unpaired decks will show up under New Devices, ready to be paired."
				case .keyMissing:
					"**To use it again:**\n1. Unpair the deck: [over USB](espdeck:usb-setup), or from its own setup page.\n2. The unpaired deck will show up under New Devices. Pair it, and its keys and settings will come back."
				case .unpaired, .oldFirmware:
					nil
			}
		}

		/// The deck only accepts pairing while it isn't paired.
		var canPair: Bool { self == .unpaired }
	}

	/// Where pairing with it has got to, for the New Device page.
	enum Pairing: Equatable {
		case idle
		case waitingForDevice
		/// Both sides show the code; the user hasn't answered on the Mac yet.
		case compare( code: String, deckConfirmed: Bool )
		/// The code matches on the Mac; waiting for Confirm on the deck.
		case confirmOnDeck( code: String )
		case finishing
		case failed( String )
	}

	let client  : ClientID
	var hello   : DeviceHello
	var reason  : Reason
	var pairing = Pairing.idle

	var id: ClientID { client }
}

/// Handshake state for one connection.
struct Handshake {
	var hello        : DeviceHello
	/// The exact `hello` frame, which the device's proof covers.
	var helloBytes   : Data
	/// Where the connection comes from.
	var address      : String?
	var key          : Data?
	var bridgeNonce  : Data?
	var pairing      : PairingState?
	/// Frames before authentication, for the device's Log tab once it has authenticated.
	var traffic      : [TrafficEntry] = []
}

/// One pairing attempt (PROTOCOL.md, Pairing).
struct PairingState {
	let privateKey     : Curve25519.KeyAgreement.PrivateKey
	/// The user agreed to replace this Mac's existing pairing for the device's ID.
	let replacing      : Bool
	var deviceKey      : Data?
	var commitment     : Data?
	var macNonce       : Data?
	/// K and the code, once the deck has revealed its nonce.
	var key            : Data?
	var code           : String?
	var macConfirmed   = false
	var deckConfirmed  = false
	var timeout        : Task<Void, Never>?

	init( replacing: Bool ) {
		privateKey     = Curve25519.KeyAgreement.PrivateKey()
		self.replacing = replacing
	}
}

extension DeckController {
	/// A paired device answers the Mac's auth at once.
	static let authenticationTimeout: TimeInterval = 15
	/// A little longer than the deck's own 2 minutes, whose pairCancel explains itself.
	static let pairingTimeout: TimeInterval        = 125
	/// The connection may stay this much longer than pairingTimeout, so the timeout, which
	/// explains itself, comes first.
	static let pairingDeadlineMargin: TimeInterval = 5
	/// How often a key the Keychain couldn't read is tried again.
	static let keyRecheckInterval: Duration        = .seconds( 60 )
	static let maxNewDevices                       = 8
	private static let maxHandshakeTraffic         = 40

	/// A message on a connection that hasn't authenticated: its hello, authentication, or
	/// pairing.
	func handleHandshake( _ message: DeviceMessage, from client: ClientID, payload: Data ) {
		switch message {
			case .hello( let hello ):
				handshakes[client] = Handshake( hello: hello, helloBytes: payload, address: server.endpoint( of: client ) )
				beginAuthentication( client )

			case .auth( let proof ):
				finishAuthentication( client, proof: proof )

			case .pairResponse( let publicKey, let commitment ):
				guard var state = handshakes[client]?.pairing, state.deviceKey == nil else { return }
				guard ( try? Curve25519.KeyAgreement.PublicKey( rawRepresentation: publicKey ) ) != nil else {
					abortPairing( client, "The deck sent an invalid key." )
					return
				}
				let nonce        = DeckCrypto.randomBytes( DeckCrypto.nonceSize )
				state.deviceKey  = publicKey
				state.commitment = commitment
				state.macNonce   = nonce
				handshakes[client]?.pairing = state
				server.send( .pairNonce( nonce ), to: client )

			case .pairReveal( let nonce ):
				revealed( nonce, from: client )

			case .pairConfirm( let proof ):
				guard var state = handshakes[client]?.pairing, let key = state.key, let code = state.code else { return }
				guard DeckCrypto.equal( proof, DeckCrypto.pairConfirmProof( key: key ) ) else {
					abortPairing( client, "Pairing failed: the deck's confirmation didn't match." )
					return
				}
				state.deckConfirmed = true
				handshakes[client]?.pairing = state
				if state.macConfirmed {
					finishPairing( client )
				} else {
					setPairing( client, .compare( code: code, deckConfirmed: true ) )
				}

			case .pairCancel( let reason ):
				guard handshakes[client]?.pairing != nil else { return }
				endPairingState( client )
				setPairing( client, .failed( Self.pairCancelExplanation( reason ) ) )

			default:
				break
		}
	}

	/// What the deck's pairCancel reason means for the user.
	private static func pairCancelExplanation( _ reason: String? ) -> String {
		switch reason {
			case "deck":      "Pairing was canceled on the deck."
			case "timeout":   "The deck stopped waiting. Try again, and hold Confirm on the deck within 2 minutes."
			case "setupMode": "The deck is in setup mode. Exit setup mode on the deck, then try again."
			case "paired":    "The deck is already paired with a Mac. Use Unpair on its setup page (or forget it on that Mac), then try again."
			case "busy":      "The deck is installing firmware. Try again when it's done."
			default:          "The deck couldn't pair. Try again."
		}
	}

	// MARK: - Authentication

	/// After the hello: authenticates a device paired with this Mac, or lists it under New
	/// Devices with why it can't be used yet.
	private func beginAuthentication( _ client: ClientID ) {
		guard var handshake = handshakes[client] else { return }
		let hello = handshake.hello

		guard hello.protocolVersion >= 3, let deviceNonce = hello.nonce, deviceNonce.count == DeckCrypto.nonceSize else {
			listNewDevice( client, hello, .oldFirmware )
			return
		}
		guard hello.pairedBridge == config.settings.bridgeID, let key = PairingKeyStore.key( for: hello.id ) else {
			// Pairing needs protocol 4; firmware 3.x only authenticates with a key it already has.
			let reason: NewDevice.Reason = hello.protocolVersion < 4 ? .oldFirmware
				: hello.pairedBridge.isEmpty ? .unpaired
				: hello.pairedBridge != config.settings.bridgeID ? .pairedElsewhere : .keyMissing
			listNewDevice( client, hello, reason )
			// Still here, even though it can't be used until it's unpaired and paired again.
			if reason == .keyMissing || reason == .pairedElsewhere { server.send( .noKey, to: client ) }
			// Only when reading the key failed: when the Keychain says there's none, there's
			// nothing to wait for.
			if reason == .keyMissing && !PairingKeyStore.isMissing( hello.id ) { recheckKey( client, deviceID: hello.id ) }
			return
		}

		sendAuth( client, key: key, handshake: &handshake )
		handshakes[client] = handshake
	}

	/// A deck waiting because its key couldn't be read: the Keychain may only have failed for
	/// a while, so read it again every minute, and authenticate it if it's back.
	private func recheckKey( _ client: ClientID, deviceID: String ) {
		Task { [weak self] in
			while true {
				try? await Task.sleep( for: Self.keyRecheckInterval )
				// Stops once it's gone, or forgotten here (it'll never have a key again).
				guard let self, self.isWaitingForKey( client ), self.settings( deviceID ) != nil else { return }
				// Off the main thread: this only runs because the Keychain misbehaved.
				guard let key = await Task.detached( operation: { PairingKeyStore.read( deviceID ) } ).value else { continue }
				guard self.isWaitingForKey( client ), var handshake = self.handshakes[client] else { return }
				PairingKeyStore.remember( key, for: deviceID )
				print( "[Pairing] Found the key for \(deviceID) again; authenticating" )
				self.newDevices.removeAll { $0.client == client }
				self.sendAuth( client, key: key, handshake: &handshake )
				self.handshakes[client] = handshake
				return
			}
		}
	}

	/// Still listed as paired with this Mac, but without its key.
	private func isWaitingForKey( _ client: ClientID ) -> Bool {
		newDevices.contains { $0.client == client && $0.reason == .keyMissing }
	}

	/// Sends the Mac's proof of `key` and a fresh nonce; the device has to answer in time.
	private func sendAuth( _ client: ClientID, key: Data, handshake: inout Handshake ) {
		guard let deviceNonce = handshake.hello.nonce else { return }
		let bridgeNonce = DeckCrypto.randomBytes( DeckCrypto.nonceSize )
		handshake.key         = key
		handshake.bridgeNonce = bridgeNonce
		server.setDeadline( client, in: Self.authenticationTimeout )
		server.send( .auth( nonce: bridgeNonce, proof: DeckCrypto.bridgeProof( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce ) ), to: client )
	}

	/// Checks the device's proof. If it holds the key, the session starts and the device is
	/// adopted; otherwise the connection is dropped.
	private func finishAuthentication( _ client: ClientID, proof: Data ) {
		guard let handshake = handshakes[client], let key = handshake.key, let bridgeNonce = handshake.bridgeNonce,
			  let deviceNonce = handshake.hello.nonce else { return }

		let expected = DeckCrypto.deviceProof( key: key, bridgeNonce: bridgeNonce, deviceNonce: deviceNonce, hello: handshake.helloBytes )
		guard DeckCrypto.equal( proof, expected ) else {
			// Whoever this is doesn't have the key (or changed the hello): nothing is kept
			// about it, so it can't affect the real device.
			print( "[DeckController] A connection claiming \(handshake.hello.id) failed authentication" )
			server.drop( client )
			return
		}

		// A new pairing: the deck has stored K (our auth proved we have it), so this Mac does too.
		if let state = handshake.pairing {
			state.timeout?.cancel()
			if PairingKeyStore.store( key, for: handshake.hello.id ) {
				print( "[DeckController] Paired with \(handshake.hello.name) (\(handshake.hello.id))\(state.replacing ? ", replacing the earlier pairing" : "")" )
			} else {
				lastError = BridgeProblem( "Pairing Key Not Saved", "Couldn't save the pairing key for \(handshake.hello.name) in the Keychain. It works until it disconnects; pair it again then." )
			}
		}

		server.establishSession( client, key: DeckCrypto.sessionKey( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce ) )
		handshakes[client] = nil
		newDevices.removeAll { $0.client == client }
		adoptDevice( handshake.hello, from: client, handshakeTraffic: handshake.traffic )
	}

	/// A connection closed before authenticating. Nothing is remembered about the device ID
	/// it claimed; a note goes into the device's log only when it came from the address the
	/// device last authenticated from.
	func handshakeEnded( _ client: ClientID ) {
		if let handshake = handshakes.removeValue( forKey: client ) {
			handshake.pairing?.timeout?.cancel()
			if handshake.bridgeNonce != nil, let device = device( handshake.hello.id ), device.client == nil,
			   let address = handshake.address, address == device.lastAddress {
				logEvent( "The deck closed the connection during authentication; it may no longer accept this Mac's pairing key", device: device.id )
			}
		}
		newDevices.removeAll { $0.client == client }
	}

	/// Frames of a connection that hasn't authenticated, kept for its log (capped).
	func recordHandshakeTraffic( _ entry: TrafficEntry, client: ClientID ) {
		guard var handshake = handshakes[client], handshake.traffic.count < Self.maxHandshakeTraffic else { return }
		handshake.traffic.append( entry )
		handshakes[client] = handshake
	}

	// MARK: - Pairing

	/// This Mac already has a pairing key or settings for this device ID: pairing replaces
	/// them, which the user has to agree to first.
	func existingPairingName( for deviceID: String ) -> String? {
		if let settings = settings( deviceID ) { return settings.name }
		return PairingKeyStore.key( for: deviceID ) != nil ? deviceID : nil
	}

	/// Starts pairing. `replacing`: the user agreed to replace this Mac's existing pairing for
	/// the device's ID (existingPairingName); without that, pairing such a device does nothing.
	func pair( _ client: ClientID, replacing: Bool = false ) {
		guard var handshake = handshakes[client], handshake.hello.protocolVersion >= 4,
			  newDevices.first( where: { $0.client == client } )?.reason.canPair == true else { return }
		guard replacing || existingPairingName( for: handshake.hello.id ) == nil else { return }

		handshake.pairing?.timeout?.cancel()
		var state     = PairingState( replacing: replacing )
		state.timeout = Task { [weak self] in
			try? await Task.sleep( for: .seconds( Self.pairingTimeout ) )
			guard !Task.isCancelled, let self else { return }
			abortPairing( client, "Pairing timed out. Try again, and hold Confirm on the deck within 2 minutes." )
		}
		let publicKey      = state.privateKey.publicKey.rawRepresentation
		handshake.pairing  = state
		handshakes[client] = handshake
		server.setDeadline( client, in: Self.pairingTimeout + Self.pairingDeadlineMargin, pairing: true )
		setPairing( client, .waitingForDevice )
		server.send( .pairRequest( bridgeID: config.settings.bridgeID, bridgeName: bridgeName, publicKey: publicKey ), to: client )
	}

	/// The deck revealed its nonce: check it against the commitment, then both sides show the code.
	private func revealed( _ deviceNonce: Data, from client: ClientID ) {
		guard var handshake = handshakes[client], var state = handshake.pairing, state.key == nil,
			  let deviceKey = state.deviceKey, let commitment = state.commitment, let macNonce = state.macNonce else { return }

		let macKey = state.privateKey.publicKey.rawRepresentation
		guard DeckCrypto.equal( commitment, DeckCrypto.pairCommitment( deviceNonce: deviceNonce, devicePublicKey: deviceKey, macPublicKey: macKey ) ),
			  let theirs = try? Curve25519.KeyAgreement.PublicKey( rawRepresentation: deviceKey ),
			  let secret = try? state.privateKey.sharedSecretFromKeyAgreement( with: theirs ) else {
			abortPairing( client, "The deck's answer didn't match what it sent before, so something else may be answering for it. Pairing stopped." )
			return
		}

		let shared = secret.withUnsafeBytes { Data( $0 ) }
		let code   = DeckCrypto.pairingCode( macPublicKey: macKey, devicePublicKey: deviceKey, macNonce: macNonce, deviceNonce: deviceNonce )
		state.key  = DeckCrypto.pairingKey( sharedSecret: shared, macPublicKey: macKey, devicePublicKey: deviceKey, macNonce: macNonce,
											deviceNonce: deviceNonce, bridgeID: config.settings.bridgeID, deviceID: handshake.hello.id )
		state.code        = code
		handshake.pairing = state
		handshakes[client] = handshake
		setPairing( client, .compare( code: code, deckConfirmed: false ) )
	}

	/// The user says the deck shows the same code.
	func confirmCode( _ client: ClientID ) {
		guard var state = handshakes[client]?.pairing, let code = state.code else { return }
		state.macConfirmed = true
		handshakes[client]?.pairing = state
		if state.deckConfirmed {
			finishPairing( client )
		} else {
			setPairing( client, .confirmOnDeck( code: code ) )
		}
	}

	/// The user says the codes differ: someone may be in the middle.
	func rejectCode( _ client: ClientID ) {
		guard handshakes[client]?.pairing != nil else { return }
		abortPairing( client, "Pairing stopped because the codes didn't match. Something else on your network may have answered for this deck." )
	}

	/// The user canceled: the deck is told, and the connection waits again.
	func cancelPairing( _ client: ClientID ) {
		server.send( .pairCancel, to: client )
		endPairingState( client )
		setPairing( client, .idle )
	}

	/// Confirmed on both sides: authenticate with the new K. The deck stores K when our auth
	/// proves we have it; this Mac stores it when the deck's auth comes back.
	private func finishPairing( _ client: ClientID ) {
		guard var handshake = handshakes[client], let key = handshake.pairing?.key else { return }
		handshake.hello.pairedBridge = config.settings.bridgeID
		sendAuth( client, key: key, handshake: &handshake )
		handshakes[client] = handshake
		setPairing( client, .finishing )
	}

	/// Ends the attempt, showing why.
	private func failPairing( _ client: ClientID, _ message: String ) {
		endPairingState( client )
		setPairing( client, .failed( message ) )
	}

	/// Tells the deck pairing is off, and ends the attempt showing why.
	private func abortPairing( _ client: ClientID, _ message: String ) {
		server.send( .pairCancel, to: client )
		failPairing( client, message )
	}

	/// Forgets the attempt's keys and nonces; the connection waits for the user again.
	private func endPairingState( _ client: ClientID ) {
		handshakes[client]?.pairing?.timeout?.cancel()
		handshakes[client]?.pairing     = nil
		handshakes[client]?.key         = nil
		handshakes[client]?.bridgeNonce = nil
		server.setDeadline( client, in: nil )
	}

	/// One entry per device ID: a newer connection replaces an older one, unless that one is
	/// pairing (then the newer one is closed). The list is capped like the connections are.
	private func listNewDevice( _ client: ClientID, _ hello: DeviceHello, _ reason: NewDevice.Reason ) {
		if let other = newDevices.first( where: { $0.hello.id == hello.id && $0.client != client } ) {
			if handshakes[other.client]?.pairing != nil {
				server.drop( client )
				return
			}
			newDevices.removeAll { $0.client == other.client }
			server.drop( other.client )
		}

		if let index = newDevices.firstIndex( where: { $0.client == client } ) {
			newDevices[index].hello  = hello
			newDevices[index].reason = reason
		} else {
			guard newDevices.count < Self.maxNewDevices else {
				server.drop( client )
				return
			}
			newDevices.append( NewDevice( client: client, hello: hello, reason: reason ) )
		}
		server.setDeadline( client, in: nil )   // it waits for the user
	}

	/// Updates the New Device page's view of the attempt.
	private func setPairing( _ client: ClientID, _ pairing: NewDevice.Pairing ) {
		guard let index = newDevices.firstIndex( where: { $0.client == client } ) else { return }
		newDevices[index].pairing = pairing
	}

	/// Shown on the deck while pairing: this Mac's name, looked up once at launch, off the
	/// main thread (it can wait on DNS).
	var bridgeName: String {
		guard let host = hostName else { return "Mac" }
		return host.hasSuffix( ".local" ) ? String( host.dropLast( 6 ) ) : host
	}
}
