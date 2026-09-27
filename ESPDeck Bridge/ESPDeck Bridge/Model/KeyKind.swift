//
//  KeyKind.swift
//  ESPDeck Bridge
//
//  What a key can be bound to, how the bound HomeKit value maps to a display state,
//  and which actions a press can perform.
//

import HomeKit
import SwiftUI

/// Display state of a key. Icons are assigned per state; `standard` is the fallback
/// used for any state that has no icon of its own.
enum KeyState: String, Codable, CaseIterable, Identifiable {
	case standard = "default"
	case open, closed, opening, closing, stopped, obstructed
	case on, off
	case locked, unlocked, jammed
	case unknown

	var id: String { rawValue }

	/// The state a sleep trigger's "and the reverse" option watches for.
	var opposite: KeyState? {
		switch self {
			case .on:       .off
			case .off:      .on
			case .open:     .closed
			case .closed:   .open
			case .locked:   .unlocked
			case .unlocked: .locked
			default:        nil
		}
	}

	var title: String {
		switch self {
			case .standard: "Default"
			default:        rawValue.capitalized
		}
	}
}

enum KeyAction: String, Codable, CaseIterable, Identifiable {
	case none
	case toggle
	case open, close
	case turnOn, turnOff
	case lock, unlock
	case run
	case runShortcut

	var id: String { rawValue }

	var title: String {
		switch self {
			case .none:    "Nothing"
			case .toggle:  "Toggle"
			case .open:    "Open"
			case .close:   "Close"
			case .turnOn:  "Turn On"
			case .turnOff: "Turn Off"
			case .lock:    "Lock"
			case .unlock:  "Unlock"
			case .run:     "Run Scene"
			case .runShortcut: "Run Shortcut"
		}
	}
}

enum KeyKind: String, Codable, CaseIterable, Identifiable {
	case garageDoor
	case power
	case lock
	case contact
	case temperature
	case scene
	case shortcut

	var id: String { rawValue }

	var title: String {
		switch self {
			case .garageDoor:  "Garage Door"
			case .power:       "On/Off"
			case .lock:        "Lock"
			case .contact:     "Contact Sensor"
			case .temperature: "Temperature"
			case .scene:       "Scene"
			case .shortcut:    "Shortcut"
		}
	}

	/// Characteristic shown on the key. Scenes have none.
	var displayCharacteristicType: String? {
		switch self {
			case .garageDoor:  HMCharacteristicTypeCurrentDoorState
			case .power:       HMCharacteristicTypePowerState
			case .lock:        HMCharacteristicTypeCurrentLockMechanismState
			case .contact:     HMCharacteristicTypeContactState
			case .temperature: HMCharacteristicTypeCurrentTemperature
			case .scene, .shortcut: nil
		}
	}

	/// Characteristic written by actions, in the same service as the displayed one.
	var targetCharacteristicType: String? {
		switch self {
			case .garageDoor: HMCharacteristicTypeTargetDoorState
			case .power:      HMCharacteristicTypePowerState
			case .lock:       HMCharacteristicTypeTargetLockMechanismState
			default:          nil
		}
	}

	/// Characteristic that, when true, overrides the state with `obstructed`.
	var alertCharacteristicType: String? {
		self == .garageDoor ? HMCharacteristicTypeObstructionDetected : nil
	}

	/// States that can have their own icon, besides `standard`.
	var states: [KeyState] {
		switch self {
			case .garageDoor: [ .open, .closed, .opening, .closing, .stopped, .obstructed ]
			case .power:      [ .on, .off ]
			case .lock:       [ .locked, .unlocked, .jammed ]
			case .contact:    [ .open, .closed ]
			default:          []
		}
	}

	var actions: [KeyAction] {
		switch self {
			case .garageDoor:            [ .toggle, .open, .close, .none ]
			case .power:                 [ .toggle, .turnOn, .turnOff, .none ]
			case .lock:                  [ .toggle, .lock, .unlock, .none ]
			case .contact, .temperature: [ .none ]
			case .scene:                 [ .run, .none ]
			case .shortcut:              [ .runShortcut, .none ]
		}
	}

	func state( for value: Any? ) -> KeyState {
		guard let number = value as? NSNumber else {
			return self == .scene || self == .shortcut || self == .temperature ? .standard : .unknown
		}

		switch self {
			case .garageDoor:
				// HMCharacteristicValueDoorState
				switch number.intValue {
					case 0:  return .open
					case 1:  return .closed
					case 2:  return .opening
					case 3:  return .closing
					case 4:  return .stopped
					default: return .unknown
				}
			case .power:
				return number.boolValue ? .on : .off
			case .lock:
				// HMCharacteristicValueLockMechanismState
				switch number.intValue {
					case 0:  return .unlocked
					case 1:  return .locked
					case 2:  return .jammed
					default: return .unknown
				}
			case .contact:
				// 0 = contact detected (closed), 1 = not detected (open)
				return number.intValue == 0 ? .closed : .open
			case .temperature, .scene, .shortcut:
				return .standard
		}
	}

	/// "On" in the broad sense the key's Toggle uses: on, open (or opening), unlocked.
	func isActive( _ state: KeyState ) -> Bool {
		switch self {
			case .garageDoor: state == .open || state == .opening
			case .power:      state == .on
			case .lock:       state != .locked
			default:          false
		}
	}

	/// The value that turns this kind on (open, unlock) or off (close, lock).
	func targetValue( activate: Bool ) -> Any? {
		switch self {
			case .garageDoor: activate ? 0 : 1
			case .power:      activate
			case .lock:       activate ? 0 : 1
			default:          nil
		}
	}

	/// Whether an action turns things on, off, or depends on the current state (nil).
	static func activates( _ action: KeyAction ) -> Bool? {
		switch action {
			case .turnOn, .open, .unlock:  true
			case .turnOff, .close, .lock: false
			default:                       nil
		}
	}

	/// Value to write to `targetCharacteristicType` for an action, given the current display state.
	func targetValue( for action: KeyAction, current: KeyState ) -> Any? {
		switch ( self, action ) {
			case ( .garageDoor, .open ):   return 0
			case ( .garageDoor, .close ):  return 1
			case ( .garageDoor, .toggle ): return current == .open || current == .opening ? 1 : 0
			case ( .power, .turnOn ):      return true
			case ( .power, .turnOff ):     return false
			case ( .power, .toggle ):      return current != .on
			case ( .lock, .unlock ):       return 0
			case ( .lock, .lock ):         return 1
			case ( .lock, .toggle ):       return current == .locked ? 0 : 1
			default:                       return nil
		}
	}

	/// SF Symbol drawn when no icon has been assigned.
	func symbol( for state: KeyState ) -> String {
		switch ( self, state ) {
			case ( .garageDoor, .open ), ( .garageDoor, .opening ), ( .garageDoor, .closing ): "door.garage.open"
			case ( .garageDoor, .closed ):                                                    "door.garage.closed"
			case ( .garageDoor, .stopped ), ( .garageDoor, .obstructed ):                      "door.garage.open.trianglebadge.exclamationmark"
			case ( .garageDoor, .unknown ):                                                   "door.garage.closed.trianglebadge.exclamationmark"
			case ( .garageDoor, _ ):                                                          "door.garage.closed"
			case ( .power, .on ):                                                             "lightbulb.fill"
			case ( .power, _ ):                                                               "lightbulb"
			case ( .lock, .unlocked ):                                                        "lock.open.fill"
			case ( .lock, .jammed ):                                                          "lock.trianglebadge.exclamationmark.fill"
			case ( .lock, _ ):                                                                "lock.fill"
			case ( .contact, .open ):                                                         "door.left.hand.open"
			case ( .contact, _ ):                                                             "door.left.hand.closed"
			case ( .temperature, _ ):                                                         "thermometer.medium"
			case ( .scene, _ ):                                                               "sparkles"
			case ( .shortcut, _ ):                                                            "square.2.layers.3d"
		}
	}

	/// Arrow drawn inside the open garage door symbol while the door moves.
	func doorArrow( for state: KeyState ) -> String? {
		guard self == .garageDoor else { return nil }
		switch state {
			case .opening: return "arrow.up"
			case .closing: return "arrow.down"
			default:       return nil
		}
	}

	/// Garage doors stay white; their open/closed/warning symbols carry the state.
	func tint( for state: KeyState ) -> Color {
		switch ( self, state ) {
			case ( .garageDoor, _ ):   .white
			case ( .power, .on ):      Color( red: 1, green: 0.76, blue: 0.18 )   // amber
			case ( _, .unknown ):      .gray
			case ( _, .jammed ):       .red
			case ( _, .unlocked ), ( _, .open ): .orange
			case ( _, .locked ), ( _, .closed ): .green
			default:                   .white
		}
	}
}
