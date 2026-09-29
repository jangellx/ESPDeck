//
//  HomeObserver.swift
//  ESPDeck Bridge
//
//  Controller-side HomeKit: lists what keys can be bound to, observes the characteristics
//  the key assignments name, and performs key actions. It covers every Home at once:
//  accessory, service and scene IDs are unique across Homes, so a key finds its target
//  wherever it is, and one key can control accessories from different Homes.
//

import HomeKit
import Observation

/// Something a key can be bound to, for the configuration UI.
struct HomeTarget: Identifiable, Hashable {
	var kind        : KeyKind
	var accessoryID : UUID?
	var serviceID   : UUID?
	var actionSetID : UUID?
	var shortcutID  : String? = nil
	var name        : String
	/// Room for accessories, folder for shortcuts.
	var room        : String?
	/// The Home an accessory or scene is in.
	var home        : String? = nil

	var id: String {
		[ kind.rawValue, accessoryID?.uuidString, serviceID?.uuidString, actionSetID?.uuidString, shortcutID ]
			.compactMap { $0 }
			.joined( separator: "/" )
	}

	func matches( _ assignment: KeyAssignment ) -> Bool {
		assignment.kind        == kind        &&
		assignment.accessoryID == accessoryID &&
		assignment.serviceID   == serviceID   &&
		assignment.actionSetID == actionSetID &&
		assignment.shortcutID  == shortcutID
	}
}

enum HomeActionError: LocalizedError {
	case noHome
	case notFound
	case unsupported
	case failed( String )

	var errorDescription: String? {
		switch self {
			case .noHome:      "No HomeKit home is available."
			case .notFound:    "The accessory or scene for this key no longer exists."
			case .unsupported: "This key has no action for its accessory."
			case .failed( let message ): message
		}
	}
}

@Observable
final class HomeObserver: NSObject {
	@ObservationIgnored private let homeManager = HMHomeManager()

	private(set) var homes         : [HMHome] = []
	private(set) var authorization : HMHomeManagerAuthorizationStatus = []
	/// Latest known value of each watched characteristic.
	private(set) var values        : [CharacteristicRef: Any] = [:] {
		didSet { noteDoorMotion() }
	}
	/// For each garage door, whether it was last seen going up (opening or open) rather than
	/// down. HomeKit reports a door stopped mid-way as just "stopped", so Toggle uses this to
	/// reverse it, as a garage remote's button does.
	@ObservationIgnored private var doorWasOpening: [CharacteristicRef: Bool] = [:]

	/// Called when a watched value or reachability changes.
	@ObservationIgnored var onChange       : ( ( CharacteristicRef ) -> Void )?
	/// Called when the set of homes, accessories, or scenes changes.
	@ObservationIgnored var onHomesChanged : ( () -> Void )?
	/// Called once, when the home has loaded and every watched value has been read.
	@ObservationIgnored var onReady        : ( () -> Void )?
	private(set) var isReady = false

	/// Several Homes: pickers and subtitles then name the Home too.
	var hasSeveralHomes: Bool { homes.count > 1 }

	@ObservationIgnored private var wanted              : Set<CharacteristicRef> = []
	@ObservationIgnored private var watched             : [( ref: CharacteristicRef, characteristic: HMCharacteristic )] = []
	@ObservationIgnored private var observedAccessories : [HMAccessory] = []
	@ObservationIgnored private var observedHomes       : [HMHome] = []
	@ObservationIgnored private var rebuildTask         : Task<Void, Never>?
	@ObservationIgnored private var rebuildPending      = false
	/// Slider keys: the level being written to each characteristic, and which have a write
	/// under way.
	@ObservationIgnored private var levelGoals          : [CharacteristicRef: Double] = [:]
	@ObservationIgnored private var levelWriters        : Set<CharacteristicRef> = []
	@ObservationIgnored private var levelError          : String?

	override init() {
		super.init()
		authorization        = homeManager.authorizationStatus
		homeManager.delegate = self
	}

	// MARK: - Watching

	/// Observes exactly these characteristics, replacing whatever was watched before.
	func watch( _ refs: Set<CharacteristicRef> ) {
		guard refs != wanted else { return }
		wanted = refs
		requestRebuild()
	}

	func isReachable( _ ref: CharacteristicRef ) -> Bool {
		accessory( ref.accessoryID )?.isReachable ?? false
	}

	/// An accessory in any Home.
	func accessory( _ id: UUID? ) -> HMAccessory? {
		guard let id else { return nil }
		for home in homes {
			if let accessory = home.accessories.first( where: { $0.uniqueIdentifier == id } ) { return accessory }
		}
		return nil
	}

	/// A scene, and the Home that runs it.
	func actionSet( _ id: UUID? ) -> ( home: HMHome, actionSet: HMActionSet )? {
		guard let id else { return nil }
		for home in homes {
			if let actionSet = home.actionSets.first( where: { $0.uniqueIdentifier == id } ) { return ( home, actionSet ) }
		}
		return nil
	}

	/// Rebuilds run one at a time, and requests made while one is waiting collapse into it.
	private func requestRebuild() {
		guard !rebuildPending else { return }
		rebuildPending = true

		let previous = rebuildTask
		rebuildTask = Task {
			await previous?.value
			rebuildPending = false
			await rebuild()
		}
	}

	private func rebuild() async {
		// Keep the values while re-reading them: clearing them would briefly render every key
		// as "unknown", and that image would be sent to the deck too.
		await stopWatching( keepingValues: true )

		for home in homes {
			home.delegate = self
			observedHomes.append( home )
		}

		for ref in wanted {
			guard let accessory      = self.accessory( ref.accessoryID ),
				  let characteristic = Self.characteristic( ref.characteristicType, serviceID: ref.serviceID, in: accessory ) else {
				print( "[HomeObserver] Not found: \(ref)" )
				continue
			}

			if !observedAccessories.contains( accessory ) {
				accessory.delegate = self
				observedAccessories.append( accessory )
			}

			watched.append( ( ref, characteristic ) )
			do {
				try await characteristic.enableNotification( true )
				try await characteristic.readValue()   // initial snapshot
			} catch {
				print( "[HomeObserver] Failed to observe \(accessory.name): \(error)" )
			}
			values[ref] = characteristic.value
			onChange?( ref )
		}

		for ref in values.keys where !wanted.contains( ref ) {
			values[ref] = nil
		}
		if !isReady {
			isReady = true
			onReady?()
		}
	}

	func stopWatching( keepingValues: Bool = false ) async {
		let characteristics = watched.map( \.characteristic )
		watched.removeAll()
		if !keepingValues { values.removeAll() }

		for characteristic in characteristics {
			try? await characteristic.enableNotification( false )
		}
		for accessory in observedAccessories {
			accessory.delegate = nil
		}
		observedAccessories.removeAll()
		for home in observedHomes {
			home.delegate = nil
		}
		observedHomes.removeAll()
	}

	private static func characteristic( _ type: String, serviceID: UUID?, in accessory: HMAccessory ) -> HMCharacteristic? {
		accessory.services
			.filter { serviceID == nil || $0.uniqueIdentifier == serviceID }
			.lazy
			.compactMap { $0.characteristics.first { $0.characteristicType == type } }
			.first
	}

	// MARK: - Targets

	/// Everything in every Home a key can be bound to, by Home, then room, then name.
	func targets() -> [HomeTarget] {
		var result: [HomeTarget] = []
		for home in homes.sorted( by: { $0.name.localizedStandardCompare( $1.name ) == .orderedAscending } ) {
			result += targets( in: home )
		}
		return result
	}

	private func targets( in home: HMHome ) -> [HomeTarget] {
		var result: [HomeTarget] = []

		for accessory in home.accessories {
			for service in accessory.services {
				let types = Set( service.characteristics.map( \.characteristicType ) )
				for kind in KeyKind.allCases {
					guard let type = kind.displayCharacteristicType, types.contains( type ) else { continue }
					// Active also switches TVs, purifiers and valves: a fan here is something with a
					// speed and no On (which makes it an On/Off target already).
					if kind == .fan && ( !types.contains( HMCharacteristicTypeRotationSpeed ) || types.contains( HMCharacteristicTypePowerState ) ) {
						continue
					}

					// "Garage Lift Side Door" rather than "Garage Lift Side Door – Lift Side Door".
					let serviceName = service.name
					let name: String
					if serviceName.isEmpty || accessory.name.localizedCaseInsensitiveContains( serviceName ) {
						name = accessory.name
					} else if serviceName.localizedCaseInsensitiveContains( accessory.name ) {
						name = serviceName
					} else {
						name = "\(accessory.name) – \(serviceName)"
					}
					result.append( HomeTarget( kind: kind, accessoryID: accessory.uniqueIdentifier, serviceID: service.uniqueIdentifier, actionSetID: nil, name: name, room: accessory.room?.name, home: home.name ) )
				}
			}
		}

		for actionSet in home.actionSets {
			result.append( HomeTarget( kind: .scene, accessoryID: nil, serviceID: nil, actionSetID: actionSet.uniqueIdentifier, name: actionSet.name, room: nil, home: home.name ) )
		}

		return result.sorted { ( $0.room ?? "~", $0.name ) < ( $1.room ?? "~", $1.name ) }
	}

	/// Accessory or scene name for a key, used when the key has no custom label.
	func name( for assignment: KeyAssignment ) -> String? {
		if let actionSetID = assignment.actionSetID {
			return actionSet( actionSetID )?.actionSet.name
		}
		guard let accessory = self.accessory( assignment.accessoryID ) else { return nil }
		if let service = accessory.services.first( where: { $0.uniqueIdentifier == assignment.serviceID } ), !service.name.isEmpty {
			return service.name
		}
		return accessory.name
	}

	// MARK: - Actions

	/// Runs an assignment's action and returns what it did, for the log. With several
	/// accessories, the key accessory's state decides Toggle, and every accessory gets the
	/// same on/off (open/close, unlock/lock).
	@discardableResult
	func perform( _ assignment: KeyAssignment ) async throws -> String {
		guard let kind = assignment.kind, assignment.action != .none else { return "Nothing to do" }
		guard !homes.isEmpty else { throw HomeActionError.noHome }

		if kind == .scene {
			guard let scene = actionSet( assignment.actionSetID ) else { throw HomeActionError.notFound }
			try await scene.home.executeActionSet( scene.actionSet )
			// A scene's changes come from this app, so HomeKit doesn't report them back.
			refreshWatched( after: .milliseconds( 1500 ) )
			return "Ran scene \u{201C}\(scene.actionSet.name)\u{201D}"
		}

		let members = assignment.members.filter { $0.kind.targetCharacteristicType != nil }
		guard !members.isEmpty, let ref = assignment.characteristicRef else { throw HomeActionError.unsupported }

		let keyState = kind.state( for: values[ref] )
		let activate: Bool
		if let explicit = KeyKind.activates( assignment.action ) {
			activate = explicit
		} else if kind == .garageDoor && keyState == .stopped {
			activate = !( doorWasOpening[ref] ?? true )   // reverse; closing if we never saw it move
		} else {
			activate = !kind.isActive( keyState )
		}

		var done: [String] = []
		var failures: [String] = []
		for member in members {
			guard let targetType = member.kind.targetCharacteristicType, let value = member.kind.targetValue( activate: activate ),
				  let accessory = self.accessory( member.accessoryID ),
				  let target    = Self.characteristic( targetType, serviceID: member.serviceID, in: accessory ) else {
				failures.append( "an accessory that no longer exists" )
				continue
			}
			do {
				try await target.writeValue( value )
				done.append( accessory.name )
				noteWrite( member: member, value: value )
			} catch {
				failures.append( "\(accessory.name) (\(error.localizedDescription))" )
			}
		}

		let verb = switch kind {
			case .garageDoor: activate ? "Open" : "Close"
			case .lock:       activate ? "Unlock" : "Lock"
			default:          activate ? "Turn on" : "Turn off"
		}
		if done.isEmpty, let first = failures.first {
			throw HomeActionError.failed( "\(verb) failed: \(first)" )
		}
		var summary = "\(verb): \(done.joined( separator: ", " ))"
		if !failures.isEmpty { summary += "; failed: \(failures.joined( separator: ", " ))" }
		return summary
	}

	// MARK: - Slider keys

	/// The levels a key's accessory (its service) can have adjusted.
	func levels( for assignment: KeyAssignment ) -> [SliderLevel] {
		guard assignment.kind == .power || assignment.kind == .fan, let accessory = accessory( assignment.accessoryID ) else { return [] }
		return SliderLevel.allCases.filter { level in
			Self.characteristic( level.characteristicType, serviceID: assignment.serviceID, in: accessory ) != nil
		}
	}

	/// The level as the key shows it: the value being written while a slider key is held,
	/// else the last known one.
	func level( _ ref: CharacteristicRef ) -> Double? {
		levelGoals[ref] ?? ( values[ref] as? NSNumber )?.doubleValue
	}

	/// One step of a slider key. The new level shows at once; the writes are coalesced, so
	/// while one is on its way the next press just moves the goal, and only the latest goal is
	/// written after it. Raising a level that's off also turns it on. Returns the new level.
	/// `toEnd`: all the way, to the top (raising key) or the bottom.
	@discardableResult
	func adjust( _ assignment: KeyAssignment, toEnd: Bool = false ) -> Double? {
		guard let slider = assignment.slider, let ref = assignment.sliderRef, let kind = assignment.kind,
			  let accessory = accessory( ref.accessoryID ),
			  let characteristic = Self.characteristic( ref.characteristicType, serviceID: ref.serviceID, in: accessory ) else { return nil }

		let metadata = characteristic.metadata
		let low      = metadata?.minimumValue?.doubleValue ?? 0
		let high     = metadata?.maximumValue?.doubleValue ?? 100
		let base     = level( ref ) ?? ( characteristic.value as? NSNumber )?.doubleValue ?? low
		var goal     = toEnd ? ( slider.raises ? high : low ) : min( max( base + ( slider.raises ? slider.step : -slider.step ), low ), high )
		if let step = metadata?.stepValue?.doubleValue, step > 0 {
			goal = min( max( ( goal / step ).rounded() * step, low ), high )
		}
		levelGoals[ref] = goal
		values[ref]     = NSNumber( value: goal )
		onChange?( ref )

		// Every accessory the key controls that has the level (a group moves together).
		let targets = assignment.members.compactMap { member -> HMCharacteristic? in
			guard let other = self.accessory( member.accessoryID ) else { return nil }
			return Self.characteristic( ref.characteristicType, serviceID: member.serviceID, in: other )
		}
		if slider.raises, let power = assignment.characteristicRef, !kind.isActive( kind.state( for: values[power] ) ),
		   let targetType = kind.targetCharacteristicType, let on = kind.targetValue( activate: true ),
		   let switchCharacteristic = Self.characteristic( targetType, serviceID: ref.serviceID, in: accessory ) {
			Task { try? await switchCharacteristic.writeValue( on ) }
		}
		writeLevel( ref, to: targets, integer: metadata?.format != HMCharacteristicMetadataFormatFloat )
		return goal
	}

	/// Writes the goal until what was written is the goal (it may move meanwhile).
	private func writeLevel( _ ref: CharacteristicRef, to targets: [HMCharacteristic], integer: Bool ) {
		guard !levelWriters.contains( ref ) else { return }
		levelWriters.insert( ref )
		Task {
			var written: Double?
			while let goal = levelGoals[ref], goal != written {
				let value: NSNumber = integer ? NSNumber( value: Int( goal.rounded() ) ) : NSNumber( value: goal )
				for target in targets {
					do {
						try await target.writeValue( value )
					} catch {
						levelError = error.localizedDescription
					}
				}
				written = goal
			}
			levelGoals[ref] = nil
			levelWriters.remove( ref )
			refreshWatched( after: .milliseconds( 1000 ) )
		}
	}

	/// The last slider write that failed, for the log; read and cleared by the caller.
	func takeLevelError() -> String? {
		defer { levelError = nil }
		return levelError
	}

	/// Remembers each door's direction from its current state (HMCharacteristicValueDoorState:
	/// 0 open, 1 closed, 2 opening, 3 closing, 4 stopped).
	private func noteDoorMotion() {
		for ( ref, value ) in values where ref.characteristicType == HMCharacteristicTypeCurrentDoorState {
			switch ( value as? NSNumber )?.intValue {
				case 0, 2: doorWasOpening[ref] = true
				case 1, 3: doorWasOpening[ref] = false
				default:   break
			}
		}
	}

	/// HomeKit doesn't tell an app about changes it made itself, so record what was written
	/// (when it's the displayed value, like a light's power) and read the rest back soon.
	private func noteWrite( member: KeyMember, value: Any ) {
		guard let displayType = member.kind.displayCharacteristicType else { return }
		let ref = CharacteristicRef( accessoryID: member.accessoryID, serviceID: member.serviceID, characteristicType: displayType )
		if member.kind.targetCharacteristicType == displayType, wanted.contains( ref ) {
			values[ref] = value
			onChange?( ref )
		}
		refreshWatched( after: .milliseconds( 1000 ) )
		refreshWatched( after: .milliseconds( 4000 ) )   // a door takes a while to open or close
	}

	/// Re-reads every watched characteristic after a delay.
	private func refreshWatched( after delay: Duration ) {
		Task { [weak self] in
			try? await Task.sleep( for: delay )
			guard let self else { return }
			for entry in watched {
				guard ( try? await entry.characteristic.readValue() ) != nil else { continue }
				let old = values[entry.ref] as? NSObject
				let new = entry.characteristic.value as? NSObject
				if old != new {
					values[entry.ref] = entry.characteristic.value
					onChange?( entry.ref )
				}
			}
		}
	}

}

extension HomeObserver: @MainActor HMHomeManagerDelegate {
	func homeManagerDidUpdateHomes( _ manager: HMHomeManager ) {
		homes         = manager.homes
		authorization = manager.authorizationStatus
		requestRebuild()
		onHomesChanged?()
	}

	func homeManager( _ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus ) {
		authorization = status
		onHomesChanged?()
	}
}

extension HomeObserver: @MainActor HMHomeDelegate {
	func home( _ home: HMHome, didAdd accessory: HMAccessory ) {
		requestRebuild()
		onHomesChanged?()
	}

	func home( _ home: HMHome, didRemove accessory: HMAccessory ) {
		requestRebuild()
		onHomesChanged?()
	}

	func home( _ home: HMHome, didAdd actionSet: HMActionSet ) {
		onHomesChanged?()
	}

	func home( _ home: HMHome, didRemove actionSet: HMActionSet ) {
		onHomesChanged?()
	}

	func home( _ home: HMHome, didUpdateNameFor actionSet: HMActionSet ) {
		onHomesChanged?()
	}
}

// HMAccessoryDelegate can't take an isolated conformance, so its methods are nonisolated.
// HomeKit calls them on the main thread in practice, but neither its headers nor its
// documentation promise a queue, so anything else hops to the main queue (in order)
// instead of asserting. Only Sendable values cross; HomeKit objects are looked up again.
extension HomeObserver: HMAccessoryDelegate {
	nonisolated private func onMain( _ work: @escaping @MainActor @Sendable () -> Void ) {
		if Thread.isMainThread {
			MainActor.assumeIsolated { work() }
		} else {
			DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
		}
	}

	nonisolated func accessory( _ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic ) {
		let changed = ObjectIdentifier( characteristic )
		onMain {
			for entry in self.watched where ObjectIdentifier( entry.characteristic ) == changed {
				self.values[entry.ref] = entry.characteristic.value
				self.onChange?( entry.ref )
			}
		}
	}

	nonisolated func accessoryDidUpdateReachability( _ accessory: HMAccessory ) {
		let id        = accessory.uniqueIdentifier
		let reachable = accessory.isReachable
		onMain {
			for entry in self.watched where entry.ref.accessoryID == id {
				self.onChange?( entry.ref )
			}
			// Values missed while unreachable arrive with a fresh read.
			if reachable { self.requestRebuild() }
		}
	}

	nonisolated func accessoryDidUpdateName( _ accessory: HMAccessory ) {
		onMain { self.onHomesChanged?() }
	}

	nonisolated func accessory( _ accessory: HMAccessory, didUpdateNameFor service: HMService ) {
		onMain { self.onHomesChanged?() }
	}

	nonisolated func accessoryDidUpdateServices( _ accessory: HMAccessory ) {
		onMain {
			self.requestRebuild()
			self.onHomesChanged?()
		}
	}
}
