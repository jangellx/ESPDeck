//
//  ColorDropView.swift
//  ESPDeckMenuBar
//
//  Takes colors dragged from the Colors panel or a color well, for the app's windows.
//  AppKit drags a color with the "generic" operation, which Catalyst passes to UIKit as no
//  operation at all: the app's own views see the drag (and highlight), but UIKit turns
//  down every drop. So an AppKit view over the window's content takes those drags, and
//  asks the app what's under them.
//

import AppKit

/// A clear view over a window's content that's only there for color drags: it's the
/// dragging destination for them, and invisible to everything else.
final class ColorDropView: NSView {
	private weak var host: DeckMenuBarHost?

	/// Covers `window`'s content, unless it has one already.
	static func install( in window: NSWindow, host: DeckMenuBarHost? ) {
		guard let content = window.contentView, !content.subviews.contains( where: { $0 is ColorDropView } ) else { return }
		let view              = ColorDropView( frame: content.bounds )
		view.host             = host
		view.autoresizingMask = [ .width, .height ]
		view.registerForDraggedTypes( [ .color ] )
		content.addSubview( view )
	}

	/// Only while a color is being dragged: clicks, scrolling and every other drag go to the
	/// app's own content underneath (a drag of another type, which this view isn't registered
	/// for, is passed up to the content view).
	override func hitTest( _ point: NSPoint ) -> NSView? {
		guard NSEvent.pressedMouseButtons & 1 == 1, NSApp.currentEvent?.type != .leftMouseDown,
			  NSPasteboard( name: .drag ).availableType( from: [ .color ] ) != nil else { return nil }
		return super.hitTest( point )
	}

	/// The drag's place, measured from the top left of the content, as the app measures.
	private func place( of sender: NSDraggingInfo ) -> ( x: Double, y: Double ) {
		let point = convert( sender.draggingLocation, from: nil )
		return ( Double( point.x ), Double( isFlipped ? point.y : bounds.height - point.y ) )
	}

	override func draggingEntered( _ sender: NSDraggingInfo ) -> NSDragOperation { draggingUpdated( sender ) }

	override func draggingUpdated( _ sender: NSDraggingInfo ) -> NSDragOperation {
		let place = place( of: sender )
		return host?.menuBarColorDragged( x: place.x, y: place.y ) == true ? .generic : []
	}

	override func draggingExited( _ sender: NSDraggingInfo? ) { host?.menuBarColorDragEnded() }
	override func draggingEnded( _ sender: NSDraggingInfo ) { host?.menuBarColorDragEnded() }

	override func performDragOperation( _ sender: NSDraggingInfo ) -> Bool {
		guard let color = NSColor( from: sender.draggingPasteboard )?.usingColorSpace( .sRGB ) else { return false }
		let place = place( of: sender )
		return host?.menuBarColorDropped( red: Double( color.redComponent ), green: Double( color.greenComponent ),
										  blue: Double( color.blueComponent ), x: place.x, y: place.y ) ?? false
	}
}
