//
//  DeckController+Transfer.swift
//  ESPDeck Bridge
//
//  Moving the bridge to another Mac (File ▸ Export Bridge… and Import Bridge…). Decks only
//  talk to the bridge they're paired with: its ID and their pairing keys. An export carries
//  both, with the settings, icons and developer password, in a file BridgeTransfer encrypts;
//  importing it makes this Mac that bridge, so the decks connect here without pairing again.
//

import Foundation

extension DeckController {
	/// This Mac's bridge, for an export.
	func bridgeArchive() throws -> BridgeArchive {
		let settings = config.settings
		var keys: [String: Data] = [:]
		for id in PairingKeyStore.storedDeviceIDs().union( settings.devices.filter { !$0.isDemo }.map( \.id ) ) {
			if let key = PairingKeyStore.key( for: id ) { keys[id] = key }
		}
		let devices = settings.devices.map { BridgeArchive.Device( id: $0.id, name: $0.name, isDemo: $0.isDemo, paired: keys[$0.id] != nil ) }
		return BridgeArchive( appVersion: updates.currentAppVersion, exported: Date(), macName: bridgeName, bridgeID: settings.bridgeID,
							  devices: devices, settings: try config.settingsData(), pairingKeys: keys, developerPassword: DevOTAPassword.stored(),
							  icons: config.iconFiles(), shortcutIcons: config.shortcutIconFiles() )
	}

	/// What an import would replace here: the devices, and the pairing keys (in the Keychain,
	/// where one can outlive its device's settings).
	var bridgeContents: ( devices: Int, pairings: Int ) {
		( config.settings.devices.count, PairingKeyStore.storedDeviceIDs().count )
	}

	/// An archive's settings, read before anything on this Mac changes.
	func importableSettings( _ archive: BridgeArchive ) throws -> BridgeSettings {
		var settings: BridgeSettings
		do {
			settings = try JSONDecoder().decode( BridgeSettings.self, from: archive.settings )
		} catch {
			throw BridgeTransfer.Problem.unreadable( "its settings can't be read" )
		}
		settings.bridgeID = archive.bridgeID
		return settings
	}

	/// Makes this Mac the archive's bridge: its ID, pairing keys, settings, icons and developer
	/// password replace this Mac's, and the server starts again under the new ID.
	func importBridge( _ archive: BridgeArchive ) throws {
		let settings = try importableSettings( archive )
		let stored   = PairingKeyStore.replaceAll( with: archive.pairingKeys )
		if let password = archive.developerPassword {
			DevOTAPassword.store( password )
		} else {
			DevOTAPassword.delete()
		}
		config.replaceAll( settings: settings, icons: archive.icons, shortcutIcons: archive.shortcutIcons )
		print( "[DeckController] Imported bridge \(archive.bridgeID) from \(archive.macName): \(archive.devices.count) devices" )
		restartAsReplacedBridge()
		if !stored {
			lastError = "Some pairing keys couldn't be stored in the Keychain. Those decks show under New Devices; unpair them on the deck's setup page and pair them again."
		}
	}

	/// After an export, if asked: this Mac forgets the bridge (pairing keys, settings, icons,
	/// developer password) and starts over as a new one with no devices, so only the Mac that
	/// imports the file answers the decks. The decks aren't told anything: they stay paired
	/// with the exported bridge. This Mac's update and USB Setup preferences stay.
	func removeBridge() {
		PairingKeyStore.replaceAll( with: [:] )
		DevOTAPassword.delete()
		var fresh         = BridgeSettings()
		fresh.updates     = config.settings.updates
		fresh.usbScanning = config.settings.usbScanning
		config.replaceAll( settings: fresh, icons: [:], shortcutIcons: [:] )
		print( "[DeckController] Removed this Mac's bridge; now bridge \(fresh.bridgeID)" )
		restartAsReplacedBridge()
	}
}
