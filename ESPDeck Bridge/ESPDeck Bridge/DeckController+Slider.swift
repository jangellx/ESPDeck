//
//  DeckController+Slider.swift
//  ESPDeck Bridge
//
//  Slider keys: two neighbouring keys that step a light's brightness or a fan's speed up
//  and down. Both hold the same target; editing either keeps the other in step. A slider key
//  acts when pressed rather than released, and repeats while held (the device's delay and
//  rate).
//

import Foundation

extension DeckController {
	// MARK: - Pairs

	/// The levels a key's target can have adjusted (empty for anything but lights and fans).
	func sliderLevels( for assignment: KeyAssignment ) -> [SliderLevel] {
		home.levels( for: assignment )
	}

	/// Whether two keys sit side by side (rather than one above the other).
	func isHorizontalPair( device id: String, _ first: Int, _ second: Int ) -> Bool {
		let cols = max( layout( id ).cols, 1 )
		return first / cols == second / cols
	}

	/// Makes `key` and `partner` a slider pair on `key`'s target. The key above or to the
	/// right raises the level. The partner's old assignment is replaced; a previous partner of
	/// `key` is cleared.
	func makeSlider( device id: String, key: Int, partner: Int, level: SliderLevel ) {
		guard let index = config.settings.deviceIndex( id ), key != partner else { return }
		config.settings.devices[index].ensureKey( max( key, partner ) )

		let cols         = max( layout( id ).cols, 1 )
		let partnerRaises = partner / cols < key / cols || ( partner / cols == key / cols && partner % cols > key % cols )
		let style        = config.settings.sliderStyle

		var keys = config.settings.devices[index].keys
		if let old = keys[key].slider, old.partner != partner, old.partner < keys.count, keys[old.partner].slider?.partner == key {
			keys[old.partner] = KeyAssignment()
		}
		if let old = keys[partner].slider, old.partner != key, old.partner < keys.count, keys[old.partner].slider?.partner == partner {
			keys[old.partner] = KeyAssignment()
		}

		let step = keys[key].slider?.step ?? SliderLevel.defaultStep
		keys[key].slider = SliderKey( level: level, raises: !partnerRaises, partner: partner, step: step, style: keys[key].slider?.style ?? style )
		var other        = KeyAssignment()
		other.slider     = SliderKey( level: level, raises: partnerRaises, partner: key, step: step, style: keys[key].slider?.style ?? style )
		copyTarget( from: keys[key], to: &other )
		keys[partner]    = other

		config.settings.devices[index].keys = keys
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Back to an ordinary key: the partner, made for the pair, is cleared.
	func removeSlider( device id: String, key: Int ) {
		guard let index = config.settings.deviceIndex( id ), key < config.settings.devices[index].keys.count,
			  let slider = config.settings.devices[index].keys[key].slider else { return }
		config.settings.devices[index].keys[key].slider = nil
		if slider.partner < config.settings.devices[index].keys.count, config.settings.devices[index].keys[slider.partner].slider?.partner == key {
			config.settings.devices[index].keys[slider.partner] = KeyAssignment()
		}
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Changes the pair's shared settings (level, step, style) on both keys.
	func updateSlider( device id: String, key: Int, _ change: ( inout SliderKey ) -> Void ) {
		update( device: id, key: key ) { assignment in
			guard var slider = assignment.slider else { return }
			change( &slider )
			assignment.slider = slider
		}
		if let style = assignment( id, key: key ).slider?.style {
			config.settings.sliderStyle = style   // the style for the next new pair
		}
	}

	/// Which key raises and which lowers.
	func swapSliderDirection( device id: String, key: Int ) {
		guard let index = config.settings.deviceIndex( id ), key < config.settings.devices[index].keys.count,
			  let slider = config.settings.devices[index].keys[key].slider else { return }
		config.settings.devices[index].keys[key].slider?.raises.toggle()
		if slider.partner < config.settings.devices[index].keys.count, config.settings.devices[index].keys[slider.partner].slider?.partner == key {
			config.settings.devices[index].keys[slider.partner].slider?.raises.toggle()
		}
		assignmentsChanged( device: id )
	}

	/// After a key changed: its partner follows the shared parts, or is let go if the key
	/// isn't a slider (with that partner) any more. A target without the level ends the pair.
	func syncSliderPartner( device index: Int, key: Int, before: KeyAssignment ) {
		var keys = config.settings.devices[index].keys
		guard key < keys.count else { return }

		// A new target without the pair's level: another level it has, or no pair.
		if let slider = keys[key].slider {
			let levels = home.levels( for: keys[key] )
			if !levels.contains( slider.level ) && !levels.isEmpty && home.isReady {
				keys[key].slider?.level = levels[0]
			} else if levels.isEmpty && home.isReady && ( keys[key].accessoryID != before.accessoryID || keys[key].kind != before.kind ) {
				keys[key].slider = nil
			}
		}

		if let old = before.slider, old.partner < keys.count, keys[old.partner].slider?.partner == key,
		   keys[key].slider?.partner != old.partner {
			keys[old.partner] = KeyAssignment()
		}
		if let slider = keys[key].slider, slider.partner < keys.count, slider.partner != key {
			var other = keys[slider.partner]
			copyTarget( from: keys[key], to: &other )
			other.slider = SliderKey( level: slider.level, raises: other.slider.map { $0.partner == key ? $0.raises : !slider.raises } ?? !slider.raises,
									  partner: key, step: slider.step, style: slider.style )
			keys[slider.partner] = other
		}
		config.settings.devices[index].keys = keys
	}

	/// Keeps pairs pointing at each other after keys move: `moved` maps old indexes to new.
	/// A pair split by a copy that left one key out becomes two ordinary keys.
	static func remapSliders( _ keys: inout [KeyAssignment], _ moved: ( Int ) -> Int? ) {
		for index in keys.indices {
			guard let partner = keys[index].slider?.partner else { continue }
			if let target = moved( partner ), target < keys.count, target != index {
				keys[index].slider?.partner = target
			} else {
				keys[index].slider = nil
			}
		}
	}

	private func copyTarget( from source: KeyAssignment, to other: inout KeyAssignment ) {
		other.kind        = source.kind
		other.accessoryID = source.accessoryID
		other.serviceID   = source.serviceID
		other.others      = source.others
		other.action      = source.action
	}

	// MARK: - Pressing

	/// A slider key went down: one step now, then repeats after the device's delay until it
	/// comes up (or a minute passes, in case the release never arrives).
	func startSlider( device id: String, key: Int ) {
		let name = "\(id)/\(key)"
		sliderRepeats[name]?.cancel()
		guard assignment( id, key: key ).slider != nil else { return }
		stepSlider( device: id, key: key )

		let settings = settings( id )
		let delay    = settings?.repeatDelay ?? DeviceSettings.defaultRepeatDelay
		let interval = 1 / max( settings?.repeatRate ?? DeviceSettings.defaultRepeatRate, 1 )
		sliderRepeats[name] = Task { [weak self] in
			try? await Task.sleep( for: .seconds( delay ) )
			let started = Date()
			while !Task.isCancelled && Date().timeIntervalSince( started ) < 60 {
				self?.stepSlider( device: id, key: key )
				try? await Task.sleep( for: .seconds( interval ) )
			}
		}
	}

	/// The key came up: stop repeating, and log where the level ended.
	func stopSlider( device id: String, key: Int ) {
		let name = "\(id)/\(key)"
		guard let task = sliderRepeats.removeValue( forKey: name ) else { return }
		task.cancel()
		let assignment = assignment( id, key: key )
		guard let slider = assignment.slider, let ref = assignment.sliderRef else { return }
		let level = home.level( ref ).map { "\(Int( $0.rounded() ))%" } ?? "unknown"
		logEvent( "Key \(key + 1): \(slider.level.title) \(level)", device: id )
	}

	/// Every repeat of a device's keys, when it disconnects or a chord starts.
	func stopSliders( device id: String ) {
		for ( name, task ) in sliderRepeats where name.hasPrefix( "\(id)/" ) {
			task.cancel()
			sliderRepeats[name] = nil
		}
	}

	func stepSlider( device id: String, key: Int ) {
		home.adjust( assignment( id, key: key ) )
		if let error = home.takeLevelError() {
			logEvent( "Key \(key + 1) failed: \(error)", device: id )
		}
	}

	/// The level a slider key's label shows, e.g. "60%".
	func sliderLabel( for assignment: KeyAssignment ) -> String? {
		guard let ref = assignment.sliderRef else { return nil }
		return home.level( ref ).map { "\(Int( $0.rounded() ))%" }
	}
}
