//
//  TrainingModule.swift
//  kicklab
//

import SwiftUI

enum ModuleDestination: String, Hashable, Codable {
    case juggling
    case targetShoot
    case powerShot
    case freeKick
    case penalties
    case challenges
    case stats
}

enum ModuleCardStyle: String, Hashable, Sendable {
    /// Full-bleed scene art (training modes from the UI kit).
    case scene
    /// Frosted glass + centered icon + lock (coming soon).
    case comingSoon
}

struct TrainingModule: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    /// Asset name with light/dark appearances in the catalog.
    let imageName: String
    let style: ModuleCardStyle
    let isAvailable: Bool
    let destination: ModuleDestination?

    var accessibilityLabel: String {
        isAvailable ? "\(title). \(subtitle)" : "\(title). Coming soon"
    }
}

extension TrainingModule {
    static let catalog: [TrainingModule] = [
        TrainingModule(
            id: "juggling",
            title: "Juggling",
            subtitle: "How long can you keep it up?",
            imageName: "card-juggling",
            style: .scene,
            isAvailable: true,
            destination: .juggling
        ),
        TrainingModule(
            id: "target-shoot",
            title: "Target Shoot",
            subtitle: "Hit the targets. Test your aim.",
            imageName: "card-target",
            style: .scene,
            isAvailable: true,
            destination: .targetShoot
        ),
        TrainingModule(
            id: "power-shot",
            title: "Ball Distance",
            subtitle: "Record a roll. Add ball effects.",
            imageName: "card-freekick",
            style: .scene,
            isAvailable: true,
            destination: .powerShot
        ),
        TrainingModule(
            id: "free-kick",
            title: "Free Kick",
            subtitle: "Curve it. Beat the wall.",
            imageName: "card-freekick",
            style: .scene,
            isAvailable: true,
            destination: .freeKick
        ),
        TrainingModule(
            id: "penalties",
            title: "Penalties",
            subtitle: "Step up. Show your nerves.",
            imageName: "card-penalties",
            style: .scene,
            isAvailable: true,
            destination: .penalties
        ),
        TrainingModule(
            id: "challenges",
            title: "Challenges",
            subtitle: "Push your limits.",
            imageName: "card-challenges",
            style: .scene,
            isAvailable: true,
            destination: .challenges
        ),
        TrainingModule(
            id: "stats",
            title: "Stats",
            subtitle: "Track your progress.",
            imageName: "card-stats",
            style: .scene,
            isAvailable: true,
            destination: .stats
        ),
        TrainingModule(
            id: "dribbling",
            title: "Dribbling",
            subtitle: "Coming Soon",
            imageName: "icon-dribbling",
            style: .comingSoon,
            isAvailable: false,
            destination: nil
        ),
        TrainingModule(
            id: "passing",
            title: "Passing",
            subtitle: "Coming Soon",
            imageName: "icon-passing",
            style: .comingSoon,
            isAvailable: false,
            destination: nil
        ),
        TrainingModule(
            id: "tournaments",
            title: "Tournaments",
            subtitle: "Coming Soon",
            imageName: "icon-tournaments",
            style: .comingSoon,
            isAvailable: false,
            destination: nil
        ),
    ]
}
