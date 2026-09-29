//
//  SliderKey.swift
//  ESPDeck Bridge
//
//  Two keys that step a level (a light's brightness, a fan's speed) up and down. Each key of
//  the pair holds the same target, its own direction, and the other key's index; holding
//  either repeats it.
//

import HomeKit

/// What a pair of slider keys adjusts.
enum SliderLevel: String, Codable, CaseIterable, Identifiable {
	case brightness
	case fanSpeed

	var id: String { rawValue }

	var title: String {
		switch self {
			case .brightness: "Brightness"
			case .fanSpeed:   "Fan Speed"
		}
	}

	var characteristicType: String {
		switch self {
			case .brightness: HMCharacteristicTypeBrightness
			case .fanSpeed:   HMCharacteristicTypeRotationSpeed
		}
	}

	/// Both are percentages in HomeKit.
	static let defaultStep = 10.0
	static let stepRange   = 1.0...50.0
}

/// The symbols a pair of slider keys shows: the key that raises the level points up (or
/// right, for keys side by side), the other down (or left). The last one chosen is used for
/// new pairs.
enum SliderStyle: String, Codable, CaseIterable, Identifiable {
	case chevron
	case chevronCircle
	case arrow
	case arrowCircle
	case triangle
	case plusMinus
	case plusMinusCircle
	case sun

	var id: String { rawValue }

	func symbol( raises: Bool, horizontal: Bool ) -> String {
		let direction = horizontal ? ( raises ? "right" : "left" ) : ( raises ? "up" : "down" )
		return switch self {
			case .chevron:         "chevron.\(direction)"
			case .chevronCircle:   "chevron.\(direction).circle.fill"
			case .arrow:           "arrow.\(direction)"
			case .arrowCircle:     "arrow.\(direction).circle.fill"
			case .triangle:        "arrowtriangle.\(direction).fill"
			case .plusMinus:       raises ? "plus" : "minus"
			case .plusMinusCircle: raises ? "plus.circle.fill" : "minus.circle.fill"
			case .sun:             raises ? "sun.max.fill" : "sun.min.fill"
		}
	}
}

struct SliderKey: Codable, Equatable {
	var level   : SliderLevel
	/// This key raises the level; its partner lowers it (or the other way round).
	var raises  : Bool
	/// The other key of the pair.
	var partner : Int
	/// How far one press (or one repeat) moves the level, in percent.
	var step    = SliderLevel.defaultStep
	var style   = SliderStyle.chevron
	/// Keys one above the other: labels on the edges facing each other (the upper key's at its
	/// bottom, the lower's at its top), rather than where the deck puts every label.
	var labelsFacing = true
	/// A double tap goes all the way (100% on the raising key, 0% on the other). Off by
	/// default: tapping quickly to step would trigger it.
	var doubleTapToEnd = false

	init( level: SliderLevel, raises: Bool, partner: Int, step: Double = SliderLevel.defaultStep, style: SliderStyle = .chevron, labelsFacing: Bool = true,
		  doubleTapToEnd: Bool = false ) {
		self.doubleTapToEnd = doubleTapToEnd
		self.level        = level
		self.raises       = raises
		self.partner      = partner
		self.step         = step
		self.style        = style
		self.labelsFacing = labelsFacing
	}

	/// Missing or unreadable settings (from an earlier version) take their defaults; only the
	/// level, direction and partner are needed.
	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		level        = try container.decode( SliderLevel.self, forKey: .level )
		raises       = try container.decode( Bool.self, forKey: .raises )
		partner      = try container.decode( Int.self, forKey: .partner )
		step         = container.lenient( Double.self, forKey: .step ) ?? SliderLevel.defaultStep
		style        = container.lenient( SliderStyle.self, forKey: .style ) ?? .chevron
		labelsFacing = container.lenient( Bool.self, forKey: .labelsFacing ) ?? true
		doubleTapToEnd = container.lenient( Bool.self, forKey: .doubleTapToEnd ) ?? false
	}
}
