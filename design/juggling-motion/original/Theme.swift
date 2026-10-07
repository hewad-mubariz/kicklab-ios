//
//  Theme.swift
//  kicklab
//
//  One place for the look, so the screens agree with each other.
//
//  Live capture keeps a quieter pitch green so overlays stay honest on camera.
//  The home shell uses a brighter brand mint that matches the marketing reference.
//

import SwiftUI

enum Theme {
    /// Pitch green for live overlays — dark enough under a camera feed.
    static let accent = Color(red: 0.15, green: 0.85, blue: 0.45)

    /// Marketing / home brand mint from the chosen home reference.
    static let brand = Color(red: 0.49, green: 0.98, blue: 0.56)

    static let warn = Color(red: 1.0, green: 0.62, blue: 0.15)
    static let streak = Color(red: 1.0, green: 0.45, blue: 0.12)
    static let star = Color(red: 1.0, green: 0.82, blue: 0.18)
    static let ink = Color.white

    /// The count. Rounded, heavy, tabular — so it does not jitter as digits change.
    static func counter(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    static let mono = Font.system(.caption2, design: .monospaced)

    static func brandWordmark(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .black, design: .default)
            .italic()
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Glass panel behind controls and readouts on the live camera.
    static func panel<S: Shape>(_ shape: S) -> some View {
        shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
    }
}

// MARK: - Home surface tokens

enum HomeSurface {
    /// Content margins and compact card dimensions from the home reference.
    static let screenInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let cardRadius: CGFloat = 15
    static let cardPadding: CGFloat = 12
    static let gridSpacing: CGFloat = 9
    static let tabBarHeight: CGFloat = 70
    static let selectionRing: CGFloat = 58
    static let iconSize: CGFloat = 50
    static let mascotSize: CGFloat = 170
    /// Pitch art stays clear; copy lives in the footer below.
    static let sceneArtHeight: CGFloat = 70
    static let sceneFooterHeight: CGFloat = 58
    static let sceneCardHeight: CGFloat = 128

    /// Consistent mint selection color in both appearances.
    static func tabGlow(for scheme: ColorScheme) -> Color {
        Theme.brand
    }

    static let forest = Color(red: 0.06, green: 0.23, blue: 0.13)
    static let dayGreen = Color(red: 0.12, green: 0.66, blue: 0.25)

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.96, green: 0.98, blue: 0.96) : Color(red: 0.04, green: 0.10, blue: 0.08)
    }

    static func mutedInk(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.76 : 0.78)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.035, green: 0.075, blue: 0.075).opacity(0.94)
            : Color(red: 1, green: 0.99, blue: 0.94).opacity(0.96)
    }

    static func rim(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.85)
    }

    static func green(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Theme.brand : dayGreen
    }
}

/// Shared tactile feedback, with no movement when Reduce Motion is enabled.
struct HomePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct HomePanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(HomeSurface.panel(scheme), in: RoundedRectangle(cornerRadius: HomeSurface.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: HomeSurface.cardRadius).strokeBorder(HomeSurface.rim(scheme), lineWidth: 0.8))
            .shadow(color: .black.opacity(scheme == .dark ? 0.16 : 0.08), radius: 8, y: 3)
    }
}

// MARK: - Shared chrome

/// A count that springs when it changes, so a touch registers physically.
struct CounterText: View {
    let value: Int
    var size: CGFloat = 96
    var tint: Color = Theme.ink

    @State private var bump = false

    var body: some View {
        Text("\(value)")
            .font(Theme.counter(size))
            .monospacedDigit()
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.45), radius: 12, y: 3)
            .scaleEffect(bump ? 1.14 : 1.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.45), value: bump)
            .onChange(of: value) { _, _ in
                bump = true
                Task {
                    try? await Task.sleep(nanoseconds: 130_000_000)
                    bump = false
                }
            }
    }
}

/// An expanding ring, fired where a touch was counted.
struct TouchPulse: View {
    let position: CGPoint
    @State private var grow = false

    var body: some View {
        Circle()
            .stroke(Theme.accent, lineWidth: grow ? 1 : 5)
            .frame(width: grow ? 190 : 40, height: grow ? 190 : 40)
            .opacity(grow ? 0 : 0.95)
            .position(position)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { grow = true }
            }
    }
}
