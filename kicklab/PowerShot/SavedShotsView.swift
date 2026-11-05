import SwiftUI

/// Ball Distance's saved shots, laid out like juggling's session history.
struct SavedShotsView: View {
    let library: SavedShotLibrary
    let owner: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var shots: [SavedShot] = []
    @State private var loading = true
    @State private var failed = false
    @State private var filter = ShotFilter.all
    #if DEBUG
    @State private var showSavedTests = false
    #endif

    private enum ShotFilter: CaseIterable, Identifiable {
        case all, recorded, imported
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .all: LocalizedStringResource("shot.filter.all", defaultValue: "All")
            case .recorded: LocalizedStringResource("shot.filter.recorded", defaultValue: "Recorded")
            case .imported: LocalizedStringResource("shot.filter.imported", defaultValue: "Imported")
            }
        }
        var emptyTitle: LocalizedStringKey {
            switch self {
            case .all: "Your next shot starts here"
            case .recorded: "No recorded shots here yet"
            case .imported: "No imported shots here yet"
            }
        }
    }
    private var filtered: [SavedShot] {
        shots.filter { filter == .all || (filter == .recorded ? $0.source == .recording : $0.source == .gallery) }
    }
    private var days: [Date] {
        Set(filtered.map { Calendar.current.startOfDay(for: $0.completedAt) }).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BALL DISTANCE")
                            .font(.caption.weight(.semibold)).tracking(1.8)
                            .foregroundStyle(TrainingHomeStyle.accent(scheme))
                        Text("SAVED SHOTS")
                            .font(TrainingHomeStyle.display(40, relativeTo: .largeTitle))
                            .lineLimit(2).minimumScaleFactor(0.6)
                            .accessibilityAddTraits(.isHeader)
                        Text("Your shots stay on this phone. They aren’t uploaded or added to your account.")
                            .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    }

                    Picker("Shot source", selection: $filter) {
                        ForEach(ShotFilter.allCases) { Text(AppLanguage.resource($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("saved-shots-filter")

                    if failed {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Some saved shots could not be read. Try again.", systemImage: "exclamationmark.triangle").font(.footnote)
                            Button("Retry") { Task { await reload() } }
                                .font(.subheadline.weight(.semibold)).appGlassButtonStyle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                        .accessibilityIdentifier("saved-shots-error")
                    }

                    if filtered.isEmpty {
                        if loading {
                            ProgressView("Loading shots…").frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if !failed {
                            ContentUnavailableView {
                                Label(filter.emptyTitle, systemImage: "figure.soccer")
                            } description: {
                                Text("Shots you record or import will appear here, ready to edit.")
                            }
                            .accessibilityIdentifier("saved-shots-empty")
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(days, id: \.self) { day in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(HistoryDayLabel.text(day)).font(.caption.weight(.semibold)).tracking(1)
                                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(filtered.filter { Calendar.current.isDate($0.completedAt, inSameDayAs: day) }) { shot in
                                        NavigationLink {
                                            SavedShotDetail(shot: shot, library: library) { await reload() }
                                        } label: {
                                            SavedShotRow(shot: shot, video: library.videoURL(for: shot))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("saved-shot-\(shot.id.uuidString)")
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Saved shots").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button("Saved tests", systemImage: "play.rectangle.on.rectangle") { showSavedTests = true }
                        .labelStyle(.iconOnly).accessibilityIdentifier("ball-distance-saved-tests")
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("saved-shots-close")
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
            .accessibilityIdentifier("saved-shots")
            #if DEBUG
            .sheet(isPresented: $showSavedTests) { ShotRecordingsView(distanceTest: true) }
            #endif
        }
    }

    private func reload() async {
        let library = library, owner = owner
        do {
            shots = try await Task.detached(priority: .userInitiated) { try library.shots(owner: owner) }.value
            failed = false
        } catch { failed = true }
        loading = false
    }
}

private struct SavedShotRow: View {
    let shot: SavedShot
    let video: URL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 16) {
            HistoryReplayThumbnail(url: video)
                .frame(width: 56, height: 74).clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Label(shot.sourceLabel, systemImage: shot.source == .recording ? "video" : "photo")
                    .font(.subheadline.weight(.semibold))
                Text("\(shot.completedAt.formatted(date: .omitted, time: .shortened))  ·  \(shot.durationLabel)")
                    .font(.caption).monospacedDigit().foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(TrainingHomeStyle.muted(scheme))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

private struct SavedShotDetail: View {
    let shot: SavedShot
    let library: SavedShotLibrary
    let onRemoved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showsReplay = false
    @State private var showsEditor = false
    @State private var editAfterReplay = false
    @State private var confirmsRemoval = false
    @State private var removalFailed = false
    private var video: URL { library.videoURL(for: shot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("BALL DISTANCE").font(.caption.weight(.semibold)).tracking(2)
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    Text(shot.completedAt.formatted(date: .complete, time: .shortened))
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 26))

                HStack(spacing: 16) {
                    HistoryStat(title: "DURATION", value: shot.durationLabel, symbol: "stopwatch")
                    HistoryStat(title: "SOURCE", value: shot.sourceLabel, symbol: shot.source == .recording ? "video" : "photo")
                }

                HistoryReplayPanel(url: video, idPrefix: "saved-shot",
                                   onEdit: { showsEditor = true }, onWatch: { showsReplay = true })

                Divider()
                Button("Remove shot from this phone", role: .destructive) { confirmsRemoval = true }
                    .font(.subheadline).frame(minHeight: 44)
                    .accessibilityIdentifier("saved-shot-remove")
            }
            .frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .navigationTitle("Shot details").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("saved-shot-detail")
        .sheet(isPresented: $showsReplay, onDismiss: {
            if editAfterReplay { editAfterReplay = false; showsEditor = true }
        }) {
            HistoryVideoPlayer(url: video) { editAfterReplay = true; showsReplay = false }
        }
        .fullScreenCover(isPresented: $showsEditor) {
            ShotEffectsReplayView(video: video, trackCache: library.trackURL(id: shot.id, owner: shot.ownerID),
                                  look: library.look(id: shot.id, owner: shot.ownerID),
                                  onLookChange: { try? library.saveLook($0, id: shot.id, owner: shot.ownerID) }) {
                showsEditor = false
            }
        }
        .confirmationDialog("Remove this shot?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove shot", role: .destructive, action: remove)
        } message: {
            Text("The video and your edits will be removed from this app. Any copy in Photos will stay.")
        }
        .alert("This shot couldn’t be removed. Try again.", isPresented: $removalFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func remove() {
        do {
            try library.remove(id: shot.id, owner: shot.ownerID)
            Task { await onRemoved(); dismiss() }
        } catch { removalFailed = true }
    }
}
