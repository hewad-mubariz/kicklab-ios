//
//  HomeSnapshot.swift
//  kicklab
//
//  Everything the home screen needs in one value. Swap this for a live store later
//  without rewriting the views.
//

import Foundation

struct HomeSnapshot: Hashable, Sendable {
    var displayName: String
    var streakDays: Int
    var hasUnreadNotifications: Bool
    var tagline: String
    var modules: [TrainingModule]
    var milestone: Milestone

    var greeting: String {
        "Hey \(displayName)! 👋"
    }
}

extension HomeSnapshot {
    static let preview = HomeSnapshot(
        displayName: "Alex",
        streakDays: 12,
        hasUnreadNotifications: true,
        tagline: "Better players brighter tomorrows.",
        modules: TrainingModule.catalog,
        milestone: .sample
    )
}
