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
		guard let index = config.settings.deviceIndex( id ), key != partner,
			  max( key, partner ) < config.settings.devices[index].keys.count else { return }
		recordUndo( device: id, "Make Slider" )

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
		let facing = keys[key].slider?.labelsFacing ?? true
		let toEnd  = keys[key].slider?.doubleTapToEnd ?? false
		keys[key].slider = SliderKey( level: level, raises: !partnerRaises, partner: partner, step: step, style: keys[key].slider?.style ?? style,
									  labelsFacing: facing, doubleTapToEnd: toEnd )
		var other        = KeyAssignment()
		other.slider     = SliderKey( level: level, raises: partnerRaises, partner: key, step: step, style: keys[key].slider?.style ?? style,
									  labelsFacing: facing, doubleTapToEnd: toEnd )
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
		recordUndo( device: id, "Remove Slider" )
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
		recordUndo( device: id, "Swap Slider Direction" )
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
									  partner: key, step: slider.step, style: slider.style, labelsFacing: slider.labelsFacing,
									  doubleTapToEnd: slider.doubleTapToEnd )
			keys[slider.partner] = other
		}
		config.settings.devices[index].keys = keys
	}

	/// Keeps pairs pointing at each other after keys move: `moved` maps old indexes to new.
	/// A pair split by a copy that left one key out becomes two ordinary keys.
	static func remapSliders( _ keys: inout [KeyAssignment], _ moved: ( Int ) -> Int? ) {
		for index in keys.indices {
			// A partner the deck doesn't show stays paired (by its place on the grid).
			guard let partner = keys[index].slider?.partner, partner != DeviceSettings.offscreenPartner else { continue }
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

	/// Shift-click in the deck preview: like the key on the deck, including the flash, a
	/// Level key's repeat while held, and other keys acting on release.
	func previewPress( device id: String, key: Int, down: Bool ) {
		if down {
			device( id )?.pressed.insert( key )
			if assignment( id, key: key ).slider != nil {
				startSlider( device: id, key: key )
			}
		} else {
			device( id )?.pressed.remove( key )
			if assignment( id, key: key ).slider != nil {
				stopSlider( device: id, key: key )
			} else {
				press( device: id, key: key )
			}
		}
	}

	/// A slider key went down: one step now, then repeats after the device's delay until it
	/// comes up (or a minute passes, in case the release never arrives). With `repeatHere`
	/// false the device sends keyRepeat itself, and this only waits for the release.
	func startSlider( device id: String, key: Int, repeatHere: Bool = true ) {
		let name = "\(id)/\(key)"
		sliderRepeats[name]?.cancel()
		guard assignment( id, key: key ).slider != nil else { return }
		stepSlider( device: id, key: key )
		guard repeatHere else {
			sliderRepeats[name] = Task {}   // held: stopSlider logs where it ended
			return
		}

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

// MARK: - Moving Level keys

extension DeckController {
	/// A drag that would split a Level pair (its other key can't come along), waiting for the
	/// user to choose.
	struct PendingLevelMove: Equatable {
		var device  : String
		var source  : Int
		var target  : Int
		var partner : Int
	}

	/// A key dragged onto another. Ordinary keys swap. A Level key dropped beside its partner
	/// moves alone and the pair turns to match; dropped elsewhere, the pair moves together
	/// (keys in the way swap into the places it left). If its partner would land off the deck,
	/// `pendingLevelMove` is set for the view to ask about.
	func moveKey( device id: String, from source: Int, to target: Int ) {
		guard source != target, let index = config.settings.deviceIndex( id ),
			  max( source, target ) < config.settings.devices[index].keys.count else { return }
		let keys = config.settings.devices[index].keys
		// Dropping an ordinary key on a Level key moves the Level key the other way.
		let ( moving, destination ) = isPairedSlider( keys, source ) ? ( source, target ) : isPairedSlider( keys, target ) ? ( target, source ) : ( -1, -1 )
		guard moving >= 0, let partner = keys[moving].slider?.partner else {
			swapKeys( device: id, source, target )
			return
		}

		let layout = layout( id )
		let cols   = max( layout.cols, 1 )
		func place( _ key: Int ) -> ( row: Int, col: Int ) { ( key / cols, key % cols ) }
		func beside( _ first: Int, _ second: Int ) -> Bool {
			let a = place( first ), b = place( second )
			return abs( a.row - b.row ) + abs( a.col - b.col ) == 1
		}

		if destination == partner || beside( destination, partner ) {
			// The two trade places, or this key moves round its partner.
			recordUndo( device: id, "Move Key" )
			let swapped = isSwapped( keys, moving, partner, cols: cols )
			config.settings.devices[index].keys.swapAt( moving, destination )
			Self.remapSliders( &config.settings.devices[index].keys ) { $0 == moving ? destination : $0 == destination ? moving : $0 }
			let newMoving  = destination
			let newPartner = destination == partner ? moving : partner
			orient( index: index, newMoving, newPartner, swapped: swapped, cols: cols )
			assignmentsChanged( device: id )
			return
		}

		// The pair moves as a block.
		let from = place( moving ), to = place( destination ), other = place( partner )
		let row  = other.row + to.row - from.row, col = other.col + to.col - from.col
		guard row >= 0, col >= 0, row < layout.rows, col < cols else {
			pendingLevelMove = PendingLevelMove( device: id, source: moving, target: destination, partner: partner )
			return
		}
		let partnerTarget = row * cols + col
		recordUndo( device: id, "Move Keys" )
		let swapped = isSwapped( keys, moving, partner, cols: cols )
		var moved   = keys
		config.settings.devices[index].ensureKey( partnerTarget )
		moved       = config.settings.devices[index].keys
		let old     = moved
		var mapping: [Int: Int] = [ moving: destination, partner: partnerTarget ]
		let displaced = [ destination, partnerTarget ].filter { $0 != moving && $0 != partner }
		let vacated   = [ moving, partner ].filter { $0 != destination && $0 != partnerTarget }
		for ( from, to ) in zip( displaced, vacated ) { mapping[from] = to }
		for ( from, to ) in mapping { moved[to] = old[from] }
		Self.remapSliders( &moved ) { mapping[$0] ?? $0 }
		config.settings.devices[index].keys = moved
		orient( index: index, destination, partnerTarget, swapped: swapped, cols: cols )
		assignmentsChanged( device: id )
	}

	/// After asking: move the key alone and clear its partner, which couldn't come along.
	func moveKeyClearingPartner( _ move: PendingLevelMove ) {
		guard let index = config.settings.deviceIndex( move.device ) else { return }
		recordUndo( device: move.device, "Move Key" )
		config.settings.devices[index].keys[move.partner] = KeyAssignment()
		config.settings.devices[index].keys[move.source].slider = nil
		config.settings.devices[index].keys.swapAt( move.source, move.target )
		Self.remapSliders( &config.settings.devices[index].keys ) { $0 == move.source ? move.target : $0 == move.target ? move.source : $0 }
		config.removeUnusedIcons()
		assignmentsChanged( device: move.device )
	}

	private func isPairedSlider( _ keys: [KeyAssignment], _ key: Int ) -> Bool {
		guard key < keys.count, let partner = keys[key].slider?.partner, partner < keys.count else { return false }
		return keys[partner].slider?.partner == key
	}

	/// The key above (or right) raises by default.
	private static func raisesByDefault( _ key: Int, partner: Int, cols: Int ) -> Bool {
		let row = key / cols, other = partner / cols
		return row != other ? row < other : key % cols > partner % cols
	}

	private func isSwapped( _ keys: [KeyAssignment], _ key: Int, _ partner: Int, cols: Int ) -> Bool {
		( keys[key].slider?.raises ?? true ) != Self.raisesByDefault( key, partner: partner, cols: cols )
	}

	/// Sets which key raises for the pair's new layout, keeping a swap the user made.
	private func orient( index: Int, _ key: Int, _ partner: Int, swapped: Bool, cols: Int ) {
		let raises = Self.raisesByDefault( key, partner: partner, cols: cols ) != swapped
		config.settings.devices[index].keys[key].slider?.raises     = raises
		config.settings.devices[index].keys[partner].slider?.raises = !raises
	}
}

// MARK: - Repeating on the device

extension DeckController {
	/// Firmware 4.1.0 and later repeat held keys themselves (keyRepeat), which stops the
	/// moment the key comes up, whatever the network does; older firmware leaves it to the Mac.
	static let deviceRepeatFirmware = Version( "4.1.0" )!

	func repeatsOnDevice( _ device: DeckDevice ) -> Bool {
		device.firmware.flatMap( Version.init ).map { $0 >= Self.deviceRepeatFirmware } ?? false
	}

	/// Tells the device how the keys on the page it shows report presses (which repeat, which
	/// have a double tap or a hold) and the timings; only when that changed.
	func sendRepeatKeys( device id: String ) {
		guard let device = device( id ), device.isOnline, repeatsOnDevice( device ), let settings = settings( id ) else { return }
		let keys    = settings.keys
		let message: HostMessage
		if device.status.presses == true {
			message = .keyModes( repeat: keys.indices.filter { keys[$0].slider != nil },
								 doubleTap: keys.indices.filter { keys[$0].slider.map( \.doubleTapToEnd ) ?? ( keys[$0].doubleTap != nil ) },
								 hold: keys.indices.filter { keys[$0].slider == nil && keys[$0].hold != nil },
								 delay: Int( settings.repeatDelay * 1000 ), interval: Int( 1000 / max( settings.repeatRate, 1 ) ),
								 doubleTapWindow: Int( settings.doubleTapWindow * 1000 ), holdTime: Int( settings.holdTime * 1000 ) )
		} else {
			message = .repeatKeys( keys: keys.indices.filter { keys[$0].slider != nil }, delay: Int( settings.repeatDelay * 1000 ),
								   interval: Int( 1000 / max( settings.repeatRate, 1 ) ) )
		}
		guard device.sentRepeatKeys != message else { return }
		device.sentRepeatKeys = message
		send( message, to: id )
	}
}
