//
//  MenuPanel.swift
//  ESPDeckMenuBar
//
//  The menu bar item's menu, as a panel of our own. macOS 26 and later run a status item's
//  NSMenu in another process, and WindowServer rejects an app's own activation requests
//  unless they follow input that activated it, so choosing Configure… from a real menu
//  (or from a non-activating panel) could never activate the window it opened.
//
//  This is an ordinary, activating window: clicking a row makes WindowServer itself
//  activate the app, as clicking any app's window does, and the row takes that same click,
//  so the window its action opens comes up in an active app. Shown, it doesn't take the
//  keyboard or activate anything; a click anywhere else closes it. While the app is already
//  active (its window is in front), it can take the keyboard: then the arrow keys move
//  through the rows and Return chooses one. From another app only the mouse works, since
//  macOS gives the keyboard to the active app's windows alone.
//
//  AppKit only: this bundle is loaded into a Catalyst app, where SwiftUI is the iOS one.
//

import AppKit

/// One line of the panel.
enum MenuPanelEntry {
	/// A small gray heading ("Decks").
	case header( String )
	/// A row: an icon (an image, or an SF Symbol) or blank space, its title, an optional
	/// second line, and what choosing it does (nil: shown but not choosable).
	case row( icon: NSImage?, title: String, detail: String? = nil, action: ( () -> Void )? )
	/// A thin line between groups.
	case separator
}

/// The panel itself: borderless, with the menu's material and rounded corners, floating at
/// menu level. It closes when it loses the keyboard (a click elsewhere), on Esc, or once a
/// row is chosen.
final class MenuPanel: NSPanel {
	/// Called when it closes, however that happened.
	var onClose: ( () -> Void )?

	private let stack = NSStackView()
	/// The rows that can be chosen, top to bottom, and the one that's highlighted (under the
	/// pointer, or reached with the arrow keys).
	private var rows: [MenuPanelRowView] = []
	private var highlightedRow: Int?

	/// Its width, as a menu's.
	private static let width: CGFloat = 280

	init() {
		super.init( contentRect: NSRect( x: 0, y: 0, width: Self.width, height: 100 ), styleMask: [ .borderless ], backing: .buffered, defer: true )
		isFloatingPanel      = true
		level                = .popUpMenu
		hasShadow            = true
		isOpaque             = false
		backgroundColor      = .clear
		hidesOnDeactivate    = false
		isReleasedWhenClosed = false
		collectionBehavior   = [ .transient, .ignoresCycle, .moveToActiveSpace ]

		let effect = NSVisualEffectView()
		effect.material     = .menu
		effect.state        = .active
		effect.blendingMode = .behindWindow
		effect.wantsLayer   = true
		effect.layer?.cornerRadius  = 10
		effect.layer?.cornerCurve   = .continuous
		effect.layer?.masksToBounds = true

		stack.orientation = .vertical
		stack.alignment   = .leading
		stack.spacing     = 0
		stack.edgeInsets  = NSEdgeInsets( top: 5, left: 5, bottom: 5, right: 5 )
		stack.translatesAutoresizingMaskIntoConstraints = false
		effect.addSubview( stack )
		NSLayoutConstraint.activate( [
			stack.leadingAnchor.constraint( equalTo: effect.leadingAnchor ),
			stack.trailingAnchor.constraint( equalTo: effect.trailingAnchor ),
			stack.topAnchor.constraint( equalTo: effect.topAnchor ),
			stack.bottomAnchor.constraint( equalTo: effect.bottomAnchor ),
			stack.widthAnchor.constraint( equalToConstant: Self.width ),
		] )
		contentView = effect
	}

	/// Replaces the rows. Choosing one closes the panel, then runs its action while that
	/// click is still the latest input.
	func setEntries( _ entries: [MenuPanelEntry] ) {
		stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
		rows           = []
		highlightedRow = nil
		for entry in entries {
			let view: NSView
			switch entry {
				case .header( let title ):
					view = MenuPanelHeaderView( title )
				case .separator:
					view = MenuPanelSeparatorView()
				case .row( let icon, let title, let detail, let action ):
					let row = MenuPanelRowView( icon: icon, title: title, detail: detail, action: action.map { action in
						{ [weak self] in
							self?.close()
							action()
						}
					} )
					if action != nil {
						let index = rows.count
						rows.append( row )
						// The pointer over a row highlights it, and leaving it clears that.
						row.onHover = { [weak self] inside in
							guard let self else { return }
							if inside { highlight( index ) } else if highlightedRow == index { highlight( nil ) }
						}
					}
					view = row
			}
			stack.addArrangedSubview( view )
			view.widthAnchor.constraint( equalTo: stack.widthAnchor, constant: -10 ).isActive = true
		}
	}

	/// Key once a click has activated the app (then Esc works).
	override var canBecomeKey: Bool { true }

	/// Never a main window: it doesn't count as an open window (DockPresence).
	override var canBecomeMain: Bool { false }

	/// Esc closes it.
	override func cancelOperation( _ sender: Any? ) {
		close()
	}

	/// Highlights one row, or none.
	private func highlight( _ index: Int? ) {
		highlightedRow = index
		for ( position, row ) in rows.enumerated() {
			row.isHighlighted = position == index
		}
	}

	/// Up and Down move through the rows that can be chosen, wrapping at the ends; Return,
	/// Enter and Space choose the highlighted one. Only reached while the panel is key.
	override func keyDown( with event: NSEvent ) {
		switch event.keyCode {
			case 125, 126:   // Down, Up
				guard !rows.isEmpty else { return }
				let step = event.keyCode == 125 ? 1 : -1
				highlight( highlightedRow.map { ( $0 + step + rows.count ) % rows.count } ?? ( step > 0 ? 0 : rows.count - 1 ) )
			case 36, 76, 49:   // Return, Enter, Space
				if let highlightedRow { rows[highlightedRow].choose() }
			default:
				super.keyDown( with: event )
		}
	}

	/// Watching for clicks outside it, in other apps and in this one, while it's shown.
	private var monitors: [Any] = []

	/// Closes and tells the owner.
	override func close() {
		guard isVisible else { return }
		monitors.forEach( NSEvent.removeMonitor )
		monitors = []
		super.close()
		onClose?()
	}

	/// A click anywhere but here closes it, as a menu would. (It isn't key while shown, so
	/// losing the keyboard can't be the signal.)
	private func watchForClicksElsewhere() {
		let mask: NSEvent.EventTypeMask = [ .leftMouseDown, .rightMouseDown, .otherMouseDown ]
		if let global = NSEvent.addGlobalMonitorForEvents( matching: mask, handler: { [weak self] _ in
			MainActor.assumeIsolated { self?.close() }
		} ) {
			monitors.append( global )
		}
		if let local = NSEvent.addLocalMonitorForEvents( matching: mask, handler: { [weak self] event in
			if event.window !== self { self?.close() }
			return event
		} ) {
			monitors.append( local )
		}
	}

	/// Shows it just under `button` (the status item's), kept on that screen.
	func show( below button: NSView ) {
		guard let buttonWindow = button.window, let content = contentView else { return }
		content.layoutSubtreeIfNeeded()
		let size   = NSSize( width: Self.width, height: content.fittingSize.height )
		let anchor = buttonWindow.convertToScreen( button.convert( button.bounds, to: nil ) )
		let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
		var origin = NSPoint( x: anchor.minX, y: anchor.minY - size.height - 4 )
		origin.x   = min( max( origin.x, screen.minX + 4 ), screen.maxX - size.width - 4 )
		setFrame( NSRect( origin: origin, size: size ), display: true )
		orderFrontRegardless()   // without activating: only a click on a row does that
		// With the app already active it can have the keyboard, for the arrow keys.
		if NSApp.isActive {
			makeKey()
			makeFirstResponder( nil )
		}
		watchForClicksElsewhere()
	}
}

/// "Decks": a small gray heading.
private final class MenuPanelHeaderView: NSView {
	init( _ title: String ) {
		super.init( frame: .zero )
		let label = NSTextField( labelWithString: title )
		label.font      = .systemFont( ofSize: 11, weight: .semibold )
		label.textColor = .secondaryLabelColor
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview( label )
		NSLayoutConstraint.activate( [
			label.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 9 ),
			label.topAnchor.constraint( equalTo: topAnchor, constant: 3 ),
			label.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -2 ),
		] )
	}

	required init?( coder: NSCoder ) { nil }
}

/// A thin line between groups, inset as a menu's are.
private final class MenuPanelSeparatorView: NSView {
	init() {
		super.init( frame: .zero )
		let line = NSBox()
		line.boxType = .separator
		line.translatesAutoresizingMaskIntoConstraints = false
		addSubview( line )
		NSLayoutConstraint.activate( [
			line.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 9 ),
			line.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -9 ),
			line.centerYAnchor.constraint( equalTo: centerYAnchor ),
			heightAnchor.constraint( equalToConstant: 11 ),
		] )
	}

	required init?( coder: NSCoder ) { nil }
}

/// One row: an icon (or blank space), the title, and an optional second line, highlighted in
/// the accent color while highlighted (the panel says when) as a menu item is. Clicked, it
/// runs its action; it takes the first click even if the panel isn't key.
private final class MenuPanelRowView: NSView {
	private let action     : ( () -> Void )?
	private let iconView   = NSImageView()
	private let titleLabel : NSTextField
	private let detailLabel: NSTextField?
	/// Set by the panel, which keeps one row highlighted at most.
	var isHighlighted = false { didSet { updateColors() } }
	/// The pointer came over the row, or left it.
	var onHover: ( ( Bool ) -> Void )?

	init( icon: NSImage?, title: String, detail: String?, action: ( () -> Void )? ) {
		self.action = action
		titleLabel  = NSTextField( labelWithString: title )
		detailLabel = detail.map { NSTextField( labelWithString: $0 ) }
		super.init( frame: .zero )
		wantsLayer = true
		layer?.cornerRadius = 5
		layer?.cornerCurve  = .continuous

		iconView.image        = icon
		iconView.imageScaling = .scaleProportionallyDown
		titleLabel.font       = .menuFont( ofSize: 13 )
		titleLabel.lineBreakMode = .byTruncatingTail
		detailLabel?.font     = .systemFont( ofSize: 11 )
		detailLabel?.lineBreakMode = .byTruncatingTail

		let text = NSStackView( views: [ titleLabel ] + ( detailLabel.map { [ $0 ] } ?? [] ) )
		text.orientation = .vertical
		text.alignment   = .leading
		text.spacing     = 1
		for view in [ iconView, text ] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview( view )
		}
		NSLayoutConstraint.activate( [
			iconView.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 9 ),
			iconView.widthAnchor.constraint( equalToConstant: 16 ),
			iconView.heightAnchor.constraint( equalToConstant: 16 ),
			iconView.centerYAnchor.constraint( equalTo: titleLabel.centerYAnchor ),
			text.leadingAnchor.constraint( equalTo: iconView.trailingAnchor, constant: 6 ),
			text.trailingAnchor.constraint( lessThanOrEqualTo: trailingAnchor, constant: -9 ),
			text.topAnchor.constraint( equalTo: topAnchor, constant: 3 ),
			text.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -3 ),
		] )
		updateColors()
	}

	required init?( coder: NSCoder ) { nil }

	/// Hover tracking over the whole row.
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		trackingAreas.forEach( removeTrackingArea )
		addTrackingArea( NSTrackingArea( rect: bounds, options: [ .mouseEnteredAndExited, .activeAlways, .inVisibleRect ], owner: self ) )
	}

	override func mouseEntered( with event: NSEvent ) { onHover?( true ) }
	override func mouseExited( with event: NSEvent ) { onHover?( false ) }

	/// Runs the row's action, as a click or Return on it does.
	func choose() {
		isHighlighted = false
		action?()
	}

	/// The click that activates the app is also the one that chooses the row.
	override func acceptsFirstMouse( for event: NSEvent? ) -> Bool { true }

	/// Chosen on release inside, as a menu item is.
	override func mouseDown( with event: NSEvent ) {}
	override func mouseUp( with event: NSEvent ) {
		guard action != nil, bounds.contains( convert( event.locationInWindow, from: nil ) ) else { return }
		choose()
	}

	/// White on the accent color while highlighted; gray when it can't be chosen. SF Symbol
	/// icons (templates) follow the text; status icons keep their colors.
	private func updateColors() {
		layer?.backgroundColor = isHighlighted ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
		titleLabel.textColor   = isHighlighted ? .white : action == nil ? .secondaryLabelColor : .labelColor
		detailLabel?.textColor = isHighlighted ? NSColor.white.withAlphaComponent( 0.85 ) : .secondaryLabelColor
		iconView.contentTintColor = isHighlighted ? .white : .labelColor
	}
}
