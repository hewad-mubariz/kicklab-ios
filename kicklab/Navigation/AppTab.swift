//
//  AppTab.swift
//  kicklab
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case train
    case progress
    case challenges
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .train: "Train"
        case .progress: "Progress"
        case .challenges: "Challenges"
        case .profile: "Profile"
        }
    }

    /// Outline for idle, filled when selected — matches the dock reference.
    var symbolName: String {
        switch self {
        case .home: "house"
        case .train: "bolt"
        case .progress: "chart.bar"
        case .challenges: "trophy"
        case .profile: "person"
        }
    }

    var symbolNameSelected: String {
        switch self {
        case .home: "house.fill"
        case .train: "bolt.fill"
        case .progress: "chart.bar.fill"
        case .challenges: "trophy.fill"
        case .profile: "person.fill"
        }
    }
}
