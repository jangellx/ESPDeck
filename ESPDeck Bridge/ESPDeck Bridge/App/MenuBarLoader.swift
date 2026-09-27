//
//  MenuBarLoader.swift
//  ESPDeck Bridge
//
//  Loads ESPDeckMenuBar.bundle, the AppKit half of the app, from Contents/PlugIns.
//

import Foundation

enum MenuBarLoader {
	static func load() -> DeckMenuBarPlugin? {
		#if targetEnvironment( macCatalyst )
		guard let url    = Bundle.main.builtInPlugInsURL?.appending( path: "ESPDeckMenuBar.bundle" ),
			  let bundle = Bundle( url: url ) else {
			print( "[MenuBarLoader] ESPDeckMenuBar.bundle is missing" )
			return nil
		}

		do {
			try bundle.loadAndReturnError()
		} catch {
			print( "[MenuBarLoader] Loading ESPDeckMenuBar.bundle failed: \(error)" )
			return nil
		}

		guard let principal = bundle.principalClass as? NSObject.Type,
			  let plugin    = principal.init() as? DeckMenuBarPlugin else {
			print( "[MenuBarLoader] ESPDeckMenuBar's principal class doesn't conform to DeckMenuBarPlugin" )
			return nil
		}
		return plugin
		#else
		return nil
		#endif
	}
}
