//
//  MenuPanel.swift
//  ESPDeckMenuBar
//
//  The menu bar item's menu, as a panel of our own. macOS 26 and later run a status item's
//  NSMenu in another process, and WindowServer only lets an app come to the front after
//  input in one of its own windows, so choosing Configure… from a real menu could never
//  activate the window it opened. A click in this panel is the app's own input.
//
//  It's a non-activating panel (as Spotlight's): it takes the keyboard without making the
//  app active, so the app in front stays so, and its first click goes straight to the row.
//

import AppKit
import SwiftUI

/// What the panel lists, kept current by MenuBarController.
@MainActor
@Observable
final class MenuPanelModel {
	/// A deck row: its name, its state on a second line, and its status icon.
	struct Deck: Identifiable {
		let id    : String
		let name  : String
		let state : String?
		let icon  : NSImage?
	}

	/// A status line, e.g. "HomeKit: Connected".
	struct Line: Identifiable {
		let id   : Int
		let text : String
		let icon : NSImage?
	}

	var decks         : [Deck] = []
	var lines         : [Line] = []
	var launchAtLogin = false
}

/// What the rows do; the panel closes first.
struct MenuPanelActions {
	let showDeck       : ( String ) -> Void
	let configure      : () -> Void
	let usbSetup       : () -> Void
	let launchAtLogin  : () -> Void
	let quit           : () -> Void
}

/// The panel itself: borderless, with the menu's material and rounded corners, floating at
/// menu level. It closes when it loses the keyboard (a click elsewhere), on Esc, or once a
/// row is chosen.
final class MenuPanel: NSPanel {
	/// Called when it closes, however that happened.
	var onClose: ( () -> Void )?

	init<Content: View>( content: Content ) {
		super.init( contentRect: NSRect( x: 0, y: 0, width: 280, height: 100 ), styleMask: [ .nonactivatingPanel, .borderless ], backing: .buffered, defer: true )
		isFloatingPanel    = true
		level              = .popUpMenu
		hasShadow          = true
		isOpaque           = false
		backgroundColor    = .clear
		hidesOnDeactivate  = false
		isReleasedWhenClosed = false
		collectionBehavior = [ .transient, .ignoresCycle, .moveToActiveSpace ]

		let effect = NSVisualEffectView()
		effect.material     = .menu
		effect.state        = .active
		effect.blendingMode = .behindWindow
		effect.wantsLayer   = true
		effect.layer?.cornerRadius  = 10
		effect.layer?.cornerCurve   = .continuous
		effect.layer?.masksToBounds = true

		let host = FirstClickHostingView( rootView: content )
		host.translatesAutoresizingMaskIntoConstraints = false
		effect.addSubview( host )
		NSLayoutConstraint.activate( [
			host.leadingAnchor.constraint( equalTo: effect.leadingAnchor ),
			host.trailingAnchor.constraint( equalTo: effect.trailingAnchor ),
			host.topAnchor.constraint( equalTo: effect.topAnchor ),
			host.bottomAnchor.constraint( equalTo: effect.bottomAnchor ),
		] )
		contentView = effect
	}

	/// Takes the keyboard (for Esc) without activating the app: it's a non-activating panel.
	override var canBecomeKey: Bool { true }

	/// Never a main window: it doesn't count as an open window (DockPresence).
	override var canBecomeMain: Bool { false }

	/// Esc closes it.
	override func cancelOperation( _ sender: Any? ) {
		close()
	}

	/// A click elsewhere takes the keyboard away: close, as a menu would.
	override func resignKey() {
		super.resignKey()
		close()
	}

	/// Closes and tells the owner.
	override func close() {
		guard isVisible else { return }
		super.close()
		onClose?()
	}

	/// Shows it just under `button` (the status item's), kept on that screen.
	func show( below button: NSView ) {
		guard let buttonWindow = button.window else { return }
		let size   = contentView?.fittingSize ?? frame.size
		let anchor = buttonWindow.convertToScreen( button.convert( button.bounds, to: nil ) )
		let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
		var origin = NSPoint( x: anchor.minX, y: anchor.minY - size.height - 4 )
		origin.x   = min( max( origin.x, screen.minX + 4 ), screen.maxX - size.width - 4 )
		setFrame( NSRect( origin: origin, size: size ), display: true )
		makeKeyAndOrderFront( nil )
	}
}

/// A hosting view that takes the first click even while its window isn't key, so choosing
/// a row never spends a click on focusing the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
	override func acceptsFirstMouse( for event: NSEvent? ) -> Bool { true }
}

/// The rows, laid out as the menu was: decks, status lines, the commands, Quit.
struct MenuPanelView: View {
	let model   : MenuPanelModel
	let actions : MenuPanelActions
	/// Closes the panel before a row's action runs.
	let dismiss : () -> Void

	var body: some View {
		VStack( alignment: .leading, spacing: 0 ) {
			Text( "Decks" )
				.font( .system( size: 11, weight: .semibold ) )
				.foregroundStyle( .secondary )
				.padding( .horizontal, 9 )
				.padding( .top, 3 )
				.padding( .bottom, 2 )
			if model.decks.isEmpty {
				MenuPanelRow( title: "None yet", enabled: false ) {}
			}
			ForEach( model.decks ) { deck in
				MenuPanelRow( icon: deck.icon, title: deck.name, detail: deck.state ) { run { actions.showDeck( deck.id ) } }
			}
			separator
			// Chosen, a status line opens the configuration window, where the same status is.
			ForEach( model.lines ) { line in
				MenuPanelRow( icon: line.icon, title: line.text ) { run( actions.configure ) }
			}
			separator
			MenuPanelRow( symbol: "gearshape", title: "Configure…" ) { run( actions.configure ) }
			MenuPanelRow( symbol: "cable.connector", title: "Set Up a Device over USB…" ) { run( actions.usbSetup ) }
			MenuPanelRow( symbol: model.launchAtLogin ? "checkmark" : nil, title: "Launch at Login" ) { run( actions.launchAtLogin ) }
			separator
			MenuPanelRow( symbol: "power", title: "Quit ESPDeck Bridge" ) { run( actions.quit ) }
		}
		.padding( 5 )
		.frame( width: 280 )
		.fixedSize( horizontal: false, vertical: true )
	}

	/// A thin line between groups, inset as a menu's are.
	private var separator: some View {
		Divider()
			.padding( .horizontal, 9 )
			.padding( .vertical, 5 )
	}

	/// Closes the panel, then runs `action` while this click is still the latest input.
	private func run( _ action: () -> Void ) {
		dismiss()
		action()
	}
}

/// One row: an icon (an image, an SF Symbol, or blank space), the title, and an optional
/// second line, highlighted in the accent color under the pointer as a menu item is.
private struct MenuPanelRow: View {
	var icon    : NSImage? = nil
	var symbol  : String?  = nil
	let title   : String
	var detail  : String?  = nil
	var enabled = true
	let action  : () -> Void

	@State private var hovering = false

	var body: some View {
		let highlighted = hovering && enabled
		Button( action: action ) {
			HStack( alignment: .firstTextBaseline, spacing: 6 ) {
				Group {
					if let icon {
						Image( nsImage: icon )
					} else if let symbol {
						Image( systemName: symbol )
							.font( .system( size: 12 ) )
					} else {
						Color.clear
					}
				}
				.frame( width: 16, height: 16 )
				.foregroundStyle( highlighted ? Color.white : Color.primary )   // SF Symbols; status icons keep their colors
				.alignmentGuide( .firstTextBaseline ) { $0[ VerticalAlignment.center ] + 4 }

				VStack( alignment: .leading, spacing: 1 ) {
					Text( title )
						.font( .system( size: 13 ) )
						.foregroundStyle( highlighted ? Color.white : enabled ? Color.primary : Color.secondary )
					if let detail {
						Text( detail )
							.font( .system( size: 11 ) )
							.foregroundStyle( highlighted ? Color.white.opacity( 0.85 ) : Color.secondary )
					}
				}
				Spacer( minLength: 0 )
			}
			.padding( .horizontal, 9 )
			.padding( .vertical, 3 )
			.frame( maxWidth: .infinity, alignment: .leading )
			.background( RoundedRectangle( cornerRadius: 5, style: .continuous ).fill( highlighted ? Color.accentColor : Color.clear ) )
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.disabled( !enabled )
		.onHover { hovering = $0 }
	}
}
