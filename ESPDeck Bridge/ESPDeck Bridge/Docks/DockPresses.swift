//
//  DockPresses.swift
//  ESPDeck Bridge
//
//  What kind of press each key had, for a Network Dock. An ESP32 judges taps, double taps,
//  holds and repeats itself (keyModes, PROTOCOL.md) and reports them; a dock only reports
//  which keys are down, so the Mac judges them here, by the firmware's rules (main.cpp's
//  handleKeyDown, reportPress and sendHeldKeys), and DockDeck reports them as the firmware
//  would. Times are seconds on a monotonic clock.
//

import Foundation

/// The key events a deck reports to the Mac, judged from keys going down and up.
struct DockPresses {
	/// What the deck says about a key, as an ESP32 would.
	enum Event: Equatable {
		case keyDown( Int )
		case keyUp( Int )
		case tap( Int )
		case doubleTap( Int )
		case hold( Int )
		case repeated( Int )
	}

	/// A switch that bounces reports up and down again within a few milliseconds; a person
	/// can't press the same key again that quickly, so that's one press (the firmware's
	/// kKeyBounce).
	static let bounce: TimeInterval = 0.05

	// How keys report presses (keyModes); until the Mac says, every key is a plain tap.
	private var repeating       : Set<Int> = []
	private var doubleTapping   : Set<Int> = []
	private var holding         : Set<Int> = []
	private var repeatDelay     : TimeInterval = 0.5
	private var repeatInterval  : TimeInterval = 0.166
	private var doubleTapWindow : TimeInterval = 0.3
	private var holdTime        : TimeInterval = 0.5

	/// Held right now.
	private(set) var down       : Set<Int> = []
	/// The Mac has seen keyDown but not keyUp.
	private var forwarded       : Set<Int> = []
	/// Down ignored as bounce: its up is ignored too.
	private var bouncing        : Set<Int> = []
	/// Forward nothing until every key is up (the press that woke the deck, say).
	private var swallowing      = false
	private var releasedAt      : [Int: TimeInterval] = [:]
	private var nextRepeatAt    : [Int: TimeInterval] = [:]
	private var holdAt          : [Int: TimeInterval] = [:]
	private var tapDueAt        : [Int: TimeInterval] = [:]
	/// This press was a hold.
	private var holdSent        : Set<Int> = []
	/// Became a repeating key while down: not until it's pressed again.
	private var repeatHeldBack  : Set<Int> = []
	/// Down within the double-tap window.
	private var secondPress     : Set<Int> = []
	/// Up, waiting to see if a second press comes.
	private var tapPending      : Set<Int> = []

	/// keyModes: which keys repeat, double-tap and hold, and the timings (milliseconds,
	/// clamped as the firmware does). A key down now keeps the modes it was pressed with
	/// until its next press.
	mutating func setModes( repeat: [Int], doubleTap: [Int], hold: [Int], delay: Int, interval: Int, doubleTapWindow window: Int, holdTime time: Int ) {
		let wasRepeating = repeating, wasHolding = holding
		repeating      = Set( `repeat` )
		doubleTapping  = Set( doubleTap )
		holding        = Set( hold )
		repeatHeldBack.formUnion( forwarded.intersection( repeating ).subtracting( wasRepeating ) )
		holdSent.formUnion( forwarded.intersection( holding ).subtracting( wasHolding ) )
		repeatDelay     = Self.seconds( delay, 100...3000 )
		repeatInterval  = Self.seconds( interval, 30...2000 )
		doubleTapWindow = Self.seconds( window, 150...1000 )
		holdTime        = Self.seconds( time, 200...3000 )
	}

	private static func seconds( _ milliseconds: Int, _ range: ClosedRange<Int> ) -> TimeInterval {
		TimeInterval( min( max( milliseconds, range.lowerBound ), range.upperBound ) ) / 1000
	}

	/// A key went down.
	mutating func keyDown( _ key: Int, at now: TimeInterval ) -> [Event] {
		if let released = releasedAt[key], now - released < Self.bounce {
			bouncing.insert( key )
			return []
		}
		down.insert( key )
		guard !swallowing else { return [] }

		forwarded.insert( key )
		if repeating.contains( key ) { nextRepeatAt[key] = now + repeatDelay }
		if holding.contains( key )   { holdAt[key] = now + holdTime }
		holdSent.remove( key )
		repeatHeldBack.remove( key )
		// The second press of a double tap.
		if tapPending.remove( key ) != nil {
			secondPress.insert( key )
		}
		return [ .keyDown( key ) ]
	}

	/// A key came up: forwarded, with what kind of press it was, if its down was.
	mutating func keyUp( _ key: Int, at now: TimeInterval ) -> [Event] {
		releasedAt[key] = now
		if bouncing.remove( key ) != nil { return [] }
		down.remove( key )

		var events: [Event] = []
		if forwarded.remove( key ) != nil {
			events.append( .keyUp( key ) )
			if holdSent.remove( key ) != nil {
				// Reported as a hold already.
			} else if secondPress.remove( key ) != nil {
				events.append( .doubleTap( key ) )
			} else if doubleTapping.contains( key ) {
				tapPending.insert( key )
				tapDueAt[key] = now + doubleTapWindow
			} else {
				events.append( .tap( key ) )
			}
		}
		if down.isEmpty { swallowing = false }
		return events
	}

	/// Repeats and holds for keys still down, and taps whose double-tap window has passed.
	mutating func tick( at now: TimeInterval ) -> [Event] {
		var events: [Event] = []
		for key in forwarded.sorted() {
			if repeating.contains( key ), !repeatHeldBack.contains( key ), let due = nextRepeatAt[key], now >= due {
				events.append( .repeated( key ) )
				nextRepeatAt[key] = now + repeatInterval
			}
			if holding.contains( key ), !holdSent.contains( key ), let due = holdAt[key], now >= due {
				events.append( .hold( key ) )
				holdSent.insert( key )
				secondPress.remove( key )
			}
		}
		for key in tapPending.sorted() {
			if let due = tapDueAt[key], now >= due {
				tapPending.remove( key )
				events.append( .tap( key ) )
			}
		}
		return events
	}

	/// When `tick` next has something to do, if anything.
	var nextDeadline: TimeInterval? {
		var times: [TimeInterval] = []
		for key in forwarded {
			if repeating.contains( key ), !repeatHeldBack.contains( key ), let due = nextRepeatAt[key] { times.append( due ) }
			if holding.contains( key ), !holdSent.contains( key ), let due = holdAt[key] { times.append( due ) }
		}
		times += tapPending.compactMap { tapDueAt[$0] }
		return times.min()
	}

	/// Ignores keys still down until every key is up, so a press that began while the deck
	/// slept doesn't reach the Mac half-way through.
	mutating func swallowHeldKeys() {
		swallowing = !down.isEmpty
	}

	/// Ignores this press and any other until every key is up: the press that wakes the deck.
	mutating func swallowPress() {
		swallowing = true
	}

	/// Ends every press the Mac has seen, before key events stop being forwarded (sleep, the
	/// deck unplugged): a keyUp for each, and nothing pending.
	mutating func releaseForwarded() -> [Event] {
		let events = forwarded.sorted().map { Event.keyUp( $0 ) }
		forwarded = []
		holdSent = []; secondPress = []; tapPending = []; repeatHeldBack = []
		swallowHeldKeys()
		return events
	}

	/// The deck went away: nothing is down any more.
	mutating func reset() {
		down = []; bouncing = []; swallowing = false; releasedAt = [:]
		_ = releaseForwarded()
	}
}
