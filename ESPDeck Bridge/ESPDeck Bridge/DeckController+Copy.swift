//
//  DeckController+Copy.swift
//  ESPDeck Bridge
//
//  Copying a deck's settings onto another (Copy From Deck), and restoring a deck after a
//  factory reset. What the device keeps itself goes to it now if it's connected, or when it
//  next connects (BridgeSettings.pendingRestores).
//

import Foundation

extension DeckController {
	/// Decks to copy from: every other device this bridge knows, connected or not, with the
	/// most recently seen first.
	func copySources( for id: String ) -> [DeviceSettings] {
		config.settings.devices
			.filter { $0.id != id }
			.sorted { ( $0.lastSeen ?? .distantPast ) > ( $1.lastSeen ?? .distantPast ) }
	}

	/// Copies `parts` of `source` (a snapshot, so it can be the device itself) onto the device.
	func copyDeck( from source: DeviceSettings, to id: String, parts: Set<DeckCopyPart> ) {
		guard let index = config.settings.deviceIndex( id ), !parts.isEmpty else { return }

		if parts.contains( .keys ) {
			recordUndo( device: id, "Copy Deck" )
			config.settings.devices[index].pages       = source.pages.isEmpty ? [ [] ] : source.pages
			config.settings.devices[index].currentPage = min( source.currentPage, max( source.pages.count - 1, 0 ) )
			stopSliders( device: id )
		}
		if parts.contains( .display ) {
			config.settings.devices[index].labelPosition = source.labelPosition
		}
		if parts.contains( .sleep ) {
			config.settings.devices[index].sleepTriggers = source.sleepTriggers
			config.settings.devices[index].onSleep       = source.onSleep
			config.settings.devices[index].onWake        = source.onWake
		}
		if parts.contains( .keyPresses ) {
			config.settings.devices[index].repeatDelay     = source.repeatDelay
			config.settings.devices[index].repeatRate      = source.repeatRate
			config.settings.devices[index].doubleTapWindow = source.doubleTapWindow
			config.settings.devices[index].holdTime        = source.holdTime
		}
		config.removeUnusedIcons()
		assignmentsChanged( device: id )

		let onDevice = parts.filter( \.isOnDevice )
		guard !onDevice.isEmpty else { return }
		if device( id )?.isOnline == true {
			sendToDevice( source, parts: onDevice, device: id )
		} else {
			config.settings.pendingRestores[id] = PendingRestore( source: source, parts: onDevice )
		}
	}

	/// After a factory reset: what to give the device once it's set up and paired again.
	func restoreAfterReset( device id: String, from source: DeviceSettings ) {
		config.settings.pendingRestores[id] = PendingRestore( source: source, parts: Set( DeckCopyPart.allCases.filter( \.isOnDevice ) ) )
	}

	/// Settings waiting for this device, which has just connected.
	func applyPendingRestore( device id: String ) {
		guard let pending = config.settings.pendingRestores.removeValue( forKey: id ) else { return }
		logEvent( "Restoring settings from \(pending.source.name)", device: id )
		copyDeck( from: pending.source, to: id, parts: pending.parts )
	}

	private func sendToDevice( _ source: DeviceSettings, parts: Set<DeckCopyPart>, device id: String ) {
		if parts.contains( .name ), source.name != settings( id )?.name {
			rename( device: id, to: source.name )
		}
		if parts.contains( .display ) {
			setBrightness( device: id, source.brightness )
			setOrientation( device: id, source.orientation )
		}
		if parts.contains( .sleep ) {
			setSleepTimeout( device: id, seconds: source.sleepTimeout )
		}
		// Last: the device restarts to use it.
		if parts.contains( .hostname ), let current = settings( id ), source.hostname != current.hostname {
			setHostname( device: id, source.hostname )
		}
	}
}
