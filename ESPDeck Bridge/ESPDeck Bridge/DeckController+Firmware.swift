//
//  DeckController+Firmware.swift
//  ESPDeck Bridge
//
//  Streams a firmware image to an ESP32 over its authenticated connection, one chunk
//  at a time (PROTOCOL.md, Firmware frame). UpdateManager downloads and verifies it.
//

import CryptoKit
import Foundation

extension DeckController {
	static let firmwareChunkSize = 16 * 1024

	func sendFirmware( device id: String, image: Data, version: String ) {
		guard let device = device( id ), let client = device.client, server.isAuthenticated( client ) else { return }
		guard !device.status.setupMode else {
			device.firmwareProgress = FirmwareProgress( version: version, phase: .failed( "Leave setup mode first." ) )
			return
		}

		print( "[DeckController] Updating \(id) to firmware \(version) (\(image.count) bytes)" )
		device.firmwareImage    = image
		device.firmwareProgress = FirmwareProgress( version: version, phase: .sending( sent: 0, total: image.count ) )
		let digest = Data( SHA256.hash( data: image ) ).hex
		server.send( .firmwareBegin( version: version, size: image.count, sha256: digest ), to: client )
	}

	func firmwareStatus( _ status: DeviceMessage.FirmwareStatus, device: DeckDevice, client: ClientID ) {
		guard var progress = device.firmwareProgress, let image = device.firmwareImage else { return }

		switch status.state {
			case .ready:
				sendChunk( image, from: 0, to: client )
			case .progress:
				let received = status.received ?? 0
				progress.phase = .sending( sent: received, total: image.count )
				if received >= image.count {
					server.send( .firmwareEnd, to: client )
					progress.phase = .installing
				} else {
					sendChunk( image, from: received, to: client )
				}
			case .installed:
				progress.phase = .restarting
				device.firmwareImage = nil
			case .error:
				progress.phase = .failed( status.message ?? "The device reported an error." )
				device.firmwareImage = nil
		}
		device.firmwareProgress = progress
	}

	private func sendChunk( _ image: Data, from offset: Int, to client: ClientID ) {
		let end = min( offset + Self.firmwareChunkSize, image.count )
		server.sendFirmwareChunk( offset: offset, chunk: image.subdata( in: offset..<end ), to: client )
	}

	/// After an update restarts the device: success if it now runs the new version.
	func firmwareReconnected( _ device: DeckDevice ) {
		guard let progress = device.firmwareProgress else { return }
		switch progress.phase {
			case .restarting, .installing:
				if device.firmware == progress.version {
					device.firmwareProgress = nil
				} else {
					device.firmwareProgress?.phase = .failed( "The device restarted on firmware \(device.firmware ?? "?"); the update was rolled back." )
				}
			case .sending, .downloading:
				device.firmwareProgress?.phase = .failed( "The connection dropped during the update." )
				device.firmwareImage = nil
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
