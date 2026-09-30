//
//  AppDelegate+Notifications.swift
//  ESPDeck Bridge
//
//  A notification for a problem that happened behind the user's back (a shortcut that
//  failed on a key press, say), which the sidebar's Status may not have on screen. Clicking
//  it opens the window scrolled to the problem.
//

import UIKit
import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
	/// Takes over notification handling; call once at launch.
	func setUpNotifications() {
		UNUserNotificationCenter.current().delegate = self
		controller.onProblem = { [weak self] problem in self?.notify( problem ) }
	}

	/// Posts `problem` if it's one that notifies: the window may be closed, behind another
	/// app, or scrolled so Status is out of sight. Permission is asked the first time there's
	/// something to say. The same kind of problem replaces the last.
	private func notify( _ problem: BridgeProblem ) {
		guard problem.notifies else { return }
		Task {
			let center = UNUserNotificationCenter.current()
			guard ( try? await center.requestAuthorization( options: [ .alert, .sound ] ) ) == true else { return }
			let content   = UNMutableNotificationContent()
			content.title = problem.title
			content.body  = problem.detail
			content.sound = .default
			try? await center.add( UNNotificationRequest( identifier: "problem-\(problem.title)", content: content, trigger: nil ) )
		}
	}

	/// Shown even while the app is in front (the window may not be).
	nonisolated func userNotificationCenter( _ center: UNUserNotificationCenter, willPresent notification: UNNotification ) async -> UNNotificationPresentationOptions {
		[ .banner, .sound ]
	}

	/// Clicked: the window, scrolled to the problem in Status.
	nonisolated func userNotificationCenter( _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse ) async {
		await MainActor.run {
			menuBarOpenConfiguration()
			controller.window.scrollToProblem = true
		}
	}
}
