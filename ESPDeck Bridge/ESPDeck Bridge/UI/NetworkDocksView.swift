//
//  NetworkDocksView.swift
//  ESPDeck Bridge
//
//  The Network Docks page: turns the experimental Network Dock support on or off, and lists
//  the docks on the network, each with Add (or Show, once added). See
//  DeckController+Docks.swift.
//

import SwiftUI

/// The Network Docks page; see the file comment.
struct NetworkDocksView: View {
	let controller: DeckController

	/// Where to report how a dock behaves.
	private static let issuesURL = URL( string: "https://github.com/jangellx/ESPDeck/issues" )!

	private var enabled: Binding<Bool> {
		Binding { controller.networkDocksEnabled } set: { controller.setNetworkDocks( enabled: $0 ) }
	}

	var body: some View {
		Form {
			Section {
				Toggle( "Use Network Docks", isOn: enabled )
			} header: {
				HStack {
					SectionHeader( "Network Docks" )
					Text( "Experimental" )
						.font( .caption.weight( .semibold ) )
						.padding( .horizontal, 6 )
						.padding( .vertical, 2 )
						.background( Capsule().fill( Color.orange.opacity( 0.2 ) ) )
						.foregroundStyle( .orange )
				}
			} footer: {
				Text( "An Elgato Stream Deck Network Dock puts a Stream Deck on your network over Ethernet. With Network Docks turned on, ESPDeck Bridge drives the Stream Deck plugged into a dock directly, with no ESP32: its keys, pages and menus work as on any other deck." )
			}

			if controller.networkDocksEnabled {
				FoundDocksSection( controller: controller )
			}

			Section {
				Text( "This hasn't been tried with a real Network Dock yet. It follows what others have worked out about how docks work, and was tested against a stand-in for one." )
				Text( "A dock works with one app at a time. Add one here only if Elgato's Stream Deck app isn't using it, and forget it here before using it with Elgato's app again." )
				Text( "A dock has no pairing or encryption: anything on your network can connect to it. Use one only on a network you trust." )
				Text( "The Stream Deck MK.2, XL, Neo, +, Pedal and 15- and 32-key modules can be used through a dock. The Mini and the original Stream Deck can't yet, and the + only has its keys: its dials and touch strip aren't used." )
				Link( "Report how a dock works on GitHub", destination: Self.issuesURL )
			} header: {
				SectionHeader( "Before You Start" )
			}
		}
		.formStyle( .grouped )
	}
}

/// The docks on the network, with Add, Show or Try Again for each.
private struct FoundDocksSection: View {
	let controller: DeckController

	private var browser: DockBrowser { controller.dockBrowser }

	var body: some View {
		Section {
			if let problem = browser.problem {
				Label( "Can't look for docks: \(problem)", systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .red )
			} else if browser.found.isEmpty {
				HStack {
					ProgressView()
						.controlSize( .small )
					Text( "Looking for Network Docks…" )
						.foregroundStyle( .secondary )
				}
			}
			ForEach( browser.found ) { dock in
				FoundDockRow( controller: controller, dock: dock )
			}
		} header: {
			SectionHeader( "On This Network" )
		} footer: {
			Text( "Docks are found over Bonjour, on the same network as this Mac. Adding one connects to it and lists it under Devices." )
		}
	}
}

/// One dock found on the network.
private struct FoundDockRow: View {
	let controller : DeckController
	let dock       : FoundDock

	var body: some View {
		HStack {
			VStack( alignment: .leading, spacing: 2 ) {
				Text( dock.serviceName )
				Text( detail )
					.secondaryCaption()
			}
			Spacer()
			action
		}
	}

	/// The dock's serial number and what's plugged into it, or where it is in being asked.
	private var detail: String {
		if let problem = dock.problem, dock.serial == nil { return "Didn't answer: \(problem)" }
		guard let serial = dock.serial else { return "Asking the dock…" }
		let deck = dock.deckModel.map { dock.supported ? $0 : "\($0) (not supported on a dock yet)" } ?? "No Stream Deck plugged in"
		return "\(serial) · \(deck)"
	}

	@ViewBuilder
	private var action: some View {
		if let id = controller.addedDock( dock ) {
			Button( "Show" ) { controller.window.selection = id }
		} else if dock.serial != nil {
			Button( "Add" ) { controller.addDock( dock ) }
				.prominentButtonStyle()
		} else if dock.problem != nil {
			Button( "Try Again" ) { controller.dockBrowser.probeAgain( dock.serviceName ) }
		} else {
			ProgressView()
				.controlSize( .small )
		}
	}
}
