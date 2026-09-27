//
//  Color+Hex.swift
//  ESPDeck Bridge
//

import SwiftUI

extension Color {
	/// "#RRGGBB" or "RRGGBB".
	init?( hex: String ) {
		let digits = hex.hasPrefix( "#" ) ? String( hex.dropFirst() ) : hex
		guard digits.count == 6, let value = UInt32( digits, radix: 16 ) else { return nil }
		self.init( red:   Double( ( value >> 16 ) & 0xFF ) / 255,
				   green: Double( ( value >> 8 ) & 0xFF ) / 255,
				   blue:  Double( value & 0xFF ) / 255 )
	}

	/// "#RRGGBB" in sRGB.
	var hex: String {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		UIColor( self ).getRed( &red, green: &green, blue: &blue, alpha: &alpha )
		func byte( _ component: CGFloat ) -> Int { Int( ( min( max( component, 0 ), 1 ) * 255 ).rounded() ) }
		return String( format: "#%02X%02X%02X", byte( red ), byte( green ), byte( blue ) )
	}

	/// Same hue and saturation with brightness scaled, for gradients.
	func adjusted( brightness factor: CGFloat ) -> Color {
		var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
		UIColor( self ).getHue( &hue, saturation: &saturation, brightness: &brightness, alpha: &alpha )
		return Color( hue: hue, saturation: saturation, brightness: min( brightness * factor, 1 ) )
	}
}
