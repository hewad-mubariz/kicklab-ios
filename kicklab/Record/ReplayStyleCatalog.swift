//
//  ReplayStyleCatalog.swift
//  kicklab
//
//  Picker chrome for Replay & Effects. Effects tab = BallStyle skins (v1).
//

import SwiftUI

enum ReplayStyleTab: String, CaseIterable, Identifiable {
    case effects = "Effects"
    case ballStyle = "Ball Style"
    case environment = "Environment"
    case counter = "Counter"
    var id: String { rawValue }
}

struct ReplayStyleOption: Identifiable, Hashable {
    let id: String
    let title: String
    let assetName: String?
    let systemIcon: String?
    let tint: Color
    /// When set, this chip maps to a real BallStyle skin.
    var ballStyle: BallStyle? = nil
}

enum ReplayStyleCatalog {
    static let effects: [ReplayStyleOption] = BallStyle.allCases.map { style in
        ReplayStyleOption(
            id: style.rawValue,
            title: style.title,
            assetName: style.assetName,
            systemIcon: nil,
            tint: style.tint,
            ballStyle: style
        )
    }

    static let ballStyles: [ReplayStyleOption] = BallSkin.allCases.map {
        .init(id: $0.rawValue, title: $0.title, assetName: nil, systemIcon: "soccerball", tint: .white)
    }

    static let environments: [ReplayStyleOption] = EffectEnvironment.allCases.map {
        .init(id: $0.rawValue, title: $0.title, assetName: nil,
              systemIcon: $0 == .night ? "moon.stars.fill" : "sun.max.fill", tint: Theme.brand)
    }

    static func options(for tab: ReplayStyleTab) -> [ReplayStyleOption] {
        switch tab {
        case .effects: return effects
        case .ballStyle: return ballStyles
        case .environment: return environments
        case .counter: return []
        }
    }
}
