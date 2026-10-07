//
//  TabHaptics.swift
//  kicklab
//
//  Selection feedback for the floating tab bar. UIKit generators give a sharper,
//  more consistent tap than SwiftUI sensoryFeedback alone on rapid tab presses.
//

import UIKit

enum TabHaptics {
    private static let select = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    static func prepare() {
        select.prepare()
        impact.prepare()
    }

    static func tabChanged() {
        select.selectionChanged()
    }

    static func tabPressed() {
        impact.impactOccurred(intensity: 0.7)
    }
}
