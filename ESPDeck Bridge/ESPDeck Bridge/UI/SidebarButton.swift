//
//  SidebarButton.swift
//  ESPDeck Bridge
//
//  A UIKit button for the sidebar's rows. In a selectable row, a SwiftUI button ignores
//  the click that makes an inactive window key (so the first click does nothing), while a
//  UIKit control takes it, without selecting the row.
//

import SwiftUI
import UIKit

/// A borderless symbol button in the tint colour, with a tooltip.
struct SidebarButton: UIViewRepresentable {
	let symbol             : String
	let toolTip            : String
	let accessibilityLabel : String
	let action             : () -> Void

	func makeUIView( context: Context ) -> UIButton {
		var configuration                 = UIButton.Configuration.plain()
		configuration.contentInsets       = .zero
		configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration( textStyle: .body )
		let button      = UIButton( configuration: configuration )
		let coordinator = context.coordinator
		button.setContentHuggingPriority( .required, for: .horizontal )
		button.setContentHuggingPriority( .required, for: .vertical )
		button.addAction( UIAction { _ in coordinator.action() }, for: .primaryActionTriggered )
		return button
	}

	func updateUIView( _ button: UIButton, context: Context ) {
		context.coordinator.action          = action
		button.configuration?.image         = UIImage( systemName: symbol )
		// White on a selected row's highlight, as SwiftUI's tint does there.
		button.tintColor                    = context.environment.backgroundProminence == .increased ? .white : nil
		button.toolTip                      = toolTip
		button.accessibilityLabel           = accessibilityLabel
	}

	func sizeThatFits( _ proposal: ProposedViewSize, uiView: UIButton, context: Context ) -> CGSize? {
		uiView.intrinsicContentSize
	}

	func makeCoordinator() -> Coordinator {
		Coordinator( action: action )
	}

	/// Holds the latest action, since the button keeps the UIAction it was made with.
	final class Coordinator {
		var action: () -> Void

		init( action: @escaping () -> Void ) {
			self.action = action
		}
	}
}
