//
//  DeckController+Firmware.swift
//  ESPDeck Bridge
//
//  Streams a firmware image to an ESP32 over its authenticated connection, one chunk
//  at a time (PROTOCOL.md, Firmware frame). UpdateManager downloads and verifies release
//  images; development images come from a file the user picks. Firmware 4.0.0 and later
//  refuses an image older than the one it runs unless it's told the user asked for it. A
//  device with encrypted storage never gets firmware older than 4.1.0, which can't read it.
//

import CryptoKit
import Foundation

extension DeckController {
	static let firmwareChunkSize = 16 * 1024

	/// allowDowngrade: the user chose this image, so the device may install it even if it's
	/// older than what it runs.
	func sendFirmware( device id: String, image: Data, version: String, allowDowngrade: Bool = false ) {
		guard let device = device( id ), let client = device.client, server.isAuthenticated( client ) else { return }
		guard !device.status.setupMode else {
			device.firmwareProgress = FirmwareProgress( version: version, phase: .failed( "Leave setup mode first." ) )
			return
		}
		// Older firmware can't read encrypted storage: it would erase the device's Wi-Fi
		// settings, name and pairing, and store new ones unencrypted.
		if device.status.storage == "encrypted", let new = Version( version ), new < Self.storageEncryptionFirmware {
			device.firmwareProgress = FirmwareProgress( version: version, phase: .failed(
				"This device's stored secrets are encrypted, which firmware before \(Self.storageEncryptionFirmware) can't read. Installing \(version) would erase its Wi-Fi settings and pairing." ) )
			return
		}

		print( "[DeckController] Updating \(id) to firmware \(version) (\(image.count) bytes)" )
		let build = ( try? FirmwareImage.appInfo( image ) )?.elfSHA256
		device.firmwareImage    = image
		device.firmwareChunkEnd = nil
		device.firmwareProgress = FirmwareProgress( version: version, build: build, phase: .sending( sent: 0, total: image.count ) )
		let digest = Data( SHA256.hash( data: image ) ).hex
		server.send( .firmwareBegin( version: version, size: image.count, sha256: digest, allowDowngrade: allowDowngrade ), to: client )
	}

	/// The device's answers drive the transfer, but only forward: `ready` once, then a
	/// `progress` for exactly the end of the chunk just sent.
	func firmwareStatus( _ status: DeviceMessage.FirmwareStatus, device: DeckDevice, client: ClientID ) {
		guard var progress = device.firmwareProgress, let image = device.firmwareImage else { return }

		switch status.state {
			case .ready:
				guard device.firmwareChunkEnd == nil else {
					failFirmware( device, "The device restarted the transfer unexpectedly." )
					return
				}
				sendChunk( image, from: 0, device: device, client: client )
			case .progress:
				guard let received = status.received, let expected = device.firmwareChunkEnd, received == expected, received <= image.count else {
					failFirmware( device, "The device reported progress that doesn't match what was sent." )
					return
				}
				progress.phase = .sending( sent: received, total: image.count )
				if received == image.count {
					server.send( .firmwareEnd, to: client )
					progress.phase          = .installing
					device.firmwareChunkEnd = nil
				} else {
					sendChunk( image, from: received, device: device, client: client )
				}
			case .installed:
				progress.phase = .restarting
				device.firmwareImage    = nil
				device.firmwareChunkEnd = nil
			case .error:
				progress.phase = .failed( status.message ?? "The device reported an error." )
				device.firmwareImage    = nil
				device.firmwareChunkEnd = nil
		}
		device.firmwareProgress = progress
	}

	private func sendChunk( _ image: Data, from offset: Int, device: DeckDevice, client: ClientID ) {
		guard ( 0..<image.count ).contains( offset ) else { return }
		let end = min( offset + Self.firmwareChunkSize, image.count )
		device.firmwareChunkEnd = end
		server.sendFirmwareChunk( offset: offset, chunk: image.subdata( in: offset..<end ), to: client )
	}

	private func failFirmware( _ device: DeckDevice, _ message: String ) {
		device.firmwareProgress?.phase = .failed( message )
		device.firmwareImage    = nil
		device.firmwareChunkEnd = nil
	}

	/// Sends a development image (from a file) that FirmwareImage has checked is ESPDeck's.
	/// The user picked it and confirmed installing it, so it may be older than what runs.
	func sendLocalFirmware( device id: String, image: Data, info: FirmwareImage.AppInfo ) {
		guard device( id )?.firmwareProgress?.isActive != true else { return }
		sendFirmware( device: id, image: image, version: info.version, allowDowngrade: true )
	}

	/// After an update restarts the device: success if it now runs the new image. A
	/// development build can have the version the device ran before, so when the device
	/// reports its build, that decides.
	func firmwareReconnected( _ device: DeckDevice ) {
		guard let progress = device.firmwareProgress else { return }
		switch progress.phase {
			case .restarting, .installing:
				if progress.isRunning( on: device ) {
					device.firmwareProgress = nil
				} else if device.firmware == progress.version {
					device.firmwareProgress?.phase = .failed( "The device restarted on its previous build of \(progress.version); the update was rolled back." )
				} else {
					device.firmwareProgress?.phase = .failed( "The device restarted on firmware \(device.firmware ?? "?"); the update was rolled back." )
				}
			case .sending, .downloading:
				device.firmwareProgress?.phase = .failed( "The connection dropped during the update." )
				device.firmwareImage    = nil
				device.firmwareChunkEnd = nil
			case .failed:
				break
		}
	}

	func firmwareDisconnected( _ device: DeckDevice ) {
		if case .installing = device.firmwareProgress?.phase {
			device.firmwareProgress?.phase = .restarting
		}
	}
}
