//
//  DeckController+Pairing.swift
//  ESPDeck Bridge
//
//  The unauthenticated part of a connection: the authentication handshake for paired
//  devices, and pairing for new ones (PROTOCOL.md, Security).
//

import CryptoKit
import Foundation

/// A connected device that hasn't authenticated.
struct NewDevice: Identifiable {
	enum Reason {
		case unpaired
		case pairedElsewhere
		case keyRejected
		case oldFirmware

		var explanation: String {
			switch self {
				case .unpaired:        "Not paired yet."
				case .pairedElsewhere: "Paired with a different ESPDeck Bridge. Pairing it here moves it to this Mac. (While that other Mac is running, the deck connects to it instead; forget it there first, or use Unpair on the deck's setup page.)"
				case .keyRejected:     "Its pairing with this Mac didn't check out. Pair it again."
				case .oldFirmware:     "Its firmware is too old for secure connections. Update it over USB."
			}
		}
	}

	enum Pairing: Equatable {
		case idle
		case waitingForDevice
		case confirmOnDeck( code: String )
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
	var key          : Data?
	var bridgeNonce  : Data?
	var pairingKey   : Curve25519.KeyAgreement.PrivateKey?
	var sharedSecret : Data?
}

extension DeckController {
	func handleHandshake( _ message: DeviceMessage, from client: ClientID, payload: Data ) {
		switch message {
			case .hello( let hello ):
				handshakes[client] = Handshake( hello: hello, helloBytes: payload )
				beginAuthentication( client )

			case .auth( let proof ):
				finishAuthentication( client, proof: proof )

			case .pairResponse( let publicKey ):
				guard var handshake = handshakes[client], let privateKey = handshake.pairingKey,
					  let theirs = try? Curve25519.KeyAgreement.PublicKey( rawRepresentation: publicKey ),
					  let secret = try? privateKey.sharedSecretFromKeyAgreement( with: theirs ) else {
					setPairing( client, .failed( "The deck sent an invalid key." ) )
					return
				}
				let z = secret.withUnsafeBytes { Data( $0 ) }
				handshake.sharedSecret = z
				handshakes[client]     = handshake
				setPairing( client, .confirmOnDeck( code: DeckCrypto.pairingCode( sharedSecret: z ) ) )

			case .pairConfirm( let proof ):
				guard var handshake = handshakes[client], let z = handshake.sharedSecret else { return }
				let key = DeckCrypto.pairingKey( sharedSecret: z, bridgeID: config.settings.bridgeID, deviceID: handshake.hello.id )
				guard DeckCrypto.equal( proof, DeckCrypto.pairConfirmProof( key: key ) ) else {
					setPairing( client, .failed( "Pairing failed: the deck's confirmation didn't match." ) )
					return
				}
				guard PairingKeyStore.store( key, for: handshake.hello.id ) else {
					setPairing( client, .failed( "Couldn't save the pairing key in the Keychain." ) )
					return
				}
				print( "[DeckController] Paired with \(handshake.hello.name) (\(handshake.hello.id))" )
				rejectedKeys.remove( handshake.hello.id )
				handshake.hello.pairedBridge = config.settings.bridgeID
				handshake.pairingKey         = nil
				handshake.sharedSecret       = nil
				handshakes[client]           = handshake
				beginAuthentication( client )

			case .pairCancel:
				// Also how the deck refuses, e.g. while it's in setup mode.
				setPairing( client, .failed( "The deck cancelled pairing. If it's in setup mode, exit setup mode and try again." ) )

			default:
				break
		}
	}

	// MARK: - Authentication

	private func beginAuthentication( _ client: ClientID ) {
		guard var handshake = handshakes[client] else { return }
		let hello = handshake.hello

		guard hello.protocolVersion >= 3, let deviceNonce = hello.nonce, deviceNonce.count == DeckCrypto.nonceSize else {
			listNewDevice( client, hello, .oldFirmware )
			return
		}
		guard hello.pairedBridge == config.settings.bridgeID, !rejectedKeys.contains( hello.id ),
			  let key = PairingKeyStore.key( for: hello.id ) else {
			let reason: NewDevice.Reason = hello.pairedBridge.isEmpty ? .unpaired
				: hello.pairedBridge != config.settings.bridgeID ? .pairedElsewhere : .keyRejected
			listNewDevice( client, hello, reason )
			return
		}

		let bridgeNonce = DeckCrypto.randomBytes( DeckCrypto.nonceSize )
		handshake.key         = key
		handshake.bridgeNonce = bridgeNonce
		handshakes[client]    = handshake
		server.send( .auth( nonce: bridgeNonce, proof: DeckCrypto.bridgeProof( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce ) ), to: client )
	}

	private func finishAuthentication( _ client: ClientID, proof: Data ) {
		guard let handshake = handshakes[client], let key = handshake.key, let bridgeNonce = handshake.bridgeNonce,
			  let deviceNonce = handshake.hello.nonce else { return }

		let expected = DeckCrypto.deviceProof( key: key, bridgeNonce: bridgeNonce, deviceNonce: deviceNonce, hello: handshake.helloBytes )
		guard DeckCrypto.equal( proof, expected ) else {
			print( "[DeckController] \(handshake.hello.id) failed authentication" )
			rejectedKeys.insert( handshake.hello.id )
			server.drop( client )
			return
		}

		server.establishSession( client, key: DeckCrypto.sessionKey( key: key, deviceNonce: deviceNonce, bridgeNonce: bridgeNonce ) )
		handshakes[client] = nil
		newDevices.removeAll { $0.client == client }
		adoptDevice( handshake.hello, from: client )
	}

	/// A connection closed before authenticating. If the device rejected our proof (it
	/// closes instead of answering), stop offering this key until it's paired again.
	func handshakeEnded( _ client: ClientID ) {
		if let handshake = handshakes.removeValue( forKey: client ), handshake.bridgeNonce != nil {
			print( "[DeckController] \(handshake.hello.id) closed during authentication" )
			rejectedKeys.insert( handshake.hello.id )
		}
		newDevices.removeAll { $0.client == client }
	}

	// MARK: - Pairing

	/// Starts pairing; the deck then shows a code to compare, and the user confirms on it.
	func pair( _ client: ClientID ) {
		guard var handshake = handshakes[client] else { return }
		let privateKey = Curve25519.KeyAgreement.PrivateKey()
		handshake.pairingKey   = privateKey
		handshake.sharedSecret = nil
		handshakes[client]     = handshake
		setPairing( client, .waitingForDevice )
		server.send( .pairRequest( bridgeID: config.settings.bridgeID, bridgeName: Self.bridgeName,
								   publicKey: privateKey.publicKey.rawRepresentation ), to: client )
	}

	func cancelPairing( _ client: ClientID ) {
		server.send( .pairCancel, to: client )
		handshakes[client]?.pairingKey   = nil
		handshakes[client]?.sharedSecret = nil
		setPairing( client, .idle )
	}

	private func listNewDevice( _ client: ClientID, _ hello: DeviceHello, _ reason: NewDevice.Reason ) {
		if let index = newDevices.firstIndex( where: { $0.client == client } ) {
			newDevices[index].hello  = hello
			newDevices[index].reason = reason
		} else {
			newDevices.append( NewDevice( client: client, hello: hello, reason: reason ) )
		}
	}

	private func setPairing( _ client: ClientID, _ pairing: NewDevice.Pairing ) {
		guard let index = newDevices.firstIndex( where: { $0.client == client } ) else { return }
		newDevices[index].pairing = pairing
	}

	/// Shown on the deck while pairing.
	static var bridgeName: String {
		let host = ProcessInfo.processInfo.hostName
		return host.hasSuffix( ".local" ) ? String( host.dropLast( 6 ) ) : host
	}
}
