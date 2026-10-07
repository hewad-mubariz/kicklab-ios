import SwiftUI

/// Colors scoped to the launch home, so capture and research tools keep their existing styling.
enum TrainingHomeStyle {
    static let lime = rgb(0xD0F852)
    static let buttonInk = rgb(0x1A2410)
    static let cardBlack = rgb(0x05090A)
    static let cardFooter = rgb(0x17201B)

    static func background(_ scheme: ColorScheme) -> Color {
        rgb(scheme == .dark ? 0x0C0F10 : 0xF3F4ED)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        rgb(scheme == .dark ? 0x151A1C : 0xFFFFFF)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        rgb(scheme == .dark ? 0xF4F6EF : 0x171F1B)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        rgb(scheme == .dark ? 0x99A5A2 : 0x646E65)
    }

    static func line(_ scheme: ColorScheme) -> Color {
        rgb(scheme == .dark ? 0x293135 : 0xDCE0D8)
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? lime : rgb(0x4A6623)
    }

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("DINCondensed-Bold", size: size, relativeTo: style)
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}
