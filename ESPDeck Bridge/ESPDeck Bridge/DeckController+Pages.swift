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
	func pageCount( device id: String ) -> Int {
		settings( id )?.pages.count ?? 1
	}

	func currentPage( device id: String ) -> Int {
		settings( id )?.currentPage ?? 0
	}

	/// Shows a page on the deck (and in the Keys page).
	func showPage( device id: String, _ page: Int ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		let page = min( max( page, 0 ), config.settings.devices[index].pages.count - 1 )
		guard page != config.settings.devices[index].currentPage else { return }
		stopSliders( device: id )
		config.settings.devices[index].currentPage = page
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
		settings.ensureKey( lowerRight )
		var newPage = Array( repeating: KeyAssignment(), count: count )

		let current = settings.keys[lowerRight]
		if !( current.kind == .page && current.action == .nextPage ) {
			if current.kind != nil || !current.icons.isEmpty || !current.label.isEmpty {
				var moved = current
				if let partner = moved.slider?.partner, partner < settings.keys.count, settings.keys[partner].slider?.partner == lowerRight {
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

		settings.pages.insert( newPage, at: settings.currentPage + 1 )
		settings.currentPage += 1
		// Go to Page keys keep pointing at the same pages.
		let inserted = settings.currentPage + 1   // 1-based
		for page in settings.pages.indices {
			for key in settings.pages[page].indices where settings.pages[page][key].kind == .page {
				if let number = settings.pages[page][key].pageNumber, number >= inserted {
					settings.pages[page][key].pageNumber = number + 1
				}
			}
		}
		stopSliders( device: id )
		config.settings.devices[index] = settings
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Removes the page the deck shows; the one before it (or after, for the first) is shown.
	func deletePage( device id: String ) {
		guard let index = config.settings.deviceIndex( id ), config.settings.devices[index].pages.count > 1 else { return }
		recordUndo( device: id, "Delete Page" )
		var settings = config.settings.devices[index]
		let removed  = settings.currentPage
		settings.pages.remove( at: removed )
		settings.currentPage = max( removed - 1, 0 )
		for page in settings.pages.indices {
			for key in settings.pages[page].indices where settings.pages[page][key].kind == .page {
				if let number = settings.pages[page][key].pageNumber, number > removed + 1 {
					settings.pages[page][key].pageNumber = number - 1
				}
			}
		}
		stopSliders( device: id )
		config.settings.devices[index] = settings
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
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
			case .goToPage:     showPage( device: id, ( assignment.pageNumber ?? 1 ) - 1 )
			default:            break
		}
	}

	/// The symbol a page key shows: arrows, or the page's number.
	func pageSymbol( for assignment: KeyAssignment, device id: String ) -> String {
		switch assignment.action {
			case .nextPage:     return "chevron.right"
			case .previousPage: return "chevron.left"
			case .goToPage:     return Self.numberSymbol( assignment.pageNumber ?? 1, shape: "circle" )
			default:            return Self.numberSymbol( currentPage( device: id ) + 1, shape: "square" )
		}
	}

	/// "3.square.fill"; SF Symbols number them up to 50.
	private static func numberSymbol( _ number: Int, shape: String ) -> String {
		( 0...50 ).contains( number ) ? "\(number).\(shape).fill" : "number.\(shape).fill"
	}
}
