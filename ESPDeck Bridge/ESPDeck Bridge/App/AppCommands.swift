//
//  AppCommands.swift
//  ESPDeck Bridge
//
//  The app's menus. Their actions live on the app delegate, the end of the responder
//  chain, and act on the configuration window's WindowState, so they work whichever
//  window is in front and open the configuration window when they need it. A focused
//  text field keeps its keys: Delete and ⌥-arrows don't reach the keys while editing.
//

import UIKit

extension AppDelegate {
	override func buildMenu( with builder: UIMenuBuilder ) {
		super.buildMenu( with: builder )
		guard builder.system == .main else { return }

		// App menu
		builder.remove( menu: .about )
		let about = UIMenu( identifier: UIMenu.Identifier( "com.tmproductions.espdeck.about" ), options: .displayInline, children: [
			UICommand( title: "About ESPDeck Bridge", action: #selector( showAbout ) ),
			UICommand( title: "Check for Updates…", action: #selector( checkForUpdates ) ),
		] )
		builder.insertChild( about, atStartOfMenu: .application )
		if menuBarAvailable {
			builder.insertSibling( UIMenu( options: .displayInline, children: [
				UICommand( title: "Launch at Login", action: #selector( toggleLaunchAtLogin ) ),
			] ), afterMenu: about.identifier )
		}

		// File: the system's New item (New Window before 26)
		if #available( iOS 26.0, * ) {
			builder.remove( menu: .newItem )
		} else {
			builder.remove( menu: .newScene )
		}

		// Quit asks first, as the status item's Quit does.
		builder.replaceChildren( ofMenu: .quit ) { _ in
			[ UIKeyCommand( title: "Quit ESPDeck Bridge", action: #selector( confirmQuit ), input: "q", modifierFlags: .command ) ]
		}
		// ⌘N makes the first model, the Mini.
		let models: [UIMenuElement] = DeckLayout.presets.enumerated().map { index, layout in
			let title = "\(layout.model) (\(layout.keyCount) keys)"
			return index == 0 ? UIKeyCommand( title: title, action: #selector( newDemoDeck( _: ) ), input: "n", modifierFlags: .command, propertyList: layout.model )
							  : UICommand( title: title, action: #selector( newDemoDeck( _: ) ), propertyList: layout.model )
		}
		var file: [UIMenuElement] = [
			UIMenu( title: "New Demo Deck", children: models ),
			// Its own action, as Help ▸ Getting Started has the same sheet.
			UIKeyCommand( title: "Find Your Device", action: #selector( findYourDevice ), input: "f", modifierFlags: [ .command, .shift ] ),
		]
		if menuBarAvailable {
			// Its own action: UIKit rejects two commands with the same action and property list,
			// and View has a USB Setup item too.
			file.append( UIKeyCommand( title: "Set Up Device over USB…", action: #selector( showUSBSetup ), input: "u",
									   modifierFlags: [ .command, .shift ] ) )
		}
		builder.insertChild( UIMenu( options: .displayInline, children: file ), atStartOfMenu: .file )

		// Edit: Copy and Paste are the standard items, which the configuration window
		// answers for the selected key.
		builder.insertSibling( UIMenu( options: .displayInline, children: [
			UIKeyCommand( title: "Clear Key…", action: #selector( clearKey ), input: UIKeyCommand.inputDelete, modifierFlags: [] ),
		] ), afterMenu: .standardEdit )

		// View
		let pages = WindowState.Page.allCases.enumerated().map { index, page in
			UIKeyCommand( title: page.rawValue, action: #selector( showPage( _: ) ), input: "\(index + 1)", modifierFlags: .command,
						  propertyList: page.rawValue )
		}
		// In sidebar order.
		var items = [ ( "Getting Started", SidebarItem.parts ), ( "Updates", SidebarItem.updates ), ( "About", SidebarItem.about ) ]
		if menuBarAvailable {
			items.insert( ( "USB Setup", SidebarItem.usbSetup ), at: 1 )
		}
		let sidebarPages = items.map { title, item in
			UICommand( title: title, action: #selector( showSidebarItem( _: ) ), propertyList: item )
		}
		builder.insertChild( UIMenu( options: .displayInline, children: sidebarPages ), atStartOfMenu: .view )
		builder.insertChild( UIMenu( options: .displayInline, children: pages ), atStartOfMenu: .view )

		// Device
		let devices = controller.devices.prefix( 9 ).enumerated().map { index, device in
			UIKeyCommand( title: controller.settings( device.id )?.name ?? device.id, action: #selector( selectDevice( _: ) ),
						  input: "\(index + 1)", modifierFlags: [ .command, .control ], propertyList: device.id )
		}
		let deviceMenu = UIMenu( title: "Device", identifier: UIMenu.Identifier( "com.tmproductions.espdeck.device" ), children: [
			UIMenu( options: .displayInline, children: [
				UIKeyCommand( title: "Next Device", action: #selector( nextDevice ), input: "]", modifierFlags: .command ),
				UIKeyCommand( title: "Previous Device", action: #selector( previousDevice ), input: "[", modifierFlags: .command ),
			] ),
			UIMenu( options: .displayInline, children: devices ),
			UIMenu( options: .displayInline, children: [
				UICommand( title: "Sleep Now", action: #selector( sleepDevice ) ),
				UICommand( title: "Wake Now", action: #selector( wakeDevice ) ),
				UICommand( title: "Enter Setup Mode", action: #selector( toggleSetupMode ) ),
				UICommand( title: "Install Firmware Update", action: #selector( installFirmwareUpdate ) ),
			] ),
			UIMenu( options: .displayInline, children: [
				UICommand( title: "Forget Device…", action: #selector( forgetDevice ) ),
			] ),
		] )
		builder.insertSibling( deviceMenu, afterMenu: .view )

		// Key
		let arrows = [ ( "Select Key to the Left", UIKeyCommand.inputLeftArrow ), ( "Select Key to the Right", UIKeyCommand.inputRightArrow ),
					   ( "Select Key Above", UIKeyCommand.inputUpArrow ), ( "Select Key Below", UIKeyCommand.inputDownArrow ) ]
		let keyMenu = UIMenu( title: "Key", identifier: UIMenu.Identifier( "com.tmproductions.espdeck.key" ), children: [
			UIMenu( options: .displayInline, children: arrows.map { title, input in
				UIKeyCommand( title: title, action: #selector( moveKeySelection( _: ) ), input: input, modifierFlags: .alternate, propertyList: input )
			} ),
			UIMenu( options: .displayInline, children: [
				UIKeyCommand( title: "Test Action", action: #selector( testAction ), input: "t", modifierFlags: .command ),
			] ),
			UIMenu( options: .displayInline, children: TargetMode.allCases.map { mode in
				UICommand( title: "Assign \(mode == .accessory ? "Accessory" : mode.rawValue)…", action: #selector( assignTarget( _: ) ),
						   propertyList: mode.rawValue )
			} ),
		] )
		builder.insertSibling( keyMenu, afterMenu: deviceMenu.identifier )

		// Help: Getting Started's sheets, on the Mac including the USB path's.
		let sheets = GuideSheet.allCases.filter { menuBarAvailable || $0 != .connect }.map { sheet in
			UICommand( title: sheet.rawValue, action: #selector( showGuideSheet( _: ) ), propertyList: sheet.rawValue )
		}
		builder.replaceChildren( ofMenu: .help ) { _ in
			[ UICommand( title: "ESPDeck Help", action: #selector( openHelp ) ),
			  UIMenu( options: .displayInline, children: [ UIMenu( title: "Getting Started", children: sheets ) ] ) ]
		}
	}

	private var menuBarAvailable: Bool { controller.macBridge != nil }
	private var window: WindowState { controller.window }

	// MARK: - State

	/// The device showing in the configuration window.
	private var currentDevice: DeckDevice? {
		guard window.isShowing, let id = window.selection else { return nil }
		return controller.device( id )
	}

	/// A real device that's connected.
	private var onlineDevice: DeckDevice? {
		guard let device = currentDevice, device.isOnline, controller.settings( device.id )?.isDemo != true else { return nil }
		return device
	}

	/// The selected key, while the Keys page shows and no text is being edited.
	private var currentKey: ( device: String, key: Int )? {
		guard let device = currentDevice, window.page == .keys, !isEditingText else { return nil }
		return ( device.id, window.selectedKey )
	}

	private var isEditingText: Bool {
		UIResponder.firstResponder is UITextInput
	}

	override func canPerformAction( _ action: Selector, withSender sender: Any? ) -> Bool {
		switch action {
			case #selector( toggleLaunchAtLogin ):
				menuBarAvailable
			case #selector( showPage( _: ) ):
				currentDevice != nil
			case #selector( clearKey ), #selector( testAction ), #selector( moveKeySelection( _: ) ):
				currentKey != nil && ( action != #selector( testAction ) || currentAssignmentActs )
			case #selector( assignTarget( _: ) ):
				currentDevice != nil
			case #selector( nextDevice ), #selector( previousDevice ):
				controller.devices.count > 1 || ( currentDevice == nil && !controller.devices.isEmpty )
			case #selector( sleepDevice ):
				onlineDevice.map { !$0.status.asleep } ?? false
			case #selector( wakeDevice ):
				onlineDevice?.status.asleep ?? false
			case #selector( toggleSetupMode ):
				onlineDevice != nil
			case #selector( installFirmwareUpdate ):
				onlineDevice.map { controller.updates.firmwareUpdateAvailable( for: $0 ) && $0.firmwareProgress?.isActive != true && !$0.status.setupMode } ?? false
			case #selector( forgetDevice ):
				currentDevice != nil
			default:
				super.canPerformAction( action, withSender: sender )
		}
	}

	private var currentAssignmentActs: Bool {
		guard let key = currentKey else { return false }
		let assignment = controller.assignment( key.device, key: key.key )
		return assignment.kind != nil && assignment.action != .none
	}

	override func validate( _ command: UICommand ) {
		super.validate( command )
		switch command.action {
			case #selector( toggleLaunchAtLogin ):
				controller.refreshLaunchAtLogin()
				command.state = controller.launchAtLogin == .on ? .on : controller.launchAtLogin == .needsApproval ? .mixed : .off
			case #selector( showPage( _: ) ):
				command.state = currentDevice != nil && window.page.rawValue == command.propertyList as? String ? .on : .off
			case #selector( showSidebarItem( _: ) ), #selector( selectDevice( _: ) ):
				command.state = window.isShowing && window.selection == command.propertyList as? String ? .on : .off
			case #selector( showGuideSheet( _: ) ):
				command.state = window.isShowing && window.selection == SidebarItem.parts && window.guideSheet.rawValue == command.propertyList as? String ? .on : .off
			case #selector( toggleSetupMode ):
				command.title = onlineDevice?.status.setupMode == true ? "Exit Setup Mode" : "Enter Setup Mode"
			case #selector( installFirmwareUpdate ):
				command.title = controller.updates.latestFirmware.map { "Install Firmware \($0.version.description)" } ?? "Install Firmware Update"
			case #selector( forgetDevice ):
				command.title = currentDevice.flatMap { controller.settings( $0.id )?.isDemo } == true ? "Delete Demo Deck…" : "Forget Device…"
			default:
				break
		}
	}

	// MARK: - Showing things

	/// Shows a sidebar item (and a device page) in the configuration window, opening it.
	private func show( _ selection: String, page: WindowState.Page? = nil ) {
		window.selection = selection
		if let page { window.page = page }
		menuBarOpenConfiguration()
	}

	@objc func showAbout() {
		show( SidebarItem.about )
	}

	@objc func checkForUpdates() {
		show( SidebarItem.updates )
		Task { await controller.updates.check( userInitiated: true ) }
	}

	@objc func toggleLaunchAtLogin() {
		controller.setLaunchAtLogin( controller.launchAtLogin != .on )
	}

	@objc func newDemoDeck( _ sender: UICommand ) {
		guard let model = sender.propertyList as? String, let layout = DeckLayout.presets.first( where: { $0.model == model } ) else { return }
		show( controller.addDemoDevice( layout: layout ), page: .keys )
	}

	@objc func showSidebarItem( _ sender: UICommand ) {
		guard let item = sender.propertyList as? String else { return }
		show( item )
	}

	@objc func showPage( _ sender: UICommand ) {
		guard let raw = sender.propertyList as? String, let page = WindowState.Page( rawValue: raw ) else { return }
		window.page = page
	}

	/// A sheet of Getting Started; Connect to This Mac is on the USB path.
	@objc func showGuideSheet( _ sender: UICommand ) {
		guard let raw = sender.propertyList as? String, let sheet = GuideSheet( rawValue: raw ) else { return }
		if sheet == .connect { window.guidePath = .usb }
		window.guideSheet = sheet
		show( SidebarItem.parts )
	}

	@objc func findYourDevice() {
		window.guideSheet = .find
		show( SidebarItem.parts )
	}

	@objc func openHelp() {
		let repository = controller.updates.repository ?? "jangellx/ESPDeck"
		guard let url = URL( string: "https://github.com/\(repository)#readme" ) else { return }
		UIApplication.shared.open( url )
	}

	// MARK: - Devices

	@objc func selectDevice( _ sender: UICommand ) {
		guard let id = sender.propertyList as? String else { return }
		show( id )
	}

	@objc func nextDevice() {
		stepDevice( by: 1 )
	}

	@objc func previousDevice() {
		stepDevice( by: -1 )
	}

	/// In sidebar order, wrapping around.
	private func stepDevice( by step: Int ) {
		let ids = controller.devices.map( \.id )
		guard !ids.isEmpty else { return }
		guard let current = currentDevice.flatMap( { ids.firstIndex( of: $0.id ) } ) else {
			show( ids[0] )
			return
		}
		show( ids[( current + step + ids.count ) % ids.count] )
	}

	@objc func sleepDevice() {
		guard let device = onlineDevice else { return }
		controller.sleep( device: device.id )
	}

	@objc func wakeDevice() {
		guard let device = onlineDevice else { return }
		controller.wake( device: device.id )
	}

	@objc func toggleSetupMode() {
		guard let device = onlineDevice else { return }
		controller.setSetupMode( device: device.id, !device.status.setupMode )
	}

	@objc func installFirmwareUpdate() {
		guard let device = onlineDevice else { return }
		Task { await controller.updates.installFirmware( on: device.id ) }
	}

	/// The Device page's own confirmation.
	@objc func forgetDevice() {
		guard currentDevice != nil else { return }
		window.page             = .device
		window.confirmingForget = true
	}

	// MARK: - Keys

	/// The Key Inspector's own confirmation.
	@objc func clearKey() {
		guard currentKey != nil else { return }
		window.confirmingClearKey = true
	}

	@objc func testAction() {
		guard let key = currentKey else { return }
		controller.press( device: key.device, key: key.key )
	}

	@objc func assignTarget( _ sender: UICommand ) {
		guard currentDevice != nil, let raw = sender.propertyList as? String, let mode = TargetMode( rawValue: raw ) else { return }
		window.page                = .keys
		window.requestedTargetMode = mode
	}

	/// ⌥-arrows from the Key menu, and plain arrows while the deck preview has focus.
	@objc func confirmQuit() {
		if let menuBar {
			menuBar.confirmQuit()
		} else {
			exit( 0 )   // no plugin (iPad): nothing to ask through
		}
	}

	@objc func showUSBSetup() {
		show( SidebarItem.usbSetup )
	}

	@objc func moveKeySelection( _ sender: UIKeyCommand ) {
		guard let key = currentKey else { return }
		let layout = controller.layout( key.device )
		var row    = key.key / layout.cols
		var column = key.key % layout.cols
		switch sender.input {
			case UIKeyCommand.inputLeftArrow:  column = max( column - 1, 0 )
			case UIKeyCommand.inputRightArrow: column = min( column + 1, layout.cols - 1 )
			case UIKeyCommand.inputUpArrow:    row = max( row - 1, 0 )
			case UIKeyCommand.inputDownArrow:  row = min( row + 1, layout.rows - 1 )
			default:                           return
		}
		window.selectedKey = row * layout.cols + column
	}
}

extension UIResponder {
	private static weak var found: UIResponder?

	/// The first responder, found by sending an action to it.
	static var firstResponder: UIResponder? {
		found = nil
		UIApplication.shared.sendAction( #selector( markFirstResponder ), to: nil, from: nil, for: nil )
		return found
	}

	@objc private func markFirstResponder() {
		UIResponder.found = self
	}
}
