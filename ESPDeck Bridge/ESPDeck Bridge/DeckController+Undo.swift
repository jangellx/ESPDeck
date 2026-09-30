//
//  DeckController+Undo.swift
//  ESPDeck Bridge
//
//  Undo and redo for key edits, on the configuration window's undo manager (Edit ▸ Undo),
//  which text fields share. Before a change, the device's pages are snapshotted; undoing
//  puts them back and registers the redo. Quick edits to the same key (typing a label,
//  dragging the colour picker) are one step.
//

import Foundation

extension DeckController {
	/// Edits of the same key this close together undo as one.
	static let undoCoalesceInterval: TimeInterval = 1.5

	/// A device's keys, as undo restores them.
	struct KeysSnapshot {
		var pages       : [[KeyAssignment]]
		var currentPage : Int
	}

	/// Call before changing a device's keys. `coalesce` names a run of edits that undo as one
	/// while they keep coming (under undoCoalesceInterval apart).
	func recordUndo( device id: String, _ name: String, coalesce: String? = nil ) {
		guard let undoManager, !undoManager.isUndoing, !undoManager.isRedoing, let settings = settings( id ) else { return }
		let now = Date()
		defer {
			undoCoalescing = coalesce
			undoCoalescedAt = now
		}
		if let coalesce, coalesce == undoCoalescing, now.timeIntervalSince( undoCoalescedAt ) < Self.undoCoalesceInterval {
			return
		}
		register( KeysSnapshot( pages: settings.pages, currentPage: settings.currentPage ), device: id, name: name )
	}

	/// Registers putting a snapshot back, under the action's name.
	private func register( _ snapshot: KeysSnapshot, device id: String, name: String ) {
		guard let undoManager else { return }
		// Its icon files stay until the app quits, in case the undo brings them back.
		for key in snapshot.pages.joined() {
			config.iconsKeptForUndo.formUnion( key.icons.values )
		}
		undoManager.registerUndo( withTarget: self ) { controller in
			MainActor.assumeIsolated { controller.restore( snapshot, device: id, name: name ) }
		}
		undoManager.setActionName( name )
	}

	/// Puts a snapshot back (undo or redo), registering the inverse, and shows the device.
	private func restore( _ snapshot: KeysSnapshot, device id: String, name: String ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		let current = config.settings.devices[index]
		// The inverse, for redo (or undo again after a redo).
		register( KeysSnapshot( pages: current.pages, currentPage: current.currentPage ), device: id, name: name )
		undoCoalescing = nil

		stopSliders( device: id )
		config.settings.devices[index].pages       = snapshot.pages
		config.settings.devices[index].currentPage = min( snapshot.currentPage, snapshot.pages.count - 1 )
		window.selection = id
		assignmentsChanged( device: id )
	}
}
