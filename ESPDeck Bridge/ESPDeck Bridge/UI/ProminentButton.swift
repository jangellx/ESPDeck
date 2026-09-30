//
//  ProminentButton.swift
//  ESPDeck Bridge
//
//  The blue, prominent button style, but plain bordered while the button is disabled: a
//  disabled .borderedProminent stays blue (only a little dimmer), so it still looks like the
//  thing to click.
//

import SwiftUI

/// Chooses the button style from the environment's isEnabled.
private struct ProminentWhenEnabled: ViewModifier {
	@Environment( \.isEnabled ) private var isEnabled

	func body( content: Content ) -> some View {
		if isEnabled {
			content.buttonStyle( .borderedProminent )
		} else {
			content.buttonStyle( .bordered )
		}
	}
}

extension View {
	/// .borderedProminent while enabled, .bordered while disabled. Put .disabled() after it.
	func prominentButtonStyle() -> some View {
		modifier( ProminentWhenEnabled() )
	}
}
