//
//  DeckController+Storage.swift
//  ESPDeck Bridge
//
//  Encrypting a device's stored secrets (PROTOCOL.md, encryptStorage): firmware 4.1.0 and
//  later can encrypt its NVS (Wi-Fi password, pairing key, developer password hash) with a key
//  it burns into a one-time eFuse on the chip. That's permanent, so it only happens when the
//  user chooses it: once after pairing (Standard or Encrypted), or later on the Device page.
//

import Foundation

enum StorageEncryption: Equatable {
	/// encryptStorage was sent; the device restarts once it's done.
	case encrypting
	case failed( String )
}

extension DeckController {
	/// The first firmware that can read encrypted storage. An encrypted device must never get
	/// an older one: it would erase its settings and pairing (see sendFirmware).
	static let storageEncryptionFirmware = Version( "4.1.0" )!
	/// How long a device may take to encrypt, restart and authenticate again.
	static let storageEncryptionTimeout: TimeInterval = 60

	/// The device can encrypt its storage now: online, authenticated, and it reports plain
	/// storage (firmware 4.1.0 and later, with a free eFuse key block).
	func canEncryptStorage( _ device: DeckDevice ) -> Bool {
		guard let client = device.client, server.isAuthenticated( client ) else { return false }
		return device.status.storage == "plain" && !device.status.setupMode && device.firmwareProgress?.isActive != true
			&& storageEncryption[device.id] != .encrypting
	}

	/// After the user confirmed: the device burns its eFuse key, encrypts, and restarts.
	func encryptStorage( device id: String ) {
		storageChoicePending.remove( id )
		guard let device = device( id ), let client = device.client, canEncryptStorage( device ) else { return }
		print( "[DeckController] Encrypting the storage of \(id)" )
		logEvent( "Encrypting stored secrets", device: id )
		storageEncryption[id] = .encrypting
		server.send( .encryptStorage, to: client )

		storageEncryptionRequests[id]?.timeout.cancel()
		let timeout = Task { [weak self] in
			try? await Task.sleep( for: .seconds( Self.storageEncryptionTimeout ) )
			guard !Task.isCancelled, let self, storageEncryption[id] == .encrypting else { return }
			endStorageEncryption( id, .failed( "The device hasn't come back. If it shows up under New Devices, pair it again: its settings may have been reset." ) )
		}
		storageEncryptionRequests[id] = ( client, timeout )
	}

	/// The user chose Standard after pairing: nothing to do, and no more asking.
	func keepStandardStorage( device id: String ) {
		storageChoicePending.remove( id )
	}

	func storageStatus( _ status: DeviceMessage.StorageStatus, device: DeckDevice ) {
		switch status.state {
			case .encrypting:
				logEvent( "The device is encrypting its storage and will restart", device: device.id )
			case .error:
				let message = status.message ?? "The device couldn't encrypt its storage."
				logEvent( "Encrypting stored secrets failed: \(message)", device: device.id )
				endStorageEncryption( device.id, .failed( message ) )
		}
	}

	/// A pairing just completed: ask how to store secrets, if there's a choice to make. Its
	/// Device page asks, so show that if the user is still on the pairing page.
	func storagePaired( _ hello: DeviceHello, client: ClientID ) {
		guard hello.status.storage == "plain" else { return }
		storageChoicePending.insert( hello.id )
		if window.selection == SidebarItem.newDevice( client ) || window.selection == hello.id {
			window.selection = hello.id
			window.page      = .device
		}
	}

	/// After the restart (a new connection): did it encrypt?
	func storageReconnected( _ device: DeckDevice ) {
		guard storageEncryption[device.id] == .encrypting, let request = storageEncryptionRequests[device.id],
			  device.client != request.client else { return }
		if device.status.storage == "encrypted" {
			logEvent( "Stored secrets are encrypted", device: device.id )
			endStorageEncryption( device.id, nil )
		} else {
			endStorageEncryption( device.id, .failed( "The device restarted without encrypting its storage." ) )
		}
	}

	private func endStorageEncryption( _ id: String, _ result: StorageEncryption? ) {
		storageEncryptionRequests.removeValue( forKey: id )?.timeout.cancel()
		storageEncryption[id] = result
	}
}
