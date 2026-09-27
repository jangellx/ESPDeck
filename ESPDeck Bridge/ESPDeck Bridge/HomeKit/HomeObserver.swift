//
//  HomeObserver.swift
//  ESPDeck Bridge
//
//  Controller-side HomeKit: lists what keys can be bound to, observes the characteristics
//  the key assignments name, and performs key actions.
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
	private(set) var values        : [CharacteristicRef: Any] = [:]

	/// Called when a watched value or reachability changes.
	@ObservationIgnored var onChange       : ( ( CharacteristicRef ) -> Void )?
	/// Called when the set of homes, accessories, or scenes changes.
	@ObservationIgnored var onHomesChanged : ( () -> Void )?
	/// Called once, when the home has loaded and every watched value has been read.
	@ObservationIgnored var onReady        : ( () -> Void )?
	private(set) var isReady = false

	/// The home whose accessories the keys refer to; nil picks the first home.
	var selectedHomeID: UUID? {
		didSet {
			if selectedHomeID != oldValue { requestRebuild() }
		}
	}

	var home: HMHome? {
		homes.first { $0.uniqueIdentifier == selectedHomeID } ?? homes.first
	}

	@ObservationIgnored private var wanted              : Set<CharacteristicRef> = []
	@ObservationIgnored private var watched             : [( ref: CharacteristicRef, characteristic: HMCharacteristic )] = []
	@ObservationIgnored private var observedAccessories : [HMAccessory] = []
	@ObservationIgnored private var observedHome        : HMHome?
	@ObservationIgnored private var rebuildTask         : Task<Void, Never>?
	@ObservationIgnored private var rebuildPending      = false

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
		home?.accessories.first { $0.uniqueIdentifier == ref.accessoryID }?.isReachable ?? false
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

		guard let home else { return }
		home.delegate = self
		observedHome  = home

		for ref in wanted {
			guard let accessory      = home.accessories.first( where: { $0.uniqueIdentifier == ref.accessoryID } ),
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
		observedHome?.delegate = nil
		observedHome = nil
	}

	private static func characteristic( _ type: String, serviceID: UUID?, in accessory: HMAccessory ) -> HMCharacteristic? {
		accessory.services
			.filter { serviceID == nil || $0.uniqueIdentifier == serviceID }
			.lazy
			.compactMap { $0.characteristics.first { $0.characteristicType == type } }
			.first
	}

	// MARK: - Targets

	/// Everything in the current home a key can be bound to.
	func targets() -> [HomeTarget] {
		guard let home else { return [] }
		var result: [HomeTarget] = []

		for accessory in home.accessories {
			for service in accessory.services {
				let types = Set( service.characteristics.map( \.characteristicType ) )
				for kind in KeyKind.allCases {
					guard let type = kind.displayCharacteristicType, types.contains( type ) else { continue }

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
					result.append( HomeTarget( kind: kind, accessoryID: accessory.uniqueIdentifier, serviceID: service.uniqueIdentifier, actionSetID: nil, name: name, room: accessory.room?.name ) )
				}
			}
		}

		for actionSet in home.actionSets {
			result.append( HomeTarget( kind: .scene, accessoryID: nil, serviceID: nil, actionSetID: actionSet.uniqueIdentifier, name: actionSet.name, room: nil ) )
		}

		return result.sorted { ( $0.room ?? "~", $0.name ) < ( $1.room ?? "~", $1.name ) }
	}

	/// Accessory or scene name for a key, used when the key has no custom label.
	func name( for assignment: KeyAssignment ) -> String? {
		guard let home else { return nil }
		if let actionSetID = assignment.actionSetID {
			return home.actionSets.first { $0.uniqueIdentifier == actionSetID }?.name
		}
		guard let accessory = home.accessories.first( where: { $0.uniqueIdentifier == assignment.accessoryID } ) else { return nil }
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
		guard let home else { throw HomeActionError.noHome }

		if kind == .scene {
			guard let actionSet = home.actionSets.first( where: { $0.uniqueIdentifier == assignment.actionSetID } ) else { throw HomeActionError.notFound }
			try await home.executeActionSet( actionSet )
			// A scene's changes come from this app, so HomeKit doesn't report them back.
			refreshWatched( after: .milliseconds( 1500 ) )
			return "Ran scene \u{201C}\(actionSet.name)\u{201D}"
		}

		let members = assignment.members.filter { $0.kind.targetCharacteristicType != nil }
		guard !members.isEmpty, let ref = assignment.characteristicRef else { throw HomeActionError.unsupported }

		let keyState = kind.state( for: values[ref] )
		let activate = KeyKind.activates( assignment.action ) ?? !kind.isActive( keyState )

		var done: [String] = []
		var failures: [String] = []
		for member in members {
			guard let targetType = member.kind.targetCharacteristicType, let value = member.kind.targetValue( activate: activate ),
				  let accessory = home.accessories.first( where: { $0.uniqueIdentifier == member.accessoryID } ),
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

// HMAccessoryDelegate can't take an isolated conformance, so its methods are nonisolated
// and assert the main actor; HomeKit calls delegates on the main thread.
extension HomeObserver: HMAccessoryDelegate {
	nonisolated func accessory( _ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic ) {
		MainActor.assumeIsolated {
			for entry in watched where entry.characteristic == characteristic {
				values[entry.ref] = characteristic.value
				onChange?( entry.ref )
			}
		}
	}

	nonisolated func accessoryDidUpdateReachability( _ accessory: HMAccessory ) {
		MainActor.assumeIsolated {
			for entry in watched where entry.ref.accessoryID == accessory.uniqueIdentifier {
				onChange?( entry.ref )
			}
			// Values missed while unreachable arrive with a fresh read.
			if accessory.isReachable { requestRebuild() }
		}
	}

	nonisolated func accessoryDidUpdateName( _ accessory: HMAccessory ) {
		MainActor.assumeIsolated { onHomesChanged?() }
	}

	nonisolated func accessory( _ accessory: HMAccessory, didUpdateNameFor service: HMService ) {
		MainActor.assumeIsolated { onHomesChanged?() }
	}

	nonisolated func accessoryDidUpdateServices( _ accessory: HMAccessory ) {
		MainActor.assumeIsolated {
			requestRebuild()
			onHomesChanged?()
		}
	}
}
