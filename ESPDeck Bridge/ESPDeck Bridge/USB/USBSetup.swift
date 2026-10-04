//
//  USBSetup.swift
//  ESPDeck Bridge
//
//  Setting up a board plugged into this Mac (Mac only; the AppKit bundle does the serial
//  work): install firmware through its ROM bootloader, then give it Wi-Fi and a name
//  with Improv. Once on Wi-Fi it finds this bridge by itself, and pairing takes over.
//
//  Other ESP32 work may be going on at this Mac, so a port is open only briefly: once
//  when a board appears, to ask what it runs, which network it's set up for and how it
//  stores its settings (only on the ESP32's own USB port, where opening can't restart it),
//  and for each action the user starts. Retries happen only while a board this app just
//  restarted is expected back.
//

import Foundation
import Observation

/// Finds boards plugged in over USB, and installs, joins, renames and unpairs them.
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

		/// From the AppKit bundle's port list: path, product, vendor, vendor ID, product ID,
		/// location, and the serial number where there is one.
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

		/// What's on the port, in words: an ESP32 and its state, or the serial chip's maker.
		var title: String {
			switch ( vendorID, productID ) {
				case ( Self.espressif, 0x1001 ): "ESP32-S3 on its USB port"
				case ( Self.espressif, 0x0009 ): "ESP32-S3 in flashing mode"
				case ( Self.espressif, _ ):      "ESP32 board running other firmware"
				case ( 0x1A86, _ ):              "Board on a USB serial chip (WCH)"
				case ( 0x10C4, _ ):              "Board on a USB serial chip (Silicon Labs)"
				case ( 0x0403, _ ):              "Board on a USB serial chip (FTDI)"
				default:                         product.isEmpty ? fileName : product
			}
		}

		/// The port's device file name, e.g. "cu.usbmodem1101".
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
		/// How it stores its settings; nil from firmware that doesn't say (before 4.1.0).
		var storage  : Storage?
		/// The bridge it's paired with, "" if none; nil from firmware that doesn't say.
		var pairedBridge: String?

		var isESPDeck: Bool { firmware == FirmwareImage.projectName }
	}

	/// The Wi-Fi network in the board's settings. Only its name: the password never leaves it.
	struct SavedNetwork: Equatable {
		/// "" when it has none.
		var ssid      : String
		/// Whether it's on that network now.
		var connected : Bool
		/// Its name on the network (hostname); nil from firmware that doesn't say.
		var hostname  : String?
	}

	/// How the board stores its settings (Wi-Fi password, pairing key), and what joining a
	/// network will do about it. See PROTOCOL.md, USB (Improv serial).
	struct Storage: Equatable {
		/// "plain", "encrypted", or "unsupported" (plain, and the chip can't encrypt).
		var state : String
		/// What saving its first network does: "encrypt", "standard", or "none" when there's
		/// nothing to choose (it's set up already, or its storage isn't plain).
		var setup : String

		var isEncrypted: Bool { state == "encrypted" }
		/// A new board with plain storage: joining a network encrypts it, unless Standard is chosen.
		var offersChoice: Bool { state == "plain" && setup != "none" }
	}

	/// Whether and how a board answered being asked what it runs.
	enum Answer: Equatable {
		case asking
		case answered( DeviceInfo )
		case silent
		/// On a USB-to-serial chip, opening the port can restart the board, so it's asked
		/// only when the user clicks.
		case notAsked
	}

	/// A board plugged in, and what's known about it.
	struct Board: Identifiable, Equatable {
		var port     : Port
		var answer   : Answer
		/// What the bootloader reported during an install: "ESP32-S3, 16 MB flash, 8 MB PSRAM".
		var hardware : String?

		var id: String { port.path }

		/// What it said about itself, if it answered.
		var info: DeviceInfo? {
			if case .answered( let info ) = answer { return info }
			return nil
		}

		/// What it said, if it runs ESPDeck.
		var espDeck: DeviceInfo? { info.flatMap { $0.isESPDeck ? $0 : nil } }
	}

	/// Where the firmware to install comes from.
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

	/// How installing firmware is going.
	enum Install: Equatable {
		case idle
		case preparing( String )
		case running( stage: String, fraction: Double )
		case finished( String )
		case failed( String )

		/// Preparing or running: the board and the rest of the page wait.
		var isBusy: Bool {
			switch self {
				case .preparing, .running: true
				default:                   false
			}
		}
	}

	/// A Wi-Fi network the board can see.
	struct Network: Identifiable, Equatable {
		var ssid   : String
		/// Signal strength in dBm; not shown, but a rescan with new strengths counts as a change.
		var rssi   : Int
		var secure : Bool

		var id: String { ssid }
	}

	/// How joining a network is going.
	enum WiFi: Equatable {
		case idle
		case joining( String )
		case joined( String )
		case failed( String )
	}

	/// How renaming the board is going.
	enum Rename: Equatable {
		case idle
		case saving
		case failed( String )
	}

	/// How unpairing a board is going.
	enum Unpairing: Equatable {
		case idle
		case working
		case done
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

	private(set) var boards          : [Board] = [] {
		didSet { noteRestartedBoard() }
	}
	/// After an install: the board's USB location, until it answers from its new firmware.
	@ObservationIgnored private var awaitingRestart: Int??
	var selectedPath                 : String?
	var source                       = Source.release
	private(set) var chosenFile      : ChosenFile?
	private(set) var install         = Install.idle
	private(set) var networks        : [Network] = []
	private(set) var findingNetworks = false
	private(set) var wifi            = WiFi.idle
	private(set) var rename          = Rename.idle
	private(set) var unpairing       = Unpairing.idle
	/// The board `unpairing` is about.
	private(set) var unpairingPath   : String?
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

	/// Improv's packet types, commands and limits (https://www.improv-wifi.com/serial/).
	private enum Improv {
		static let typeError  = 0x02
		static let typeResult = 0x04

		static let sendWiFi   = 0x01
		static let getInfo    = 0x03
		static let scan       = 0x04
		static let deviceName = 0x06
		/// ESPDeck's own commands (firmware 4.1.0 and later); earlier firmware answers
		/// unknownCommand. The saved network's name, and "YES" or "NO" for whether it's on it:
		static let wifiNetwork = 0xFE
		/// The storage and what the first network will do (Storage); with one byte, chooses
		/// Standard (0) or encrypted (1) storage for a new board's setup first.
		static let storage     = 0xFD
		/// The bridge ID it's paired with ("" if none); with 0x00, unpairs it first.
		static let pairing     = 0xFC

		static let unknownCommand = 0x02

		/// An RPC's data: the packet's length byte also covers the command and its own length.
		static let maximumData    = 253
		/// 802.11's limit on a network name.
		static let maximumSSID    = 32
	}

	init( controller: DeckController ) {
		self.controller = controller
	}

	/// The AppKit bundle, which does the serial work; nil if it didn't load.
	private var bridge: DeckMenuBarPlugin? { controller?.macBridge }

	/// USB Setup needs the AppKit bundle.
	var isAvailable: Bool { bridge != nil }

	/// "Look for boards plugged in over USB". Off, nothing is watched or opened.
	var scanning: Bool {
		get { controller?.config.settings.usbScanning ?? false }
		set {
			controller?.config.settings.usbScanning = newValue
			newValue ? start() : stop()
		}
	}

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

	/// Stops watching, and forgets the boards.
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

	/// The installed board answered from its new firmware: say it's done.
	private func noteRestartedBoard() {
		guard let location = awaitingRestart, case .finished = install else { return }
		for board in boards where board.port.location == location {
			guard case .answered( let info ) = board.answer, info.isESPDeck else { continue }
			awaitingRestart = nil
			install = .finished( "ESPDeck \(info.version) is installed and running. You can unplug the board safely, or carry on setting it up below." )
			return
		}
	}

	/// Changes the board on `path`, if it's still plugged in.
	private func update( _ path: String, _ change: ( inout Board ) -> Void ) {
		guard let index = boards.firstIndex( where: { $0.port.path == path } ) else { return }
		change( &boards[index] )
	}

	/// Changes what the board on `path` said about itself, if it answered.
	private func updateInfo( _ path: String, _ change: ( inout DeviceInfo ) -> Void ) {
		update( path ) { board in
			guard case .answered( var info ) = board.answer else { return }
			change( &info )
			board.answer = .answered( info )
		}
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

	/// Closes the port; anything it still sends is ignored.
	private func closePort() {
		session += 1
		inbox = []
		bridge?.stopImprov()
	}

	/// Sends an Improv RPC on the open port. False if it couldn't be sent.
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
					if info.isESPDeck {
						info.network      = await askNetwork()
						info.storage      = await askStorage()
						info.pairedBridge = await askPairing()
					}
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
				return SavedNetwork( ssid: DeviceMessage.displayName( ssid ) ?? "", connected: packet.strings.count > 1 && packet.strings[1] == "YES",
									 hostname: packet.strings.count > 2 ? DeviceSettings.hostname( from: packet.strings[2] ) : nil )
			}
			if packet.type == Improv.typeError, packet.value != 0 { return .some( nil ) }
			return nil
		}
		return answer ?? nil
	}

	/// How an ESPDeck board stores its settings, on the port that's open; with `encrypt`,
	/// first chooses that for a new board's setup. Nil as for askNetwork().
	private func askStorage( choosing encrypt: Bool? = nil ) async -> Storage? {
		guard send( Improv.storage, data: encrypt.map { Data( [ $0 ? 1 : 0 ] ) } ?? Data() ) else { return nil }
		let answer = await wait( .milliseconds( encrypt == nil ? 700 : 2000 ) ) { packet -> Storage?? in
			if packet.type == Improv.typeResult, packet.value == Improv.storage, packet.strings.count >= 2 {
				return Storage( state: packet.strings[0], setup: packet.strings[1] )
			}
			if packet.type == Improv.typeError, packet.value != 0 { return .some( nil ) }
			return nil
		}
		return answer ?? nil
	}

	/// The bridge an ESPDeck board is paired with ("" if none), on the port that's open; with
	/// `unpair`, unpairs it first. Nil as for askNetwork().
	private func askPairing( unpair: Bool = false ) async -> String? {
		guard send( Improv.pairing, data: unpair ? Data( [ 0 ] ) : Data() ) else { return nil }
		let answer = await wait( .milliseconds( unpair ? 2000 : 700 ) ) { packet -> String?? in
			if packet.type == Improv.typeResult, packet.value == Improv.pairing { return .some( packet.strings.first ?? "" ) }
			if packet.type == Improv.typeError, packet.value != 0 { return .some( nil ) }
			return nil
		}
		return answer ?? nil
	}

	/// The board for a device, where one is plugged in and has answered: by its USB serial
	/// number (the ESP32-S3's own port), else by name.
	func board( forDevice id: String ) -> Board? {
		boards.first { $0.port.deviceID == id }
			?? controller?.settings( id ).flatMap { settings in boards.first { $0.espDeck?.name == settings.name } }
	}

	/// Unpairs a board over USB, as its setup page's Unpair does. It then connects as a new
	/// device, ready to pair.
	func unpair( _ board: Board ) {
		let path = board.port.path
		unpairingPath = path
		unpairing     = .working
		enqueue { [weak self] in
			guard let self else { return }
			defer { closePort() }
			guard openPort( path ), let paired = await askPairing( unpair: true ) else {
				unpairing = .failed( "The board didn't answer. Its firmware may be older than 4.1.0, which can't be unpaired over USB: use its setup page, or a factory reset." )
				return
			}
			updateInfo( path ) { $0.pairedBridge = paired }
			unpairing = paired.isEmpty ? .done : .failed( "The board is still paired." )
		}
	}

	/// Notes how the board on `path` stores its settings, when it said.
	private func updateStorage( _ path: String, _ storage: Storage? ) {
		updateInfo( path ) { info in
			if let storage { info.storage = storage }
		}
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

	/// Installs the chosen firmware on the selected board, through its ROM bootloader.
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
		install            = error.map { .failed( $0 ) } ?? .finished( "ESPDeck \(version) is installed, and the board is restarting…" )
		awaitingRestart    = nil
		installingLocation = nil
		expected           = ( location, ContinuousClock.now + .seconds( 30 ) )

		selectedPath = port
		guard let current = ports.first( where: { $0.path == port } ) else {
			// Away: it's asked when it's back, as a board expected back.
			boards.removeAll { $0.port.location == location }
			if error == nil { awaitingRestart = .some( location ) }
			return
		}
		boards.removeAll { $0.port.location == location && $0.port.path != port }
		if !boards.contains( where: { $0.port.path == port } ) {
			boards.append( Board( port: current, answer: .asking, hardware: location.flatMap { hardware[$0] } ) )
		}
		update( port ) { $0.answer = .asking }
		// Only now, so the board's answer from before the install doesn't count.
		if error == nil { awaitingRestart = .some( location ) }
		Task {
			// ESPDeck takes a moment to start and to decide its USB port stays a serial port.
			try? await Task.sleep( for: .seconds( 3 ) )
			ask( port, attempts: 12 )
		}
	}

	/// Stops an install under way.
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

	/// Why a firmware file can't be used.
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

	/// Asks the selected board for the networks it can see.
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

	/// Sends the network and password, and waits for the board to join or give up. For a new
	/// board with plain storage, `encrypt` chooses first whether joining encrypts its storage
	/// (burning its one-time key) or keeps it Standard; nil when there's no choice.
	func join( ssid: String, password: String, encrypt: Bool? ) {
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
			guard openPort( path ) else {
				wifi = .failed( "Couldn't reach the board." )
				return
			}
			if let encrypt {
				// Standard must be confirmed before the network goes out: otherwise joining
				// would encrypt, which can't be undone.
				let storage = await askStorage( choosing: encrypt )
				updateStorage( path, storage )
				if !encrypt && storage.map( { $0.setup == "encrypt" } ) != false {
					wifi = .failed( "The board didn't confirm Standard storage, so the network wasn't sent. Try again." )
					return
				}
			}
			guard send( Improv.sendWiFi, data: data ) else {
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
				updateInfo( path ) { info in
					if info.network != nil { info.network = SavedNetwork( ssid: ssid, connected: true ) }
				}
				// A new board encrypted its storage before saving the network (or kept it Standard).
				if board.espDeck?.storage != nil {
					updateStorage( path, await askStorage() )
				}
			}
			wifi = switch joined {
				case true?:  .joined( ssid )
				case false?: .failed( "Couldn't join the network. Check the password, and that it's a 2.4 GHz network." )
				case nil:    .failed( "The board didn't say whether it joined the network." )
			}
		}
	}

	/// Why the network name or password can't be sent.
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
				updateInfo( path ) { $0.name = name }
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
	/// sidebar item to select, a line saying how it is, and whether it still needs pairing.
	/// Found by its device ID where its USB port gave it, since a board renamed after it first
	/// connected can still be listed under its old name; by name otherwise.
	func arrival( of board: JoinedBoard ) -> ( selection: String, status: String, needsPairing: Bool )? {
		guard let controller else { return nil }
		// A known device shows on its own row, whatever's left to do (stuckConnection,
		// waitingConnection).
		let listed = { ( new: NewDevice ) -> ( selection: String, status: String, needsPairing: Bool ) in
			if controller.device( new.hello.id ) != nil {
				return ( new.hello.id, new.reason.foundBridge, new.reason.canPair )
			}
			return ( SidebarItem.newDevice( new.client ), new.reason.foundBridge, new.reason.canPair )
		}
		if let id = board.deviceID {
			if let new = controller.newDevices.first( where: { $0.hello.id == id } ) {
				return listed( new )
			}
			if let device = controller.device( id ), device.isOnline {
				return ( device.id, "The deck is connected to ESPDeck Bridge.", false )
			}
			return nil
		}
		if let new = controller.newDevices.first( where: { $0.hello.name == board.name } ) {
			return listed( new )
		}
		if let device = controller.devices.first( where: { $0.isOnline && controller.settings( $0.id )?.name == board.name } ) {
			return ( device.id, "The deck is connected to ESPDeck Bridge.", false )
		}
		return nil
	}
}
