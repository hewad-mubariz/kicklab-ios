#if DEBUG && BALL_DETECTION_DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Deterministic rendering of the real board on Simulator, whose camera cannot
/// run the wall experiment. This entry point is absent from the phone build.
struct WallTargetsPreviewScene: View {
    @StateObject private var model = WallTargetsModel(defaults: UserDefaults(suiteName: "WallGamePreview.\(UUID().uuidString)")!)
    @State private var configured=false

    private var previewBoard: some View {
        WallTargetsBoard(model: model, onStart: { _ = model.beginGameSetup() }, onSettings: {},
                         onPenalties: { VirtualPenaltyPresentation.shared.open() },
                         onChallenge: { VirtualPenaltyPresentation.shared.open(realBall:true,challenge:$0) },
                         runtime: ProcessInfo.processInfo.arguments.contains("--wall-runtime")
                            ? WallRuntimeSample(memoryMiB: 486, peakMemoryMiB: 512, thermalState: 2,
                                analysisFPS: 24, captureFPS: 60, inferenceMS: 32, cameraResting: false) : nil)
    }

    var body: some View {
        previewBoard
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .modifier(VirtualPenaltyCover())
            .onAppear {
                guard !configured else { return }
                configured=true
                defer { exportBoard() }
                WallTargetsAppDelegate.lock(.landscapeRight)
                if ProcessInfo.processInfo.arguments.contains("--virtual-penalties") {
                    model.showGameIntro()
                    VirtualPenaltyPresentation.shared.open()
                    return
                }
                model.style = .metal
                let selected: WallGame? = ProcessInfo.processInfo.arguments.contains("--memory-strike") ? .memoryStrike
                    : ProcessInfo.processInfo.arguments.contains("--meteor-defence") ? .meteorDefence
                    : ProcessInfo.processInfo.arguments.contains("--cross-circle") ? .crossCircle
                    : ProcessInfo.processInfo.arguments.contains("--goal-duel") ? .goalDuel
                    : ProcessInfo.processInfo.arguments.contains("--four-in-row") ? .fourInRow
                    : ProcessInfo.processInfo.arguments.contains("--territory-duel") ? .territoryDuel
                    : ProcessInfo.processInfo.arguments.contains("--copy-my-shot") ? .copyMyShot
                    : ProcessInfo.processInfo.arguments.contains("--brick-blast") ? .brickBlast : nil
                if let selected {
                    model.showGameIntro(); model.selectGame(selected); model.newRound()
                }
                let state = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--wall-state=") }?
                    .replacingOccurrences(of: "--wall-state=", with: "") ?? "playing"
                if state == "searching" { model.beginCalibration(); model.cornerDots = .large; return }
                if state == "focusing" { model.beginCalibration(); model.isFocusing = true; return }
                if state == "focus-failed" { model.focusAcquisitionFailed(); return }
                if state == "failed" { model.calibrationFailed(); return }
                model.setCorners([CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                                  CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)])
                if state == "mapping" { model.beginMappingCheck(); model.mappingDotsVisible = true; return }
                // Synthetic UI state only. Physical builds get this report from camera observations.
                model.finishMappingCheck(.init(status: state == "mapping-failed" ? .missingPoints : .passed,
                    cornersNormalised: model.corners.map { [Double($0.x), Double($0.y)] },
                    frameWidth: 1280, frameHeight: 720, samples: [], limitCells: WallMappingCheck.limit))
                if state == "mapping-failed" { return }
                if state == "reference" {
                    model.beginReference(); model.showReference(box: WallReferenceCollector.wallCentre, progress: 0.65); return
                }
                model.finishReference([0.04])
                if model.game.isArcade {
                    prepareArcadePreview(state: state)
                    return
                }
                if ["intro", "cleared", "stopped", "saving"].contains(state) {
                    let previous = Date().addingTimeInterval(-100)
                    model.startPlay(at: previous)
                    let previousSequence = model.game.layout.targets.flatMap { Array(repeating: $0.id, count: $0.health) }
                    for (index, box) in previousSequence.enumerated() {
                        let frame = model.game.layout.target(box)!.frame
                        model.record(box: box, u: frame.midX, v: frame.midY,
                                     at: previous.addingTimeInterval(Double(index + 1) * 4.8), footprint: .preview)
                    }
                    model.newRound()
                }
                if state == "intro" { model.showGameIntro(); return }
                if state == "countdown" { model.countdown = 3; model.notice = "Board aligned · get ready"; return }
                let start = Date().addingTimeInterval(-18)
                model.startPlay(at: start)
                if state == "go" { model.showGoCue(); return }
                model.recordingState = .recording
                if state == "pristine" { return }
                if state == "brick-still" {
                    let frame = model.game.layout.target(12)!.frame
                    model.record(box: 12, u: frame.maxX + 0.004, v: frame.maxY - 0.02,
                                 approachSpeed: 12, footprint: .preview)
                    exportImpact()
                    return
                }
                if state == "brick-demo" {
                    // Simulator-only visual QA: exercise cracking, repeated hits,
                    // shattering and completion without a camera or a recording.
                    Task { @MainActor in
                        for (index, box) in [12, 11, 13, 5, 7, 9, 15, 18, 22, 25, 1, 3, 16, 21, 24, 2, 4, 6, 8, 10, 14, 17, 19, 20, 23, 26, 27, 28, 29, 30].enumerated() {
                            if model.remainingHealth(for: box) == 0 { continue }
                            try? await Task.sleep(for: .seconds(1.8))
                            let x = index.isMultiple(of: 2) ? 0.36 : 0.64
                            let frame = model.game.layout.target(box)!.frame
                            model.record(box: box, u: frame.minX + x * frame.width,
                                         v: frame.minY + 0.4 * frame.height,
                                         approachSpeed: [3.0, 12.0, 24.0][index % 3], footprint: .preview)
                        }
                        model.recordingState = .saved
                    }
                    return
                }
                let finished = ["cleared", "saving"].contains(state)
                let sequence = model.game == .brickBlast
                    ? (finished ? model.game.layout.targets.flatMap { Array(repeating: $0.id, count: $0.health) } : [1, 5, 9])
                    : (finished ? Array(1...6) : [4, 5])
                for (index, box) in sequence.enumerated() {
                    let frame = model.game.layout.target(box)!.frame
                    model.record(box: box, u: frame.minX + (box.isMultiple(of: 2) ? 0.7 : 0.3) * frame.width,
                                 v: frame.minY + 0.35 * frame.height,
                                 at: start.addingTimeInterval(finished ? Double(index + 1) * 18.6 / Double(sequence.count) : Double(index + 1) * 3.1), footprint: .preview)
                }
                if state == "cleared" { model.recordingState = .saved }
                if state == "saving" { model.recordingState = .saving }
                if state == "stopped" { model.finishSession(); model.recordingState = .saved }
                if state == "paused" {
                    model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2), at: Date().addingTimeInterval(-5))
                }
                if state == "contact" {
                    model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2))
                    model.showContactPreview(.init(t: 10, x: 600, y: 250, d: 44, turn: 70,
                                                   u: 1.7, v: 0.65, box: 2))
                }
            }
            .task(id: model.isPlaying) {
                guard ProcessInfo.processInfo.arguments.contains("--wall-state=arcade-demo"), model.game.isArcade else { return }
                while model.isPlaying && !Task.isCancelled {
                    model.tickArcade()
                    let host = ProcessInfo.processInfo.systemUptime, time = model.arcadeTime(at: host)
                    var point: CGPoint?
                    if let state = model.memory, state.phase == .recalling,
                       time > state.phaseStart + Double(state.cursor + 1) * 1.3 {
                        let pad = model.game.layout.target(state.sequence[state.cursor])!.frame
                        point = CGPoint(x: pad.midX, y: pad.midY)
                    } else if let state = model.meteors,
                              let meteor = state.visible(at: time).first(where: { time - $0.spawn > 3 }) {
                        point = meteor.position(at: time)
                    } else if let state = model.crossCircle, time > state.readyAt + 2 {
                        let id = [1, 4, 5, 2, 9][min(state.cells.count, 4)]
                        let r = model.game.layout.target(id)!.frame
                        point = CGPoint(x: r.midX, y: r.midY)
                    } else if let state = model.goalDuel, time > state.readyAt + 2.5 {
                        let head = state.keeper(at: time)[0].frame
                        point = state.shots.count % 4 == 1 ? CGPoint(x: head.midX, y: head.midY) : CGPoint(x: 0.48, y: 0.45)
                    }
                    if model.game.isParty && point == nil && time > model.partyReadyAt + 1.3 {
                        point = battleDemoPoint()
                    }
                    if let point {
                        model.accept(.init(t: host, x: 600, y: 300, d: 44, turn: 90,
                            u: point.x, v: point.y, box: nil, footprint: .preview), hostTime: host) { _ in }
                    }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                if model.sessionEnded && !Task.isCancelled {
                    model.recordingState = .saved
                    if let data = try? JSONSerialization.data(withJSONObject: model.gameMetadata, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-arcade-demo.json"), options: .atomic)
                    }
                    exportBoard()
                }
            }
    }

    private func prepareArcadePreview(state: String) {
        if state == "intro" { model.showGameIntro(); return }
        if state == "countdown" { model.countdown = 3; return }
        if model.game.isParty { preparePartyPreview(state: state); return }
        if state == "won" || state == "lost" {
            finishArcadePreview(win: state == "won")
            return
        }
        let host = ProcessInfo.processInfo.systemUptime
        let offset = state == "arcade-demo" ? 0 : model.game == .memoryStrike ? (state == "watching" ? 1.5 : 6.2) : 8.4
        model.startPlay(at: Date().addingTimeInterval(-offset), hostTime: host - offset, seed: 17)
        model.recordingState = .recording
        model.tickArcade(hostTime: host)
        if state == "meteor-impact", let meteor = model.meteors?.visible(at: offset).first {
            let point = meteor.position(at: offset)
            model.accept(.init(t: host, x: 600, y: 300, d: 44, turn: 90,
                u: point.x, v: point.y, box: nil, footprint: .preview), hostTime: host) { _ in }
            model.freezeArcadePreview(at: host + 0.30)
            return
        }
        if state == "stopped" { model.finishSession(hostTime: host); model.recordingState = .saved }
        if state == "paused" {
            model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2), hostTime: host)
        }
        if state != "arcade-demo" { model.freezeArcadePreview(at: host) }
    }

    private func preparePartyPreview(state: String) {
        let host = ProcessInfo.processInfo.systemUptime, date = Date()
        let offset = state == "arcade-demo" ? 0.0 : 120.0
        model.startPlay(at: date.addingTimeInterval(-offset), hostTime: host - offset, seed: 17)
        model.recordingState = .recording
        if state == "arcade-demo" { return }
        var last = 0.0
        func hit(_ p: CGPoint, _ t: Double) {
            model.accept(.init(t: host - offset + t, x: 600, y: 300, d: 44, turn: 90,
                u: p.x, v: p.y, box: nil,
                footprint: .init(xAxis: CGPoint(x: 0.04, y: 0), yAxis: CGPoint(x: 0, y: 0.04))),
                at: date.addingTimeInterval(t - offset + 0.2), hostTime: host - offset + t + 0.2) { _ in }
            last = t + 0.2
        }
        if model.game == .crossCircle {
            let sequence = state == "won" ? [1, 4, 5, 2, 9]
                : state == "draw" ? [1, 2, 3, 5, 4, 6, 8, 7, 9] : [5, 1, 9, 3]
            for id in sequence {
                let f = model.game.layout.target(id)!.frame
                hit(CGPoint(x: f.midX, y: f.midY), model.partyReadyAt + 1)
            }
        } else if model.game == .goalDuel {
            let count = ["won", "draw"].contains(state) ? 10 : state == "impact" ? 1 : 4
            for i in 0..<count {
                let t = model.partyReadyAt + 1
                let head = model.goalDuel!.keeper(at: t)[0].frame
                let saved = state != "draw" && i % 4 == 1
                hit(saved ? CGPoint(x: head.midX, y: head.midY) : CGPoint(x: 0.48, y: 0.45), t)
            }
        }
        if [.fourInRow, .territoryDuel, .copyMyShot].contains(model.game) {
            let count = ["won", "draw"].contains(state) ? 42 : state == "impact" ? 3 : model.game == .fourInRow ? 4 : 7
            for _ in 0..<count where model.isPlaying {
                if let p = battleDemoPoint() { hit(p, model.partyReadyAt + 1) }
            }
        }
        let freeze = host - offset + (state == "impact" ? last + 0.3 : model.partyReadyAt + 1)
        if state == "paused" {
            model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2), hostTime: freeze)
        }
        if !model.sessionEnded { model.freezeArcadePreview(at: freeze) }
        else { model.recordingState = .saved }
    }

    private func battleDemoPoint() -> CGPoint? {
        if let state = model.fourInRow {
            let column = [1, 2, 1, 3, 1, 4, 1][min(state.cells.count, 6)]
            return WallFourInRow.centre(column)
        }
        if let state = model.territoryDuel {
            let id = [1, 9, 4, 12, 6, 13, 7, 10, 2, 8, 3, 11, 5, 9, 9, 6, 6, 4, 4, 12][min(state.shots, 19)]
            return WallTerritoryDuel.zones[id - 1].centre
        }
        if let state = model.copyMyShot {
            if let target = state.target {
                return CGPoint(x: target.x + (state.setter == .one ? 0.42 : 0.10), y: target.y + 0.04)
            }
            return CGPoint(x: [1.8, 0.8, 1.5, 2.1, 0.9, 1.6][min(state.challenges.count, 5)], y: 0.75 + Double(state.challenges.count % 2) * 0.40)
        }
        return nil
    }

    private func finishArcadePreview(win: Bool) {
        let host = ProcessInfo.processInfo.systemUptime - 600, date = Date().addingTimeInterval(-600)
        model.startPlay(at: date, hostTime: host, seed: 17)
        func tick(_ t: Double) { model.tickArcade(at: date.addingTimeInterval(t), hostTime: host + t) }
        func hit(_ p: CGPoint, _ t: Double) {
            model.accept(.init(t: host + t, x: 600, y: 300, d: 44, turn: 90, u: p.x, v: p.y, box: nil,
                footprint: .preview), at: date.addingTimeInterval(t + 0.2), hostTime: host + t + 0.2) { _ in }
        }
        for _ in 0..<5 where model.isPlaying {
            if let memory = model.memory {
                if memory.phase == .interlude { tick(memory.phaseStart + 1.7) }
                tick(model.memory!.watchEnd + 0.01)
                let memory = model.memory!
                for (index, target) in memory.sequence.enumerated() {
                    let id = win ? target : target % 4 + 1
                    let pad = model.game.layout.target(id)!.frame
                    hit(CGPoint(x: pad.midX, y: pad.midY), memory.phaseStart + Double(index + 1) * 2)
                    if !win { break }
                }
            } else if let meteors = model.meteors {
                if !win { tick(100); break }
                if meteors.phase == .interlude { tick(meteors.phaseStart + 2.6) }
                for meteor in model.meteors!.meteors {
                    let t = meteor.spawn + 2
                    hit(meteor.position(at: t), t)
                }
            }
        }
        model.recordingState = .saved
    }

    private func exportBoard() {
        let renderer = ImageRenderer(content: previewBoard
            .frame(width: 1600, height: 900))
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-board-preview.png"), options: .atomic)
        let projector = ImageRenderer(content: WallTargetsBoard(model: model).frame(width: 1600, height: 900))
        projector.scale = 1
        if let data = projector.uiImage?.pngData() {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-projector-preview.png"), options: .atomic)
        }
    }

    /// A fixed frame of the shipping renderer for comparing material and shard
    /// geometry. It uses a synthetic contact, not a claimed camera observation.
    private func exportImpact() {
        guard let hit = model.lastHit else { return }
        let size = CGSize(width: 1600, height: 900)
        let rect = WallTargetsBoard.boardRect(in: size)
        let localBoard = CGRect(origin: .zero, size: rect.size)
        let bricks = hit.brickDamage.compactMap { damage -> WallBrickExplosion.Brick? in
            guard let target = model.game.layout.target(damage.id) else { return nil }
            return .init(id: damage.id, frame: target.screenFrame(in: localBoard), shattered: damage.shattered)
        }
        let radius = sqrt(abs(hit.footprint!.determinant) * rect.width / 3 * rect.height / 2)
        let content = WallTargetsBoard(model: model).frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                WallBrickExplosion(bricks: bricks,
                    origin: CGPoint(x: hit.u / 3 * rect.width, y: hit.v / 2 * rect.height),
                    ballRadius: radius, strength: WallImpactMotion.strength(for: hit.approachSpeed), previewAge: 0.32)
                    .frame(width: rect.width, height: rect.height).clipped()
                    .offset(x: rect.minX, y: rect.minY)
            }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        if let data = renderer.uiImage?.pngData() {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-impact-preview.png"), options: .atomic)
        }
    }
}
#endif
