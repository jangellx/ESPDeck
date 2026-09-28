//
//  USBSetup.swift
//  ESPDeck Bridge
//
//  Setting up a board plugged into this Mac (Mac only; the AppKit bundle does the serial
//  work): install firmware through its ROM bootloader, then give it Wi-Fi and a name
//  with Improv. Once on Wi-Fi it finds this bridge by itself, and pairing takes over.
//
//  Other ESP32 work may be going on at this Mac, so a port is open only briefly: once
//  when a board appears, to ask what it runs and which network it's set up for (only on
//  the ESP32's own USB port, where opening can't restart it), and for each action the user
//  starts. Retries happen only
//  while a board this app just restarted is expected back.
//

import Foundation
import Observation

@Observable
final class USBSetup {
	/// A serial port, described in words where the USB IDs allow.
	struct Port: Identifiable, Equatable {
		var path      : String
		var product   : String
		var vendor    : String
		var vendorID  : Int?
		var productID : Int?
		var location  : Int?
		/// The USB serial number; "" when there's none.
		var serial    : String

		var id: String { path }

		static let espressif = 0x303A

		init?( fields: [String] ) {
			guard fields.count >= 6 else { return nil }
			path      = fields[0]
			product   = fields[1]
			vendor    = fields[2]
			vendorID  = Int( fields[3] )
			productID = Int( fields[4] )
			location  = Int( fields[5] )
			serial    = fields.count > 6 ? fields[6] : ""
		}

		/// The device ID of the board on this port, where the port gives it: the ESP32-S3's
		/// own USB port has the chip's MAC address as its serial number ("7C:4F:AD:BB:D9:78"),
		/// and ESPDeck's device ID is that MAC in lowercase. Serial chips have their own.
		var deviceID: String? {
			guard isEspressif else { return nil }
			let parts = serial.split( separator: ":", omittingEmptySubsequences: false )
			guard parts.count == 6, parts.allSatisfy( { $0.count == 2 && $0.allSatisfy( \.isHexDigit ) } ) else { return nil }
			return serial.lowercased()
		}

		/// An ESP32's own USB port, or a USB-to-serial chip that dev boards use.
		var isLikelyBoard: Bool {
			isEspressif || [ 0x1A86, 0x10C4, 0x0403 ].contains( vendorID ?? 0 )
		}

		var isEspressif: Bool { vendorID == Self.espressif }

		var title: String {
			switch ( vendorID, productID ) {
				case ( Self.espressif, 0x1001 ): "ESP32-S3 on its USB port"
				case ( Self.espressif, 0x0009 ): "ESP32-S3 in flashing mode"
				case ( Self.espressif, _ ):      "ESP32 running other firmware"
				case ( 0x1A86, _ ):              "Board on a USB serial chip (WCH)"
				case ( 0x10C4, _ ):              "Board on a USB serial chip (Silicon Labs)"
				case ( 0x0403, _ ):              "Board on a USB serial chip (FTDI)"
				default:                         product.isEmpty ? fileName : product
			}
		}

		var fileName: String { ( path as NSString ).lastPathComponent }
	}

	/// What the board said about itself over Improv.
	struct DeviceInfo: Equatable {
		var firmware : String
		var version  : String
		var chip     : String
		var name     : String
		/// The network it's set up for; nil from firmware that doesn't say (before 4.1.0).
		var network  : SavedNetwork?

		var isESPDeck: Bool { firmware == FirmwareImage.projectName }
	}

	/// The Wi-Fi network in the board's settings. Only its name: the password never leaves it.
	struct SavedNetwork: Equatable {
		/// "" when it has none.
		var ssid      : String
		/// Whether it's on that network now.
		var connected : Bool
	}

	enum Answer: Equatable {
		case asking
		case answered( DeviceInfo )
		case silent
		/// On a USB-to-serial chip, opening the port can restart the board, so it's asked
		/// only when the user clicks.
		case notAsked
	}

	struct Board: Identifiable, Equatable {
		var port     : Port
		var answer   : Answer
		/// What the bootloader reported during an install: "ESP32-S3, 16 MB flash, 8 MB PSRAM".
		var hardware : String?

		var id: String { port.path }

		var info: DeviceInfo? {
			if case .answered( let info ) = answer { return info }
			return nil
		}

		var espDeck: DeviceInfo? { info.flatMap { $0.isESPDeck ? $0 : nil } }
	}

	enum Source: Hashable {
		case release
		case file( URL )
	}

	/// A full image picked with Choose File, read and checked once when it was chosen.
	struct ChosenFile {
		var url     : URL
		var regions : [FirmwareImage.Region]
		var version : String
	}

	enum Install: Equatable {
		case idle
		case preparing( String )
		case running( stage: String, fraction: Double )
		case finished( String )
		case failed( String )

		var isBusy: Bool {
			switch self {
				case .preparing, .running: true
				default:                   false
			}
		}
	}

	struct Network: Identifiable, Equatable {
		var ssid   : String
		var rssi   : Int
		var secure : Bool

		var id: String { ssid }
	}

	enum WiFi: Equatable {
		case idle
		case joining( String )
		case joined( String )
		case failed( String )
	}

	enum Rename: Equatable {
		case idle
		case saving
		case failed( String )
	}

	/// The board that joined a network, remembered after it's unplugged, to find it when
	/// it connects to this bridge.
	struct JoinedBoard: Equatable {
		var path     : String
		var deviceID : String?
		var name     : String
	}

	@ObservationIgnored private weak var controller: DeckController?

	private(set) var boards          : [Board] = []
	var selectedPath                 : String?
	var source                       = Source.release
	private(set) var chosenFile      : ChosenFile?
	private(set) var install         = Install.idle
	private(set) var networks        : [Network] = []
	private(set) var findingNetworks = false
	private(set) var wifi            = WiFi.idle
	private(set) var rename          = Rename.idle
	private(set) var joinedBoard     : JoinedBoard?

	@ObservationIgnored private var watching           = false
	@ObservationIgnored private var ports              : [Port] = []
	/// The USB socket of a board being installed; its ports come and go meanwhile.
	@ObservationIgnored private var installingLocation : Int?
	/// What installs found out about the board in each USB socket.
	@ObservationIgnored private var hardware           : [Int: String] = [:]
	/// A board this app restarted, expected back in this socket until the deadline.
	@ObservationIgnored private var expected           : ( location: Int?, until: ContinuousClock.Instant )?
	/// Port work runs one piece at a time: the AppKit bundle has one Improv session.
	@ObservationIgnored private var queue              : Task<Void, Never>?
	@ObservationIgnored private var inbox              : [Packet] = []
	@ObservationIgnored private var session            = 0
	/// Boards whose networks were looked for without being asked, by device ID or port.
	@ObservationIgnored private var scannedBoards      : Set<String> = []

	/// An Improv packet, or the port closing (`closed` set).
	private struct Packet {
		var type    : Int
		var value   : Int
		var strings : [String]
		var closed  : String?
	}

	// Improv (https://www.improv-wifi.com/serial/)
	private enum Improv {
		static let typeError  = 0x02
		static let typeResult = 0x04

		static let sendWiFi   = 0x01
		static let getInfo    = 0x03
		static let scan       = 0x04
		static let deviceName = 0x06
		/// ESPDeck's own command (firmware 4.1.0 and later): the saved network's name, and
		/// "YES" or "NO" for whether it's on it. Earlier firmware answers unknownCommand.
		static let wifiNetwork = 0xFE

		static let unknownCommand = 0x02

		/// An RPC's data: the packet's length byte also covers the command and its own length.
		static let maximumData    = 253
		/// 802.11's limit on a network name.
		static let maximumSSID    = 32
	}

	init( controller: DeckController ) {
		self.controller = controller
	}

	private var bridge: DeckMenuBarPlugin? { controller?.macBridge }

	var isAvailable: Bool { bridge != nil }

	/// "Look for boards plugged in over USB". Off, nothing is watched or opened.
	var scanning: Bool {
		get { controller?.config.settings.usbScanning ?? false }
		set {
			controller?.config.settings.usbScanning = newValue
			newValue ? start() : stop()
		}
	}

	/// Boards plugged in, for the sidebar's badge.
	var boardCount: Int { boards.count }

	/// The board to act on: the only one, or the one picked in the list.
	var selectedBoard: Board? {
		boards.first { $0.port.path == selectedPath } ?? ( boards.count == 1 ? boards.first : nil )
	}

	// MARK: - Watching

	/// Watches for boards while scanning is on; called at launch.
	func start() {
		guard let bridge, scanning, !watching else { return }
		watching = true
		bridge.watchSerialPorts { [weak self] fields in
			self?.portsChanged( fields.compactMap( Port.init( fields: ) ).filter( \.isLikelyBoard ) )
		}
	}

	private func stop() {
		guard watching else { return }
		watching = false
		bridge?.stopWatchingSerialPorts()
		closePort()
		ports  = []
		boards = []
	}

	/// Keeps boards still plugged in, asks new ones what they run, and follows a board
	/// that comes back as another port in the same USB socket (restarting into its
	/// bootloader or into new firmware).
	private func portsChanged( _ list: [Port] ) {
		ports = list
		var next: [Board] = []
		for port in list {
			if var board = boards.first( where: { $0.port.path == port.path } ) {
				board.port = port
				next.append( board )
				continue
			}
			// Mid-install, the installer owns the socket's ports.
			if install.isBusy, port.location != nil, port.location == installingLocation { continue }

			let previous = boards.first { old in
				old.port.location != nil && old.port.location == port.location && !list.contains { $0.path == old.port.path }
			}
			var board = Board( port: port, answer: port.isEspressif ? .asking : .notAsked, hardware: port.location.flatMap { hardware[$0] } )
			if let previous, selectedPath == previous.port.path {
				selectedPath = port.path
			}
			if !port.isEspressif, let previous {
				board.answer = previous.answer   // the same board, on another port of the chip
			}
			next.append( board )
		}
		// A board being installed stays while its port is away.
		if install.isBusy, let installing = boards.first( where: { $0.port.location == installingLocation } ),
		   !next.contains( where: { $0.port.location == installingLocation } ) {
			next.append( installing )
		}

		let added = next.filter { board in !boards.contains { $0.port.path == board.port.path } }
		boards = next
		if selectedPath == nil || !boards.contains( where: { $0.port.path == selectedPath } ) {
			selectedPath = boards.first?.port.path
		}
		for board in added where board.port.isEspressif {
			let restarting = expected.map { $0.location == board.port.location && ContinuousClock.now < $0.until } ?? false
			if restarting { selectedPath = board.port.path }
			ask( board.port.path, attempts: restarting ? 12 : 1 )
		}
	}

	private func update( _ path: String, _ change: ( inout Board ) -> Void ) {
		guard let index = boards.firstIndex( where: { $0.port.path == path } ) else { return }
		change( &boards[index] )
	}

	// MARK: - The port

	/// Runs `work` after whatever port work is already queued.
	private func enqueue( _ work: @escaping () async -> Void ) {
		let previous = queue
		queue = Task {
			await previous?.value
			await work()
		}
	}

	/// Opens a board's port for Improv. False if it couldn't be opened.
	private func openPort( _ path: String ) -> Bool {
		guard let bridge else { return false }
		closePort()
		session += 1
		let current = session
		bridge.startImprov( port: path ) { [weak self] type, value, strings in
			guard let self, session == current else { return }
			inbox.append( Packet( type: type, value: value, strings: strings ) )
		} log: { _ in
		} stopped: { [weak self] error in
			guard let self, session == current else { return }
			inbox.append( Packet( type: 0, value: 0, strings: [], closed: error ?? "closed" ) )
		}
		return !inbox.contains { $0.closed != nil }
	}

	private func closePort() {
		session += 1
		inbox = []
		bridge?.stopImprov()
	}

	private func send( _ command: Int, data: Data = Data() ) -> Bool {
		bridge?.sendImprov( command: command, data: data ) == nil
	}

	/// Waits up to `timeout` for a packet `match` turns into a value. Nil on a timeout, or
	/// if the port closed.
	private func wait<Value>( _ timeout: Duration, _ match: ( Packet ) -> Value? ) async -> Value? {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			while !inbox.isEmpty {
				let packet = inbox.removeFirst()
				if packet.closed != nil { return nil }
				if let value = match( packet ) { return value }
			}
			try? await Task.sleep( for: .milliseconds( 100 ) )
		}
		return nil
	}

	/// Asks what the board runs, then closes the port. More attempts only when a board
	/// is expected to be starting up.
	private func ask( _ path: String, attempts: Int ) {
		update( path ) { $0.answer = .asking }
		enqueue { [weak self] in
			guard let self, boards.contains( where: { $0.port.path == path } ) else { return }
			var answer = Answer.silent
			for attempt in 0..<attempts {
				if attempt > 0 { try? await Task.sleep( for: .seconds( 1 ) ) }
				guard boards.contains( where: { $0.port.path == path } ) else { return }
				guard openPort( path ) else { continue }
				if send( Improv.getInfo ), var info = await wait( .milliseconds( 1500 ), { packet -> DeviceInfo? in
					guard packet.type == Improv.typeResult, packet.value == Improv.getInfo, packet.strings.count >= 4 else { return nil }
					return DeviceInfo( firmware: packet.strings[0], version: packet.strings[1], chip: packet.strings[2], name: packet.strings[3] )
				} ) {
					if info.isESPDeck { info.network = await askNetwork() }
					answer = .answered( info )
				}
				closePort()
				if case .answered = answer { break }
			}
			update( path ) { $0.answer = answer }
		}
	}

	/// The network an ESPDeck board is set up for, on the port that's open. Nil when its
	/// firmware doesn't know the command (it says so at once) or doesn't answer quickly.
	private func askNetwork() async -> SavedNetwork? {
		guard send( Improv.wifiNetwork ) else { return nil }
		let answer = await wait( .milliseconds( 700 ) ) { packet -> SavedNetwork?? in
			if packet.type == Improv.typeResult, packet.value == Improv.wifiNetwork, let ssid = packet.strings.first {
				return SavedNetwork( ssid: DeviceMessage.displayName( ssid ) ?? "", connected: packet.strings.count > 1 && packet.strings[1] == "YES" )
			}
			if packet.type == Improv.typeError, packet.value != 0 { return .some( nil ) }
			return nil
		}
		return answer ?? nil
	}

	/// Asks a board the user picked, e.g. one on a USB-to-serial chip.
	func ask( _ board: Board ) {
		ask( board.port.path, attempts: 1 )
	}

	// MARK: - Installing firmware

	/// The version the selected source installs, when it's known before downloading.
	var sourceVersion: String? {
		switch source {
			case .release:
				controller?.updates.latestFirmware?.version.description
			case .file( let url ):
				chosenFile.flatMap { $0.url == url ? $0.version : nil }
		}
	}

	/// Reads and checks a full image from Choose File, and makes it the source.
	func choose( _ url: URL ) throws {
		let image            = try Self.read( url )
		let ( regions, app ) = try FirmwareImage.regions( fullImage: image )
		chosenFile = ChosenFile( url: url, regions: regions, version: app.version )
		source     = .file( url )
	}

	func installFirmware() {
		guard let bridge, let board = selectedBoard, !install.isBusy else { return }
		let source         = self.source
		let location       = board.port.location
		installingLocation = location
		wifi               = .idle
		rename             = .idle
		joinedBoard        = nil
		install            = .preparing( "Getting the firmware…" )

		Task {
			let regions: [FirmwareImage.Region]
			let version: String
			do {
				( regions, version ) = try await firmware( for: source )
			} catch {
				install            = .failed( error.localizedDescription )
				installingLocation = nil
				return
			}
			let minimum = FirmwareImage.requiredFlashSize( regions ) ?? 16 * 1024 * 1024
			install = .running( stage: "Waiting for the board…", fraction: 0 )

			enqueue {
				await withCheckedContinuation { ( done: CheckedContinuation<Void, Never> ) in
					bridge.installFirmware( port: board.port.path, offsets: regions.map( \.offset ), images: regions.map( \.data ),
											minimumFlashSize: minimum ) { found in
						if let location { self.hardware[location] = found }
						for index in self.boards.indices where self.boards[index].port.location == location {
							self.boards[index].hardware = found
						}
					} progress: { stage, fraction in
						guard self.install.isBusy else { return }
						self.install = .running( stage: stage, fraction: fraction )
					} completion: { error, port in
						self.finishInstall( error: error, version: version, port: port, location: location )
						done.resume()
					}
				}
			}
		}
	}

	/// Either way the board restarts (into its old firmware after a refusal), so it's
	/// expected back, and asked again once it has had time to start. On its own USB port it
	/// usually drops off the bus for a moment; then it's asked when it's back.
	private func finishInstall( error: String?, version: String, port: String, location: Int? ) {
		install            = error.map { .failed( $0 ) } ?? .finished( "ESPDeck \(version) is installed, and the board is restarting." )
		installingLocation = nil
		expected           = ( location, ContinuousClock.now + .seconds( 30 ) )

		selectedPath = port
		guard let current = ports.first( where: { $0.path == port } ) else {
			// Away: it's asked when it's back, as a board expected back.
			boards.removeAll { $0.port.location == location }
			return
		}
		boards.removeAll { $0.port.location == location && $0.port.path != port }
		if !boards.contains( where: { $0.port.path == port } ) {
			boards.append( Board( port: current, answer: .asking, hardware: location.flatMap { hardware[$0] } ) )
		}
		update( port ) { $0.answer = .asking }
		Task {
			// ESPDeck takes a moment to start and to decide its USB port stays a serial port.
			try? await Task.sleep( for: .seconds( 3 ) )
			ask( port, attempts: 12 )
		}
	}

	func cancelInstall() {
		bridge?.cancelFirmwareInstall()
	}

	/// The regions to write, and the version being installed.
	private func firmware( for source: Source ) async throws -> ( [FirmwareImage.Region], String ) {
		switch source {
			case .release:
				guard let updates = controller?.updates else { throw CancellationError() }
				install = .preparing( "Downloading the latest firmware…" )
				let ( image, version ) = try await updates.downloadFullFirmware()
				return ( try FirmwareImage.regions( fullImage: image ).regions, version )
			case .file( let url ):
				guard let chosenFile, chosenFile.url == url else { throw FileProblem.notChosen }
				return ( chosenFile.regions, chosenFile.version )
		}
	}

	enum FileProblem: LocalizedError {
		case tooLarge
		case notChosen

		var errorDescription: String? {
			switch self {
				case .tooLarge:  "That file is too large to be ESPDeck firmware."
				case .notChosen: "Choose the firmware file again."
			}
		}
	}

	/// No ESP32-S3 has more flash than this, so no full image is larger.
	static let maximumFileSize = 32 * 1024 * 1024

	/// A file from the file picker, which may be outside what the app can read by itself.
	static func read( _ url: URL ) throws -> Data {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		if let size = try url.resourceValues( forKeys: [ .fileSizeKey ] ).fileSize, size > maximumFileSize {
			throw FileProblem.tooLarge
		}
		return try Data( contentsOf: url )
	}

	// MARK: - Wi-Fi and name

	/// Opens the selected board's port for one action, then closes it.
	private func withSelectedBoard( _ action: @escaping ( String ) async -> Void ) {
		guard let path = selectedBoard?.port.path else { return }
		enqueue { [weak self] in
			guard let self else { return }
			await action( path )
			closePort()
		}
	}

	/// Looks for networks the first time a board that can be asked is showing, so the
	/// Network menu is filled in by the time it's needed. Once per board while the app runs.
	func findNetworksOnce() {
		guard let board = selectedBoard, board.espDeck != nil, !findingNetworks else { return }
		guard scannedBoards.insert( board.port.deviceID ?? board.port.path ).inserted else { return }
		findNetworks()
	}

	func findNetworks() {
		guard selectedBoard?.espDeck != nil, !findingNetworks else { return }
		findingNetworks = true
		withSelectedBoard { [weak self] path in
			guard let self else { return }
			defer { findingNetworks = false }
			guard openPort( path ), send( Improv.scan ) else { return }
			var found: [Network] = []
			let finished = await wait( .seconds( 20 ) ) { packet -> Bool? in
				guard packet.type == Improv.typeResult, packet.value == Improv.scan else { return nil }
				guard packet.strings.count >= 3 else { return true }   // the empty result ends the list
				found.append( Network( ssid: packet.strings[0], rssi: Int( packet.strings[1] ) ?? -100, secure: packet.strings[2] == "YES" ) )
				return nil
			}
			if finished != nil { networks = found }
		}
	}

	/// Sends the network and password, and waits for the board to join or give up.
	func join( ssid: String, password: String ) {
		guard let board = selectedBoard, let info = board.espDeck else { return }
		let data: Data
		switch Self.wifiSettings( ssid: ssid, password: password ) {
			case .success( let settings ): data = settings
			case .failure( let problem ):
				wifi = .failed( problem.message )
				return
		}
		wifi        = .joining( ssid )
		joinedBoard = nil
		withSelectedBoard { [weak self] path in
			guard let self else { return }
			guard openPort( path ), send( Improv.sendWiFi, data: data ) else {
				wifi = .failed( "Couldn't reach the board." )
				return
			}
			// The firmware gives up after 20 seconds.
			let joined = await wait( .seconds( 30 ) ) { packet -> Bool? in
				if packet.type == Improv.typeResult && packet.value == Improv.sendWiFi { return true }
				if packet.type == Improv.typeError && packet.value != 0 { return false }
				return nil
			}
			if joined == true {
				let name    = boards.first( where: { $0.port.path == path } )?.espDeck?.name ?? info.name
				joinedBoard = JoinedBoard( path: path, deviceID: board.port.deviceID, name: name )
				// It saved the network; firmware that can't say which keeps saying nothing.
				update( path ) { board in
					guard case .answered( var info ) = board.answer, info.network != nil else { return }
					info.network = SavedNetwork( ssid: ssid, connected: true )
					board.answer = .answered( info )
				}
			}
			wifi = switch joined {
				case true?:  .joined( ssid )
				case false?: .failed( "Couldn't join the network. Check the password, and that it's a 2.4 GHz network." )
				case nil:    .failed( "The board didn't say whether it joined the network." )
			}
		}
	}

	struct FieldProblem: Error, Equatable {
		var message: String
	}

	/// Improv's Wi-Fi settings: the network name and password, each a length byte and its
	/// bytes, all within one RPC.
	static func wifiSettings( ssid: String, password: String ) -> Result<Data, FieldProblem> {
		let name = Data( ssid.utf8 ), secret = Data( password.utf8 )
		guard !name.isEmpty else { return .failure( FieldProblem( message: "Choose a network to join." ) ) }
		guard name.count <= Improv.maximumSSID else {
			return .failure( FieldProblem( message: "A Wi-Fi network name can be at most \(Improv.maximumSSID) bytes long." ) )
		}
		guard 2 + name.count + secret.count <= Improv.maximumData else {
			return .failure( FieldProblem( message: "That password is too long to send to the board." ) )
		}
		var data = Data()
		for bytes in [ name, secret ] {
			data.append( UInt8( bytes.count ) )
			data.append( bytes )
		}
		return .success( data )
	}

	/// Improv's device name command, which ESPDeck stores like a rename from the bridge.
	func setName( _ name: String ) {
		guard selectedBoard?.espDeck != nil else { return }
		guard name.utf8.count <= Improv.maximumData else {
			rename = .failed( "That name is too long." )
			return
		}
		rename = .saving
		withSelectedBoard { [weak self] path in
			guard let self else { return }
			guard openPort( path ), send( Improv.deviceName, data: Data( name.utf8 ) ) else {
				rename = .failed( "Couldn't reach the board." )
				return
			}
			// The new name, or the error code.
			let answer = await wait( .seconds( 5 ) ) { packet -> ( name: String?, error: Int? )? in
				if packet.type == Improv.typeResult, packet.value == Improv.deviceName, let name = packet.strings.first { return ( name, nil ) }
				if packet.type == Improv.typeError, packet.value != 0 { return ( nil, packet.value ) }
				return nil
			}
			if let name = answer?.name {
				update( path ) { board in
					guard case .answered( var info ) = board.answer else { return }
					info.name    = name
					board.answer = .answered( info )
				}
				if joinedBoard?.path == path { joinedBoard?.name = name }
				rename = .idle
			} else if answer?.error == Improv.unknownCommand {
				rename = .failed( "This firmware can't be renamed over USB. Install the current firmware, or rename the device in ESPDeck Bridge once it's connected." )
			} else {
				rename = .failed( answer == nil ? "The board didn't answer." : "The board didn't accept that name." )
			}
		}
	}

	// MARK: - After Wi-Fi

	/// Where the board that joined a network shows up once it has found this bridge: the
	/// sidebar item to select, and whether it still needs pairing. Found by its device ID
	/// where its USB port gave it, since a board renamed after it first connected can still
	/// be listed under its old name; by name otherwise.
	func arrival( of board: JoinedBoard ) -> ( selection: String, needsPairing: Bool )? {
		guard let controller else { return nil }
		if let id = board.deviceID {
			if let new = controller.newDevices.first( where: { $0.hello.id == id } ) {
				return ( SidebarItem.newDevice( new.client ), true )
			}
			if let device = controller.device( id ), device.isOnline {
				return ( device.id, false )
			}
			return nil
		}
		if let new = controller.newDevices.first( where: { $0.hello.name == board.name } ) {
			return ( SidebarItem.newDevice( new.client ), true )
		}
		if let device = controller.devices.first( where: { $0.isOnline && controller.settings( $0.id )?.name == board.name } ) {
			return ( device.id, false )
		}
		return nil
	}
}
