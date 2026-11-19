//
//  AppTab.swift
//  kicklab
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case learn
    case challenges
    case wallGame
    case leaderboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .learn: "Learn"
        case .leaderboard: "Leaderboard"
        case .challenges: "Challenges"
        case .wallGame: "Wall Game"
        }
    }

    /// Outline for idle, filled when selected — matches the dock reference.
    var symbolName: String {
        switch self {
        case .home: "house"
        case .learn: "graduationcap"
        case .leaderboard: "trophy"
        case .challenges: "flag.checkered"
        case .wallGame: "square.grid.3x2"
        }
    }

    var symbolNameSelected: String {
        switch self {
        case .home: "house.fill"
        case .learn: "graduationcap.fill"
        case .leaderboard: "trophy.fill"
        case .challenges: "flag.checkered"
        case .wallGame: "square.grid.3x2.fill"
        }
    }
}
