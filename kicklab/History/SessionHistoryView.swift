import AVKit
import SwiftUI

struct SessionHistoryView: View {
    @ObservedObject var store: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionHistoryContent(store: store)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close history", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly).accessibilityIdentifier("history-close")
                    }
                }
        }
        .id(store.ownerID)
    }
}

struct SessionHistoryContent: View {
    @ObservedObject var store: SessionHistoryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.colorScheme) private var scheme
    @State private var filter = HistoryFilter.all

    private enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All", recorded = "Recorded", imported = "Imported"
        var id: Self { self }
    }
    private var filtered: [HistorySession] {
        store.items.filter { filter == .all || (filter == .recorded ? $0.source == .recording : $0.source == .gallery) }
    }
    private var days: [Date] {
        Set(filtered.map { Calendar.current.startOfDay(for: $0.completedAt) }).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR TRAINING LOG")
                        .font(.caption.weight(.semibold)).tracking(1.8)
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    Text("SESSION HISTORY")
                        .font(TrainingHomeStyle.display(40, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text(store.ownerID == nil
                         ? "Guest sessions stay on this phone. Sign in from Profile to save future results to your account."
                         : "Your results, saved to your account. Replays stay on the phone where you trained.")
                        .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                }

                Picker("Session source", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("history-filter")

                if let error = store.errorMessage {
                    notice(error, symbol: "wifi.exclamationmark") {
                        Task { player.syncPending(); await store.refresh() }
                    }
                    .accessibilityIdentifier("history-error")
                }

                if filtered.isEmpty {
                    if store.isLoading {
                        ProgressView("Loading sessions…").frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        ContentUnavailableView {
                            Label(filter == .all ? "Your next session starts here" : "No \(filter.rawValue.lowercased()) sessions here yet",
                                  systemImage: "figure.soccer")
                        } description: {
                            Text(store.hasMore ? "Load older sessions to keep looking."
                                 : "Completed juggling sessions will appear here with your touches, time and replay.")
                        }
                        .accessibilityIdentifier("history-empty")
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(days, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(dayLabel(day)).font(.caption.weight(.semibold)).tracking(1)
                                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(filtered.filter { Calendar.current.isDate($0.completedAt, inSameDayAs: day) }) { item in
                                    NavigationLink {
                                        SessionHistoryDetail(id: item.id, store: store)
                                    } label: {
                                        SessionHistoryRow(item: item, hasVideo: store.replayURL(for: item) != nil)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("history-session-\(item.id.uuidString)")
                                }
                            }
                        }
                    }
                }
                if store.hasMore {
                    Button { Task { await store.loadMore() } } label: {
                        HStack {
                            if store.isLoading { ProgressView() }
                            Text(store.isLoading ? "Loading…" : "Load older sessions")
                        }.frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glass).disabled(store.isLoading)
                    .accessibilityIdentifier("history-load-more")
                }
            }
            .frame(maxWidth: 560)
            .padding(20).frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .refreshable { player.syncPending(); await store.refresh() }
        .task(id: store.ownerID) { await store.refresh() }
        .accessibilityIdentifier("session-history")
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(date: .abbreviated, time: .omitted).uppercased()
    }
    private func notice(_ text: String, symbol: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: symbol).font(.footnote)
            Button("Retry", action: retry).font(.subheadline.weight(.semibold)).buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
    }
}

private struct SessionHistoryRow: View {
    let item: HistorySession
    let hasVideo: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 8) {
                Label(item.sourceLabel, systemImage: item.source == .recording ? "video" : "photo")
                    .font(.subheadline.weight(.semibold))
                Text("\(item.completedAt.formatted(date: .omitted, time: .shortened))  ·  \(item.durationLabel)")
                    .font(.caption).monospacedDigit().foregroundStyle(TrainingHomeStyle.muted(scheme))
                if hasVideo {
                    Label("Replay on this phone", systemImage: "play.circle.fill")
                        .font(.caption2.weight(.medium)).foregroundStyle(TrainingHomeStyle.accent(scheme))
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(item.touches.formatted()).font(TrainingHomeStyle.display(44, relativeTo: .largeTitle))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Text("TOUCHES").font(.system(.caption2, design: .monospaced)).tracking(0.6)
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

private struct SessionHistoryDetail: View {
    let id: UUID
    @ObservedObject var store: SessionHistoryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.colorScheme) private var scheme
    @State private var showsReplay = false
    @State private var confirmsRemoval = false
    private var item: HistorySession? { store.items.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("JUGGLING").font(.caption.weight(.semibold)).tracking(2)
                            .foregroundStyle(TrainingHomeStyle.accent(scheme))
                        Text(item.touches.formatted()).font(TrainingHomeStyle.display(100, relativeTo: .largeTitle))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        Text("TOTAL TOUCHES").font(.caption.weight(.semibold)).tracking(1.3)
                        Text(item.completedAt.formatted(date: .complete, time: .shortened))
                            .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 26))

                    HStack(spacing: 16) {
                        stat("DURATION", value: item.durationLabel, symbol: "stopwatch")
                        stat("SOURCE", value: item.sourceLabel, symbol: item.source == .recording ? "video" : "photo")
                    }

                    if store.replayURL(for: item) != nil {
                        Button { showsReplay = true } label: {
                            Label("Watch replay", systemImage: "play.fill")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(scheme == .dark ? TrainingHomeStyle.buttonInk : .white)
                        }
                        .buttonStyle(.glassProminent).tint(TrainingHomeStyle.accent(scheme))
                        .accessibilityIdentifier("history-watch-replay")
                        Text("Original video · saved on this phone")
                            .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    } else {
                        Label("Replay isn’t on this phone", systemImage: "video.slash")
                            .font(.headline)
                        Text("Your result is kept in history. Videos aren’t uploaded to your account; older sessions may only have a saved result.")
                            .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                            .accessibilityIdentifier("history-no-replay")
                    }

                    Divider()
                    Label(item.syncLabel, systemImage: item.syncIcon).font(.subheadline.weight(.semibold))
                    if item.syncState == .pending {
                        Text("Your account updates automatically when you’re connected.")
                            .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    }
                    Label(eligibility(item), systemImage: item.source == .gallery || item.ownerID == nil ? "lock" : "trophy")
                        .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))

                    if store.library.videoURL(for: item) != nil {
                        Button("Remove replay from this phone", role: .destructive) { confirmsRemoval = true }
                            .font(.subheadline).frame(minHeight: 44)
                            .accessibilityIdentifier("history-remove-replay")
                    }
                }
                .frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
                .sheet(isPresented: $showsReplay) {
                    if let url = store.replayURL(for: item) { HistoryVideoPlayer(url: url) }
                }
                .confirmationDialog("Remove this replay?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                    Button("Remove replay", role: .destructive) { store.removeVideo(for: item) }
                } message: {
                    Text("The video will be removed from this app. Your session result and any copy in Photos will stay.")
                }
            }
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .navigationTitle("Session details").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("history-detail")
    }

    private func stat(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption2.weight(.semibold))
                .foregroundStyle(TrainingHomeStyle.muted(scheme))
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func eligibility(_ item: HistorySession) -> String {
        if item.ownerID == nil { return "Guest session. Kept on this device only." }
        if item.source == .gallery { return "Private import. Gallery videos don’t count toward the leaderboard." }
        if item.scoreStatus == "rejected" { return "This result is excluded from the leaderboard." }
        if item.touches == 0 { return "No touches counted. This session stays in your history." }
        if item.syncState == .pending || item.syncState == .saving { return "Your recorded result updates automatically in the background." }
        if player.profile?.leaderboardVisible == true { return "Eligible for the leaderboard. Your best recorded score counts." }
        return "Private until you turn on leaderboard sharing in Profile."
    }
}

private struct HistoryVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player).background(.black)
                .navigationTitle("Original replay").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close replay", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly).accessibilityIdentifier("history-replay-close")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onAppear { player = AVPlayer(url: url); player?.play() }
        .onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
        .onChange(of: phase) { _, phase in if phase != .active { player?.pause() } }
    }
}
