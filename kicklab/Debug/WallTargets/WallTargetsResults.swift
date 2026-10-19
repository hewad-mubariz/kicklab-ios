#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import UIKit

/// A recorded wall-targets session, read back from its session.json.
struct WallTargetsSession: Identifiable {
    /// A wall contact: when, which box (nil outside the grid) and where on the board (u 0...3, v 0...2).
    struct Hit { let t: Double; let box: Int?; let u: Double; let v: Double }

    let folder: URL
    let created: Date
    let duration: Double
    let hits: [Hit]
    let clears: [Double]
    let style: String
    /// "recording" on disk after the app stopped means it was cut off; all but the last second is kept.
    let interrupted: Bool

    var id: URL { folder }
    var boxHits: [Hit] { hits.filter { $0.box != nil } }
    var boxesHit: Set<Int> { Set(hits.compactMap(\.box)) }

    init?(folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.folder = folder
        created = (json["created"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        duration = json["duration"] as? Double ?? 0
        hits = (json["impacts"] as? [[String: Any]] ?? []).map {
            Hit(t: $0["t"] as? Double ?? 0, box: $0["box"] as? Int, u: $0["u"] as? Double ?? -1, v: $0["v"] as? Double ?? -1)
        }
        clears = json["clears"] as? [Double] ?? []
        style = json["style"] as? String ?? ""
        interrupted = json["status"] as? String == "recording"
    }

    static func all() -> [WallTargetsSession] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: WallTargetsRecorder.root,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap(WallTargetsSession.init).sorted { $0.created > $1.created }
    }

    /// One zip with video, detections and session.json, ready to AirDrop.
    func zipped() throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zip in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("WallTargets-\(folder.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: destination)
            result = Result { try FileManager.default.copyItem(at: zip, to: destination); return destination }
        }
        if let coordination { throw coordination }
        return try result.get()
    }
}

/// Saved sessions with their results, and one-tap export for review on the Mac.
struct WallTargetsResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions = WallTargetsSession.all()

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Text("Start Wall targets to record. Clear all six targets or long-press the game screen to stop and save.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    NavigationLink { WallTargetsSessionView(session: session) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.created.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(Self.summary(session)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { try? FileManager.default.removeItem(at: sessions[index].folder) }
                    sessions.remove(atOffsets: offsets)
                }
            }
            .navigationTitle("Results")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    static func summary(_ s: WallTargetsSession) -> String {
        var parts = [String(format: "%.0f s", s.duration), "\(s.boxHits.count) hits", "\(s.boxesHit.count)/6 boxes"]
        if let best = s.clears.min() { parts.append("\(s.clears.count) cleared · best \(String(format: "%.1f", best)) s") }
        if s.interrupted { parts.append("cut off (saved up to the last second)") }
        return parts.joined(separator: " · ")
    }
}

private struct WallTargetsSessionView: View {
    let session: WallTargetsSession
    @State private var export: ExportItem?
    @State private var exporting = false
    @State private var exportError: String?

    private struct ExportItem: Identifiable { let url: URL; var id: URL { url } }

    var body: some View {
        List {
            Section {
                Text(WallTargetsResultsView.summary(session))
                Button {
                    exporting = true
                    let session = session
                    Task {
                        let result = await Task.detached { Result { try session.zipped() } }.value
                        exporting = false
                        switch result {
                        case .success(let url): export = ExportItem(url: url)
                        case .failure(let error): exportError = error.localizedDescription
                        }
                    }
                } label: {
                    Label(exporting ? "Preparing…" : "Export for review", systemImage: "square.and.arrow.up")
                }
                .disabled(exporting)
                if let exportError { Text(exportError).foregroundStyle(.red) }
            }
            Section("Where the ball hit the wall") {
                WallTargetsHitMap(hits: session.hits)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.85, contentMode: .fit)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section("Hits per box") {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(1...3, id: \.self) { column in
                                let box = row * 3 + column
                                let count = session.hits.filter { $0.box == box }.count
                                VStack {
                                    Text("\(box)").font(.caption)
                                    Text("\(count)").font(.title2.bold())
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(count > 0 ? WallTargetsBoard.hitColor.opacity(0.35) : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            if !session.clears.isEmpty {
                Section("Cleared rounds") {
                    ForEach(Array(session.clears.enumerated()), id: \.offset) { index, seconds in
                        Text("Round \(index + 1): \(String(format: "%.1f", seconds)) s")
                    }
                }
            }
            Section("Hits in order") {
                ForEach(Array(session.hits.enumerated()), id: \.offset) { index, hit in
                    Text("\(index + 1). \(String(format: "%.1f", hit.t)) s  ·  \(hit.box.map { "Box \($0)" } ?? "Outside the grid")")
                }
            }
        }
        .navigationTitle(session.created.formatted(date: .omitted, time: .shortened))
        .sheet(item: $export) { item in WallTargetsShareSheet(items: [item.url]) }
    }
}

/// The board as seen on the wall, with every contact where the ball touched it:
/// green inside a box, orange outside the grid (drawn at the edge if far off).
private struct WallTargetsHitMap: View {
    let hits: [WallTargetsSession.Hit]

    var body: some View {
        Canvas { context, size in
            let margin = size.height * 0.12
            let board = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            func point(u: Double, v: Double) -> CGPoint {
                CGPoint(x: board.minX + board.width * min(3.35, max(-0.35, u)) / 3,
                        y: board.minY + board.height * min(2.4, max(-0.4, v)) / 2)
            }
            for box in 1...6 {
                let c = CGFloat((box - 1) % 3), r = CGFloat((box - 1) / 3)
                let cell = CGRect(x: board.minX + c * board.width / 3, y: board.minY + r * board.height / 2,
                                  width: board.width / 3, height: board.height / 2).insetBy(dx: 2, dy: 2)
                let count = hits.filter { $0.box == box }.count
                context.fill(Path(roundedRect: cell, cornerRadius: 6),
                             with: .color(WallTargetsBoard.metalCyan.opacity(count > 0 ? 0.45 : 0.18)))
                context.draw(Text("\(box)").font(.title2.bold()).foregroundStyle(.white.opacity(0.35)),
                             at: CGPoint(x: cell.midX, y: cell.midY))
            }
            for (index, hit) in hits.enumerated() where hit.u > -5 {
                let p = point(u: hit.u, v: hit.v)
                let dot = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
                context.fill(Path(ellipseIn: dot), with: .color(hit.box == nil ? .orange : .green))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
                context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black), at: p)
            }
        }
    }
}

private struct WallTargetsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
