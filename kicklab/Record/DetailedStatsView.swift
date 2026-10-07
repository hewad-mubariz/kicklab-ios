//
//  DetailedStatsView.swift
//  kicklab
//
//  Performance analysis — real session data + Metal-glow chart.
//

import SwiftUI

struct DetailedStatsView: View {
    let summary: SessionSummary
    var onSaveShare: () -> Void
    var onBack: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case touches = "Touches"
        case height = "Height"
        case combo = "Combo"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                SessionSegments(options: Tab.allCases, selection: $tab) { $0.rawValue }
                    .padding(.horizontal, SessionStyle.inset)
                    .padding(.bottom, 16)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        statsGrid
                        contentForTab
                        SessionAction(title: "Save & Share", symbol: "square.and.arrow.up", primary: false, action: onSaveShare)
                            .padding(.top, 4)
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, SessionStyle.inset)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                appeared = true
            }
        }
    }

    private var background: some View { SessionBackdrop() }

    private var topBar: some View {
        SessionHeader(title: "Detailed Stats", onBack: onBack)
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            PostStatCard(icon: "trophy.fill", iconColor: Theme.star, title: "Total Touches", value: "\(summary.touches)")
            PostStatCard(icon: "flame", iconColor: .white, title: "Best Combo", value: "\(summary.bestCombo)")
            PostStatCard(icon: "stopwatch", iconColor: .white, title: "Duration", value: summary.durationLabel)
            PostStatCard(icon: "arrow.up.to.line", title: "Max Height", value: summary.maxHeightLabel)
            PostStatCard(icon: "chart.bar.fill", title: "Avg. Height", value: summary.avgHeightMeters.map { String(format: "%.1f m", $0) } ?? "—")
            PostStatCard(icon: "xmark.circle.fill", iconColor: .white, title: "Drops", value: "\(summary.drops)")
        }
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch tab {
        case .overview:
            TouchesChartView(
                series: summary.touchTimeline,
                peakLabel: "Peak \(summary.peakTouchesInWindow)",
                duration: summary.duration
            )
            ConsistencyRingView(
                percent: summary.consistencyPercent,
                blurb: summary.consistencyBlurb
            )
        case .touches:
            TouchesChartView(
                series: summary.touchTimeline,
                peakLabel: "Peak \(summary.peakTouchesInWindow)",
                duration: summary.duration
            )
            touchList
        case .height:
            heightPanel
        case .combo:
            comboPanel
        }
    }

    private var touchList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Touch Log")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(.white)
            ForEach(summary.touchesMarked.prefix(12)) { touch in
                HStack {
                    Text("#\(touch.index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .default))
                        .foregroundStyle(SessionStyle.mint)
                        .frame(width: 40, alignment: .leading)
                    Text(String(format: "%.2fs", touch.time))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f%% · %.0f%%", touch.x * 100, touch.y * 100))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SessionStyle.secondary)
                }
                .padding(.vertical, 6)
                Divider().overlay(Color.white.opacity(0.08))
            }
            if summary.touchesMarked.count > 12 {
                Text("+ \(summary.touchesMarked.count - 12) more")
                    .font(.caption)
                    .foregroundStyle(SessionStyle.secondary)
            }
        }
        .padding(16)
        .background(panel)
    }

    private var heightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Height")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(.white)
            HStack {
                metric("Max", summary.maxHeightLabel)
                metric("Avg", summary.avgHeightMeters.map { String(format: "%.2f m", $0) } ?? "—")
            }
            Text("Heights are estimated from ball position in frame until calibrated.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SessionStyle.secondary)
        }
        .padding(16)
        .background(panel)
    }

    private var comboPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Combo")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(.white)
            HStack {
                metric("Best", "\(summary.bestCombo)")
                metric("Session", "\(summary.touches)")
            }
            ConsistencyRingView(
                percent: summary.consistencyPercent,
                blurb: summary.consistencyBlurb
            )
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SessionStyle.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .default))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(SessionPanel())
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: SessionStyle.radius)
            .fill(SessionStyle.panel)
            .overlay(RoundedRectangle(cornerRadius: SessionStyle.radius).strokeBorder(SessionStyle.rim, lineWidth: 0.7))
    }
}
