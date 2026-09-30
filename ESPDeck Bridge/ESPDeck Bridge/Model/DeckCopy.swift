//
//  DeckCopy.swift
//  ESPDeck Bridge
//
//  Copying one deck's settings to another, or back to itself after a factory reset: which
//  parts, and settings kept for a device until it next connects. Nothing secret is copied
//  (pairing keys, Wi-Fi passwords and the developer password never leave where they are).
//

import Foundation

/// A part of a deck's settings that can be copied on its own.
enum DeckCopyPart: String, Codable, CaseIterable, Identifiable {
	case keys
	case name
	case hostname
	case display
	case sleep
	case keyPresses

	var id: String { rawValue }

	var title: String {
		switch self {
			case .keys:       "Keys and pages"
			case .name:       "Device name"
			case .hostname:   "Network name"
			case .display:    "Display"
			case .sleep:      "Sleep"
			case .keyPresses: "Key presses"
		}
	}

	/// What the part covers, under its title.
	var detail: String {
		switch self {
			case .keys:       "Every page, with icons, labels and actions."
			case .name:       "What the deck is called here and on its screens."
			case .hostname:   "How it shows up on your network. Two devices with the same name there conflict."
			case .display:    "Brightness, orientation and where labels go."
			case .sleep:      "The sleep timer, triggers, and the On Sleep and On Wake commands."
			case .keyPresses: "Double-tap speed, hold time, and how held Level keys repeat."
		}
	}

	/// Kept by the device itself, so they need it connected (or wait until it is).
	var isOnDevice: Bool {
		switch self {
			case .name, .hostname, .display, .sleep: true
			case .keys, .keyPresses:                 false
		}
	}

	/// Checked at first when copying from another deck: not its identity.
	static let fromAnother: Set<DeckCopyPart> = [ .keys, .display, .sleep, .keyPresses ]
}

/// Settings waiting for a device to connect: a copy of the source as it was when chosen.
struct PendingRestore: Codable, Equatable {
	var source : DeviceSettings
	var parts  : Set<DeckCopyPart>
}
