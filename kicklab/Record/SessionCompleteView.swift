import AVFoundation
import SwiftUI
import UIKit

struct SessionCompleteView: View {
    let summary: SessionSummary
    var onWatchEffects: () -> Void
    var onDetailedStats: () -> Void
    var onSaveShare: () -> Void
    var onClose: () -> Void = {}

    @State private var thumb: UIImage?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SessionBackdrop()
            if let thumb {
                GeometryReader { geometry in
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blur(radius: 40).opacity(0.07)
                }.ignoresSafeArea().accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                SessionHeader(title: "", onBack: onClose, onHome: onClose)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        hero
                        statsGrid
                        milestones
                        VStack(spacing: 10) {
                            SessionAction(title: "Watch Replay & Effects", symbol: "arrow.right", trailingSymbol: true, action: onWatchEffects)
                            SessionAction(title: "View Detailed Stats", symbol: "chart.xyaxis.line", primary: false, action: onDetailedStats)
                            SessionAction(title: "Save & Share", symbol: "square.and.arrow.up", primary: false, action: onSaveShare)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal, SessionStyle.inset)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadThumb() }
        .onAppear {
            JugglingRecords.recordIfNeeded(summary.touches)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
        }
    }

    private var hero: some View {
        VStack(spacing: 3) {
            CrownBurst(active: appeared).frame(height: 39)
            Text("Session Complete!").font(.system(size: 23, weight: .bold))
            Text("\(summary.touches)")
                .font(.system(size: 76, weight: .heavy)).monospacedDigit()
                .tracking(-2)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.95)
                .padding(.top, 1)
            Text("Total Touches").font(.system(size: 13)).foregroundStyle(SessionStyle.secondary)
                .padding(.top, -6)
            if summary.isNewBest {
                Text("New Best!")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(SessionStyle.deepGreen, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SessionStyle.mint, lineWidth: 0.7))
                    .shadow(color: SessionStyle.mint.opacity(0.22), radius: 10)
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .background { CompletionFlecks(active: appeared).padding(.horizontal, -4) }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            PostStatCard(icon: "stopwatch", iconColor: .white, title: "Duration", value: summary.durationLabel)
            PostStatCard(icon: "arrow.up.to.line", title: "Max Height", value: summary.maxHeightLabel)
            PostStatCard(icon: "flame.fill", iconColor: Theme.streak, title: "Best Combo", value: "\(summary.bestCombo)")
            PostStatCard(icon: "chart.bar.fill", title: "Avg. Height", value: summary.avgHeightMeters.map { String(format: "%.1f m", $0) } ?? "—")
        }
    }

    @ViewBuilder private var milestones: some View {
        if !summary.milestonesReached.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Milestones Reached").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    ForEach(summary.milestonesReached.prefix(2)) { milestone in
                        HStack(spacing: 10) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 27))
                                .foregroundStyle(LinearGradient(colors: [.yellow, Theme.star, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: Theme.star.opacity(0.4), radius: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(milestone.threshold)").font(.system(size: 20, weight: .semibold))
                                Text(milestone.title).font(.system(size: 10)).foregroundStyle(SessionStyle.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 62)
                        .modifier(SessionPanel(tint: Theme.star.opacity(0.65)))
                    }
                }
            }
        }
    }

    private func loadThumb() async {
        let asset = AVURLAsset(url: summary.videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        let time = CMTime(seconds: min(0.4, summary.duration * 0.15), preferredTimescale: 600)
        if let cg = try? await gen.image(at: time).image { thumb = UIImage(cgImage: cg) }
    }
}
