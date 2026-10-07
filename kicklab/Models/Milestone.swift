//
//  Milestone.swift
//  kicklab
//

import Foundation

struct Milestone: Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let current: Int
    let goal: Int

    var progress: Double {
        guard goal > 0 else { return 0 }
        return min(1, Double(current) / Double(goal))
    }

    var progressLabel: String {
        "\(current) / \(goal)"
    }
}

extension Milestone {
    static let sample = Milestone(
        id: "juggle-50",
        title: "Next Milestone",
        detail: "Reach 50 touches in a single juggle!",
        current: 24,
        goal: 50
    )
}
