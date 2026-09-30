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

	/// Its width, as a menu's.
	private static let width: CGFloat = 280

	init() {
		super.init( contentRect: NSRect( x: 0, y: 0, width: Self.width, height: 100 ), styleMask: [ .nonactivatingPanel, .borderless ], backing: .buffered, defer: true )
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
		for entry in entries {
			let view: NSView
			switch entry {
				case .header( let title ):
					view = MenuPanelHeaderView( title )
				case .separator:
					view = MenuPanelSeparatorView()
				case .row( let icon, let title, let detail, let action ):
					view = MenuPanelRowView( icon: icon, title: title, detail: detail, action: action.map { action in
						{ [weak self] in
							self?.close()
							action()
						}
					} )
			}
			stack.addArrangedSubview( view )
			view.widthAnchor.constraint( equalTo: stack.widthAnchor, constant: -10 ).isActive = true
		}
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
		guard let buttonWindow = button.window, let content = contentView else { return }
		content.layoutSubtreeIfNeeded()
		let size   = NSSize( width: Self.width, height: content.fittingSize.height )
		let anchor = buttonWindow.convertToScreen( button.convert( button.bounds, to: nil ) )
		let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
		var origin = NSPoint( x: anchor.minX, y: anchor.minY - size.height - 4 )
		origin.x   = min( max( origin.x, screen.minX + 4 ), screen.maxX - size.width - 4 )
		setFrame( NSRect( origin: origin, size: size ), display: true )
		makeKeyAndOrderFront( nil )
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
/// the accent color under the pointer as a menu item is. Clicked, it runs its action; it
/// takes the first click even if the panel isn't key.
private final class MenuPanelRowView: NSView {
	private let action     : ( () -> Void )?
	private let iconView   = NSImageView()
	private let titleLabel : NSTextField
	private let detailLabel: NSTextField?
	private var highlighted = false { didSet { updateColors() } }

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

	override func mouseEntered( with event: NSEvent ) { highlighted = action != nil }
	override func mouseExited( with event: NSEvent ) { highlighted = false }

	/// A click never goes to focusing the panel.
	override func acceptsFirstMouse( for event: NSEvent? ) -> Bool { true }

	/// Chosen on release inside, as a menu item is.
	override func mouseDown( with event: NSEvent ) {}
	override func mouseUp( with event: NSEvent ) {
		guard let action, bounds.contains( convert( event.locationInWindow, from: nil ) ) else { return }
		highlighted = false
		action()
	}

	/// White on the accent color while highlighted; gray when it can't be chosen. SF Symbol
	/// icons (templates) follow the text; status icons keep their colors.
	private func updateColors() {
		layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
		titleLabel.textColor   = highlighted ? .white : action == nil ? .secondaryLabelColor : .labelColor
		detailLabel?.textColor = highlighted ? NSColor.white.withAlphaComponent( 0.85 ) : .secondaryLabelColor
		iconView.contentTintColor = highlighted ? .white : .labelColor
	}
}
