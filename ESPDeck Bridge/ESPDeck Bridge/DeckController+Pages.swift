//
//  DeckController+Pages.swift
//  ESPDeck Bridge
//
//  Pages of keys, as in Elgato's software. The deck shows one page at a time, and the Keys
//  page edits the one it shows. Adding a page makes this page's lower-right key Next Page
//  (what was there moves to the new page's first key) and gives the new page a Previous
//  Page key at its lower left.
//

import Foundation

extension DeckController {
	/// How many pages the device has; always at least one.
	func pageCount( device id: String ) -> Int {
		settings( id )?.pages.count ?? 1
	}

	/// The page the deck shows, from 0.
	func currentPage( device id: String ) -> Int {
		settings( id )?.currentPage ?? 0
	}

	/// Shows a page on the deck (and in the Keys page).
	func showPage( device id: String, _ page: Int ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		let page = min( max( page, 0 ), config.settings.devices[index].pages.count - 1 )
		guard page != config.settings.devices[index].currentPage else { return }
		stopSliders( device: id )
		// What each key shows now, which may still be the page before (changing twice quickly).
		device( id )?.pageChange = ( Date(), device( id )?.displayedPreviews ?? [] )
		config.settings.devices[index].currentPage = page
		clearFailures( device: id )   // they were about the other page's keys
		window.selectedKey = min( window.selectedKey, max( layout( id ).keyCount - 1, 0 ) )
		assignmentsChanged( device: id )
	}

	/// A new page after this one, which the deck then shows.
	func addPage( device id: String ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		let layout     = layout( id )
		let count      = max( layout.keyCount, 1 )
		let cols       = max( layout.cols, 1 )
		let lowerRight = count - 1
		let lowerLeft  = count - cols
		// Where the displaced key goes: key 1, unless that's the Previous Page key (one row).
		let first      = lowerLeft == 0 && count > 2 ? 1 : 0

		recordUndo( device: id, "Add Page" )
		var settings = config.settings.devices[index]
		var newPage  = Array( repeating: KeyAssignment(), count: count )

		let current = settings.keys[lowerRight]
		if !( current.kind == .page && current.action == .nextPage ) {
			if current.kind != nil || !current.icons.isEmpty || !current.label.isEmpty {
				var moved = current
				if let partner = moved.slider?.partner, Self.isPartner( partner, of: lowerRight, in: settings.keys ) {
					settings.keys[partner].slider = nil   // the pair is split across pages
				}
				moved.slider = nil
				if first != lowerRight { newPage[first] = moved }
			}
			settings.keys[lowerRight] = Self.pageKey( .nextPage )
		}
		if lowerLeft != lowerRight {
			newPage[lowerLeft] = Self.pageKey( .previousPage )
		}
		// Pages after it: it needs its own way on.
		if settings.currentPage + 1 < settings.pages.count && lowerLeft != lowerRight {
			newPage[lowerRight] = Self.pageKey( .nextPage )
		}

		settings.pages.insert( DeviceSettings.grid( fromDisplay: newPage, layout: settings.layout ), at: settings.currentPage + 1 )
		settings.currentPage += 1
		let inserted = settings.currentPage + 1   // 1-based
		Self.renumberPageKeys( &settings ) { $0 >= inserted ? $0 + 1 : nil }
		stopSliders( device: id )
		config.settings.devices[index] = settings
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Nothing on it but Next and Previous Page keys.
	func isPageEmpty( device id: String, _ page: Int ) -> Bool {
		guard let pages = settings( id )?.pages, page < pages.count else { return true }
		return pages[page].allSatisfy { key in
			( key.kind == nil && key.icons.isEmpty && key.label.isEmpty && key.backgroundColor == nil )
				|| ( key.kind == .page && ( key.action == .nextPage || key.action == .previousPage ) )
		}
	}

	/// Removes a page (the one the deck shows unless given); the one before it (or after, for
	/// the first) is shown if it was that one. Afterward the last page has no Next Page key
	/// and the first no Previous Page key, since they'd have nowhere to go.
	func deletePage( device id: String, _ page: Int? = nil ) {
		guard let index = config.settings.deviceIndex( id ), config.settings.devices[index].pages.count > 1 else { return }
		var settings = config.settings.devices[index]
		let removed  = min( page ?? settings.currentPage, settings.pages.count - 1 )
		recordUndo( device: id, "Delete Page" )
		settings.pages.remove( at: removed )
		// The last page has nowhere to go on to and the first nowhere to go back to (one page
		// left is both).
		Self.removePageKeys( .nextPage, from: &settings.pages[settings.pages.count - 1] )
		Self.removePageKeys( .previousPage, from: &settings.pages[0] )
		if settings.currentPage > removed || settings.currentPage >= settings.pages.count {
			settings.currentPage = max( settings.currentPage - 1, 0 )
		}
		Self.renumberPageKeys( &settings ) { $0 > removed + 1 ? $0 - 1 : nil }
		stopSliders( device: id )
		config.settings.devices[index] = settings
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Clears every key on every page, leaving one empty page. Its other settings stay, and it
	/// can be undone.
	func clearAllKeys( device id: String ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		recordUndo( device: id, "Clear All Keys" )
		stopSliders( device: id )
		config.settings.devices[index].pages       = [ [] ]
		config.settings.devices[index].currentPage = 0
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Clears a page's keys that run `action` (Next or Previous Page with nowhere to go).
	private static func removePageKeys( _ action: KeyAction, from page: inout [KeyAssignment] ) {
		for key in page.indices where page[key].kind == .page && page[key].action == action {
			page[key] = KeyAssignment()
		}
	}

	/// Keeps Go to Page keys pointing at the same pages after one is inserted or removed:
	/// `renumber` maps a page number (from 1) to its new one, or nil to leave it.
	private static func renumberPageKeys( _ settings: inout DeviceSettings, _ renumber: ( Int ) -> Int? ) {
		for page in settings.pages.indices {
			for key in settings.pages[page].indices where settings.pages[page][key].kind == .page {
				if let number = settings.pages[page][key].pageNumber, let new = renumber( number ) {
					settings.pages[page][key].pageNumber = new
				}
			}
		}
	}

	/// A key running a page command.
	static func pageKey( _ action: KeyAction ) -> KeyAssignment {
		var key    = KeyAssignment()
		key.kind   = .page
		key.action = action
		return key
	}

	/// Next, Previous, Go to Page; Show Page Number does nothing when pressed.
	func performPage( _ assignment: KeyAssignment, device id: String ) {
		let current = currentPage( device: id )
		switch assignment.action {
			case .nextPage:     showPage( device: id, current + 1 )
			case .previousPage: showPage( device: id, current - 1 )
			case .firstPage:    showPage( device: id, 0 )
			case .lastPage:     showPage( device: id, pageCount( device: id ) - 1 )
			case .goToPage:     showPage( device: id, ( assignment.pageNumber ?? 1 ) - 1 )
			default:            break
		}
	}

	/// The symbol a page key shows: arrows, or the page's number.
	func pageSymbol( for assignment: KeyAssignment ) -> String {
		switch assignment.action {
			case .nextPage:     return "chevron.right"
			case .previousPage: return "chevron.left"
			case .firstPage:    return "chevron.left.to.line"
			case .lastPage:     return "chevron.right.to.line"
			case .goToPage:     return Self.numberSymbol( assignment.pageNumber ?? 1, shape: "circle" )
			default:            return "doc"   // drawn as a page with the number on it (KeyFace.pageNumber)
		}
	}

	/// "3.square.fill"; SF Symbols number them up to 50.
	private static func numberSymbol( _ number: Int, shape: String ) -> String {
		( 0...50 ).contains( number ) ? "\(number).\(shape).fill" : "number.\(shape).fill"
	}
}

// MARK: - Failed keys

extension DeckController {
	/// How long a key shows that its action failed.
	static let failureMarkDuration: Duration = .seconds( 10 )

	/// Marks a key whose action failed with a warning triangle on the deck, for
	/// failureMarkDuration: a hint to look at the bridge (Status, or the notification).
	func flagFailure( device id: String, key: Int ) {
		guard let device = device( id ) else { return }
		device.failedKeys.insert( key )
		device.failureTasks[key]?.cancel()
		device.failureTasks[key] = Task { [weak self, weak device] in
			try? await Task.sleep( for: Self.failureMarkDuration )
			guard !Task.isCancelled, let self, let device else { return }
			device.failedKeys.remove( key )
			device.failureTasks[key] = nil
			render( device: id, key: key )
		}
		render( device: id, key: key )
	}

	/// Takes every warning triangle off a deck (another page is showing).
	func clearFailures( device id: String ) {
		guard let device = device( id ) else { return }
		device.failureTasks.values.forEach { $0.cancel() }
		device.failureTasks = [:]
		device.failedKeys   = []
	}
}
