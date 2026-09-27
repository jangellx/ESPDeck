//
//  StatusIndicator.swift
//  ESPDeck Bridge
//

import SwiftUI

/// Yellow circle while waiting, white check on green when found, white exclamation
/// mark on red for a problem, dashed circle for a demo deck. The menu bar draws the
/// same symbols (it never lists demo decks).
struct StatusIndicator: View {
	let level: DeckController.StatusItem.Level

	var body: some View {
		switch level {
			case .waiting:
				Image( systemName: "circle.fill" )
					.foregroundStyle( .yellow )
			case .ok:
				Image( systemName: "checkmark.circle.fill" )
					.foregroundStyle( .white, .green )
			case .problem:
				Image( systemName: "exclamationmark.circle.fill" )
					.foregroundStyle( .white, .red )
			case .demo:
				Image( systemName: "circle.dashed" )
					.foregroundStyle( .secondary )
		}
	}
}
