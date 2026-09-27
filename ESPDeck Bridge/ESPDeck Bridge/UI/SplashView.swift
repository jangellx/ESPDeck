//
//  SplashView.swift
//  ESPDeck Bridge
//
//  Shown briefly at launch before the app retreats to the menu bar.
//

import SwiftUI

struct SplashView: View {
	var body: some View {
		VStack( spacing: 14 ) {
			Image( systemName: "square.grid.3x2.fill" )
				.font( .system( size: 64, weight: .medium ) )
				.foregroundStyle( .white.opacity( 0.9 ) )

			Text( "ESPDeck Bridge" )
				.font( .title.bold() )
				.foregroundStyle( .white )

			Label( "Running in the menu bar", systemImage: "menubar.arrow.up.rectangle" )
				.font( .callout )
				.foregroundStyle( .white.opacity( 0.7 ) )
		}
		.frame( maxWidth: .infinity, maxHeight: .infinity )
		.background( LinearGradient( colors: [ Color( white: 0.22 ), Color( white: 0.08 ) ], startPoint: .top, endPoint: .bottom ) )
		.ignoresSafeArea()
	}
}

#Preview {
	SplashView()
		.frame( width: 420, height: 280 )
}
