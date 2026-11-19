import SwiftUI

/// The Ball page's sets. With 49 balls the page shows one set at a time, two rows of five,
/// so every ball in it is on screen at once and a pick never has to scroll.
enum BallSet: String, CaseIterable, Identifiable {
    case classic, crafted, match, arcade, shine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: String(localized: "Classic", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .crafted: String(localized: "Crafted", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .match: String(localized: "Match", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .arcade: String(localized: "Arcade", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .shine: String(localized: "Shine", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }

    var symbol: String {
        switch self {
        case .classic: "soccerball"
        case .crafted: "paintpalette.fill"
        case .match: "bolt.fill"
        case .arcade: "gamecontroller.fill"
        case .shine: "sparkles"
        }
    }

    /// Ten at most, so a set always fits two rows of five. Original leads Classic.
    var skins: [BallSkin] {
        switch self {
        case .classic: [.original, .classic, .chrome, .gold, .arctic, .crimson, .stealth, .matrix, .galaxy, .graffiti]
        case .crafted: [.kintsugi, .porcelainTide, .dragonhide, .amberHive, .turboCore,
                        .opalMosaic, .crimsonVelvet, .roseQuartz, .coralBloom, .meteorRelic]
        case .match: [.apexCarbon, .redline, .monoShift, .ultraviolet, .chromeArmor,
                      .plasmaCore, .aeroWhite, .scarletMesh, .topoOrange, .crownBlack]
        case .arcade: [.discoMirror, .eightBall, .puzzleSphere, .gummyPop, .airPop,
                       .toonBall, .littleEarth, .robotBuddy, .treasureOrb, .goalGlobe]
        case .shine: [.goldPolish, .prism, .wave, .nightPulse, .aurora, .metal, .lava, .pearl, .volt]
        }
    }

    static func containing(_ skin: BallSkin) -> BallSet {
        allCases.first { $0.skins.contains(skin) } ?? .classic
    }
}

/// iOS-style segments: the open set shows its name, the rest are icons, and the thumb
/// glides between them.
struct BallSetSwitcher: View {
    @Binding var selection: BallSet
    /// The set holding the ball in use gets a mint dot, so it can be found from any set.
    let current: BallSet
    let onSelect: (BallSet) -> Void
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BallSet.allCases) { set in
                let on = set == selection
                Button { onSelect(set) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: set.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .symbolEffect(.bounce, value: on && !reduceMotion)
                        if on {
                            Text(set.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).fixedSize()
                                .transition(.opacity.combined(with: .offset(x: -6)))
                        }
                    }
                    .foregroundStyle(on ? .white : .white.opacity(0.55))
                    .padding(.horizontal, on ? 12 : 0)
                    .frame(maxWidth: on ? nil : .infinity, minHeight: 34)
                    .overlay(alignment: .topTrailing) {
                        if set == current && !on {
                            Circle().fill(SessionStyle.mint).frame(width: 5, height: 5)
                                .offset(x: -8, y: 6)
                                .transition(.scale)
                        }
                    }
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(.white.opacity(0.16))
                                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(set.title))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("ball-set-\(set.rawValue)")
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
        .sensoryFeedback(.selection, trigger: selection)
    }
}
