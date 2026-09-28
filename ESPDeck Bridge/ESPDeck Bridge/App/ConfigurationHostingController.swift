//
//  ConfigurationHostingController.swift
//  ESPDeck Bridge
//
//  Hosts the configuration window and answers Edit ▸ Copy / Paste (Cmd-C / Cmd-V) for
//  the selected key. A focused text field sits earlier in the responder chain, so it
//  still copies and pastes text normally.
//

import SwiftUI

final class ConfigurationHostingController: UIHostingController<ConfigurationView> {
	private let controller: DeckController

	/// The configuration window's controller; there's only ever one.
	private static weak var current: ConfigurationHostingController?

	/// Makes Edit ▸ Copy / Paste act on keys: becoming first responder takes focus from
	/// any text field, and puts this controller at the start of the responder chain.
	static func takeKeyboardFocus() {
		current?.becomeFirstResponder()
	}

	init( controller: DeckController ) {
		self.controller = controller
		super.init( rootView: ConfigurationView( controller: controller ) )
		Self.current = self
	}

	@available( *, unavailable )
	required init?( coder: NSCoder ) {
		fatalError( "init(coder:) is not used" )
	}

	override var canBecomeFirstResponder: Bool { true }

	/// Arrow keys move the key selection while the deck preview has focus: clicking a key
	/// makes this controller first responder, and a focused text field keeps them.
	override var keyCommands: [UIKeyCommand]? {
		[ UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow ].map { input in
			let command = UIKeyCommand( input: input, modifierFlags: [], action: #selector( AppDelegate.moveKeySelection( _: ) ) )
			command.wantsPriorityOverSystemBehavior = true
			return command
		}
	}

	override func viewDidAppear( _ animated: Bool ) {
		super.viewDidAppear( animated )
		becomeFirstResponder()
		controller.refreshClipboard()
	}

	override func canPerformAction( _ action: Selector, withSender sender: Any? ) -> Bool {
		switch action {
			case #selector( copy( _: ) ):  controller.focusedKey != nil
			case #selector( paste( _: ) ): controller.focusedKey != nil && controller.clipboardHasKey
			default:                       super.canPerformAction( action, withSender: sender )
		}
	}

	override func copy( _ sender: Any? ) {
		guard let focused = controller.focusedKey else { return }
		controller.copyKey( device: focused.device, key: focused.key )
	}

	override func paste( _ sender: Any? ) {
		guard let focused = controller.focusedKey else { return }
		controller.pasteKey( device: focused.device, key: focused.key )
	}
}
