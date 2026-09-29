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

	override func viewDidLoad() {
		super.viewDidLoad()
		// Shift-click in the deck preview runs the key. SwiftUI's modifier gestures aren't
		// available to Catalyst, so a recognizer here that only begins with Shift held, over a
		// key the preview reported (DeckKeyView), and otherwise leaves clicks alone.
		let shiftPress = UILongPressGestureRecognizer( target: self, action: #selector( shiftPressed( _: ) ) )
		shiftPress.minimumPressDuration = 0
		shiftPress.delegate             = self
		view.addGestureRecognizer( shiftPress )
	}

	/// The key under a shift-press, while it's held.
	private var shiftPressedKey: ( device: String, key: Int )?

	/// `point` in window coordinates, which SwiftUI's global frames are in.
	private func previewKey( at point: CGPoint ) -> Int? {
		controller.previewKeyFrames.first { $0.value.contains( point ) }?.key
	}

	@objc private func shiftPressed( _ recognizer: UILongPressGestureRecognizer ) {
		switch recognizer.state {
			case .began:
				guard let device = controller.previewDevice, let key = previewKey( at: recognizer.location( in: nil ) ) else { return }
				shiftPressedKey = ( device, key )
				controller.window.selectedKey = key
				controller.previewPress( device: device, key: key, down: true )
			case .ended, .cancelled, .failed:
				if let pressed = shiftPressedKey {
					controller.previewPress( device: pressed.device, key: pressed.key, down: false )
				}
				shiftPressedKey = nil
			default:
				break
		}
	}

	override func viewDidAppear( _ animated: Bool ) {
		super.viewDidAppear( animated )
		becomeFirstResponder()
		controller.refreshClipboard()
		controller.undoManager = undoManager   // the window's, which Edit ▸ Undo uses
	}

	override func canPerformAction( _ action: Selector, withSender sender: Any? ) -> Bool {
		switch action {
			case #selector( copy( _: ) ):  controller.focusedKey != nil
			case #selector( paste( _: ) ): controller.focusedKey != nil && controller.clipboardHasKey
			default:                       super.canPerformAction( action, withSender: sender )
		}
	}

	/// Only reached with this controller answering (a text field being edited answers for
	/// itself, as plain Copy and Paste).
	override func validate( _ command: UICommand ) {
		super.validate( command )
		switch command.action {
			case #selector( copy( _: ) ):  command.title = "Copy Key"
			case #selector( paste( _: ) ): command.title = "Paste Key"
			default:                       break
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

extension ConfigurationHostingController: UIGestureRecognizerDelegate {
	func gestureRecognizerShouldBegin( _ recognizer: UIGestureRecognizer ) -> Bool {
		recognizer.modifierFlags.contains( .shift ) && previewKey( at: recognizer.location( in: nil ) ) != nil
	}
}
