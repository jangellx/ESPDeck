//
//  ShortcutsEvents.swift
//  ESPDeckMenuBar
//
//  Talks to Shortcuts Events (com.apple.shortcuts.events) with Apple Events built
//  directly, the ones its scripting dictionary (Shortcuts.sdef) describes: nothing to
//  compile, and no text of the user's put into a script. Sending blocks until the answer
//  comes, so it happens on serial queues of its own, never the main thread or the Swift
//  concurrency pool: one for looking things up (quick) and one for running shortcuts
//  (which can take as long as a shortcut takes). AEMach.h: the Apple Event APIs are
//  thread safe apart from event delivery, which sending with a reply doesn't use;
//  NSAppleScript, by contrast, belongs on the main thread.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ShortcutsEvents {
	static let bundleID = "com.apple.shortcuts.events"

	struct Failure: Error, Sendable {
		let message: String
	}

	/// Listing shortcuts and reading icons. Shortcuts Events answers these in moments.
	private static let lookupQueue = DispatchQueue( label: "com.tmproductions.espdeck.shortcuts.lookup", qos: .userInitiated )
	/// Running shortcuts, one at a time, so a long one never holds up a lookup.
	private static let runQueue    = DispatchQueue( label: "com.tmproductions.espdeck.shortcuts.run", qos: .userInitiated )

	private static let lookupTimeout : TimeInterval = 30
	private static let iconTimeout   : TimeInterval = 10
	/// A shortcut can take a while; AppleScript's default would be 2 minutes.
	private static let runTimeout    : TimeInterval = 3600

	// MARK: - Requests

	/// [id, name, folder] for each shortcut, folder "" when it isn't in one.
	static func shortcuts() async -> Result<[[String]], Failure> {
		await perform( on: lookupQueue ) {
			let ids   = try strings( get( property: "ID  ", of: everyShortcut( of: nil ), timeout: lookupTimeout ) )
			let names = try strings( get( property: "pnam", of: everyShortcut( of: nil ), timeout: lookupTimeout ) )

			var folderByID: [String: String] = [:]
			let folders     = element( "fldr", every: nil )
			let folderIDs   = try strings( get( property: "ID  ", of: folders, timeout: lookupTimeout ) )
			let folderNames = try strings( get( property: "pnam", of: folders, timeout: lookupTimeout ) )
			for ( folderID, folderName ) in zip( folderIDs, folderNames ) {
				let folder = element( "fldr", id: folderID, in: nil )
				for id in try strings( get( property: "ID  ", of: everyShortcut( of: folder ), timeout: lookupTimeout ) ) {
					folderByID[id] = folderName
				}
			}
			return zip( ids, names ).map { [ $0, $1, folderByID[$0] ?? "" ] }
		}
	}

	/// The shortcut's icon as a PNG `size` pixels square.
	static func icon( id: String, size: Int ) async -> Result<Data, Failure> {
		await perform( on: lookupQueue ) {
			let tiff = try get( property: "sico", of: element( "srct", id: id, in: nil ), timeout: iconTimeout ).data
			guard let png = png( tiff, size: min( max( size, 1 ), 1024 ) ) else { throw Failure( message: "Shortcuts gave an icon that couldn't be read." ) }
			return png
		}
	}

	/// Runs a shortcut, with `input` as its text input if given, and returns its output as
	/// text: a list's items on separate lines, "" for none.
	static func run( id: String, input: String? ) async -> Result<String, Failure> {
		await perform( on: runQueue ) {
			let event = appleEvent( "srct", "run " )
			event.setParam( element( "srct", id: id, in: nil ), forKeyword: keyDirectObject )
			if let input {
				event.setParam( NSAppleEventDescriptor( string: input ), forKeyword: code( "inpt" ) )
			}
			return text( try send( event, timeout: runTimeout ) ).trimmingCharacters( in: .whitespacesAndNewlines )
		}
	}

	/// Runs `work` on `queue` and waits for it without holding a thread of the pool.
	private static func perform<Value: Sendable>( on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> Value ) async -> Result<Value, Failure> {
		await withCheckedContinuation { continuation in
			queue.async {
				do {
					continuation.resume( returning: .success( try work() ) )
				} catch let failure as Failure {
					continuation.resume( returning: .failure( failure ) )
				} catch {
					continuation.resume( returning: .failure( Failure( message: error.localizedDescription ) ) )
				}
			}
		}
	}

	// MARK: - Building events

	/// A four-character code, like 'srct'.
	private static func code( _ text: String ) -> FourCharCode {
		text.utf8.reduce( 0 ) { $0 << 8 | FourCharCode( $1 ) }
	}

	private static func appleEvent( _ eventClass: String, _ eventID: String ) -> NSAppleEventDescriptor {
		NSAppleEventDescriptor( eventClass: code( eventClass ), eventID: code( eventID ),
								targetDescriptor: NSAppleEventDescriptor( bundleIdentifier: bundleID ),
								returnID: AEReturnID( kAutoGenerateReturnID ), transactionID: AETransactionID( kAnyTransactionID ) )
	}

	/// An object specifier: what's wanted, how it's picked, and what it's in (nil for the
	/// application).
	private static func specifier( want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor,
								   in container: NSAppleEventDescriptor? ) -> NSAppleEventDescriptor {
		let record = NSAppleEventDescriptor.record()
		record.setDescriptor( NSAppleEventDescriptor( typeCode: want ), forKeyword: AEKeyword( keyAEDesiredClass ) )
		record.setDescriptor( NSAppleEventDescriptor( enumCode: form ), forKeyword: AEKeyword( keyAEKeyForm ) )
		record.setDescriptor( data, forKeyword: AEKeyword( keyAEKeyData ) )
		record.setDescriptor( container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword( keyAEContainer ) )
		return record.coerce( toDescriptorType: typeObjectSpecifier ) ?? record
	}

	/// "every shortcut", of a folder or of the application.
	private static func everyShortcut( of folder: NSAppleEventDescriptor? ) -> NSAppleEventDescriptor {
		element( "srct", every: folder )
	}

	private static func element( _ kind: String, every container: NSAppleEventDescriptor? ) -> NSAppleEventDescriptor {
		var all = OSType( kAEAll )
		let ordinal = NSAppleEventDescriptor( descriptorType: typeAbsoluteOrdinal, bytes: &all, length: MemoryLayout<OSType>.size )
		return specifier( want: code( kind ), form: OSType( formAbsolutePosition ), data: ordinal ?? NSAppleEventDescriptor.null(), in: container )
	}

	/// "shortcut id …" or "folder id …".
	private static func element( _ kind: String, id: String, in container: NSAppleEventDescriptor? ) -> NSAppleEventDescriptor {
		specifier( want: code( kind ), form: OSType( formUniqueID ), data: NSAppleEventDescriptor( string: id ), in: container )
	}

	/// "get <property> of <object>".
	private static func get( property: String, of object: NSAppleEventDescriptor, timeout: TimeInterval ) throws -> NSAppleEventDescriptor {
		let event = appleEvent( "core", "getd" )
		event.setParam( specifier( want: OSType( cProperty ), form: OSType( formPropertyID ),
								   data: NSAppleEventDescriptor( typeCode: code( property ) ), in: object ), forKeyword: keyDirectObject )
		return try send( event, timeout: timeout )
	}

	// MARK: - Sending

	/// Sends an event and returns its result. Shortcuts Events quits when it has been idle
	/// a while, so it's started if it isn't running.
	private static func send( _ event: NSAppleEventDescriptor, timeout: TimeInterval ) throws -> NSAppleEventDescriptor {
		var launched = false
		while true {
			let reply: NSAppleEventDescriptor
			do {
				reply = try event.sendEvent( options: [ .waitForReply, .canInteract ], timeout: timeout )
			} catch let error as NSError where error.domain == NSOSStatusErrorDomain && [ -600, -609 ].contains( error.code ) && !launched {
				// procNotFound, or connectionInvalid when it quit just now.
				launched = true
				try launch()
				continue
			} catch let error as NSError {
				throw failure( code: error.code, message: nil )
			}

			if let number = reply.paramDescriptor( forKeyword: AEKeyword( keyErrorNumber ) )?.int32Value, number != 0 {
				throw failure( code: Int( number ), message: reply.paramDescriptor( forKeyword: AEKeyword( keyErrorString ) )?.stringValue )
			}
			return reply.paramDescriptor( forKeyword: keyDirectObject ) ?? NSAppleEventDescriptor.null()
		}
	}

	/// Starts Shortcuts Events in the background and waits until it takes events.
	private static func launch() throws {
		guard let url = NSWorkspace.shared.urlForApplication( withBundleIdentifier: bundleID ) else {
			throw Failure( message: "Shortcuts Events isn't installed on this Mac." )
		}
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates         = false
		configuration.addsToRecentItems = false
		let opened = DispatchSemaphore( value: 0 )
		NSWorkspace.shared.openApplication( at: url, configuration: configuration ) { _, _ in opened.signal() }
		_ = opened.wait( timeout: .now() + 10 )

		for _ in 0..<40 {
			if NSRunningApplication.runningApplications( withBundleIdentifier: bundleID ).contains( where: \.isFinishedLaunching ) { return }
			Thread.sleep( forTimeInterval: 0.25 )
		}
		throw Failure( message: "Shortcuts Events didn't start." )
	}

	private static func failure( code: Int, message: String? ) -> Failure {
		switch code {
			case -1743:   // errAEEventNotPermitted
				Failure( message: "ESPDeck Bridge isn't allowed to use Shortcuts. Turn it on in System Settings → Privacy & Security → Automation." )
			case -1712:   // errAETimeout
				Failure( message: "Shortcuts didn't finish in time, so ESPDeck Bridge stopped waiting." )
			case -1728:   // errAENoSuchObject
				Failure( message: message ?? "That shortcut isn't in Shortcuts any more." )
			case -600, -609:   // procNotFound, connectionInvalid
				Failure( message: "Shortcuts Events isn't running." )
			default:
				Failure( message: message ?? "Shortcuts Events reported error \(code)." )
		}
	}

	// MARK: - Results

	private static func items( _ list: NSAppleEventDescriptor ) -> [NSAppleEventDescriptor] {
		guard list.descriptorType == typeAEList, list.numberOfItems > 0 else { return [] }
		return ( 1...list.numberOfItems ).compactMap { list.atIndex( $0 ) }
	}

	/// A list of texts; nothing (no shortcuts) is an empty list.
	private static func strings( _ result: NSAppleEventDescriptor ) throws -> [String] {
		if result.descriptorType == typeNull { return [] }
		guard result.descriptorType == typeAEList else { throw Failure( message: "Shortcuts Events answered in an unexpected way." ) }
		return items( result ).map { $0.stringValue ?? "" }
	}

	/// Text, a list of texts (one per line), or nothing.
	private static func text( _ result: NSAppleEventDescriptor ) -> String {
		if result.descriptorType == typeAEList {
			return items( result ).map( text ).joined( separator: "\n" )
		}
		return result.stringValue ?? ""
	}

	/// The largest image in the TIFF, drawn `size` pixels square.
	private static func png( _ tiff: Data, size: Int ) -> Data? {
		guard let source = CGImageSourceCreateWithData( tiff as CFData, nil ) else { return nil }
		let images = ( 0..<CGImageSourceGetCount( source ) ).compactMap { CGImageSourceCreateImageAtIndex( source, $0, nil ) }
		guard let image = images.max( by: { $0.width < $1.width } ),
			  let space = CGColorSpace( name: CGColorSpace.sRGB ),
			  let context = CGContext( data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
									   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue ) else { return nil }
		context.interpolationQuality = .high
		context.draw( image, in: CGRect( x: 0, y: 0, width: size, height: size ) )
		guard let drawn = context.makeImage() else { return nil }

		let png = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData( png, UTType.png.identifier as CFString, 1, nil ) else { return nil }
		CGImageDestinationAddImage( destination, drawn, nil )
		return CGImageDestinationFinalize( destination ) ? png as Data : nil
	}
}
