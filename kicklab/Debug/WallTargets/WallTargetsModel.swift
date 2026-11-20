#if DEBUG
import Combine
import CoreGraphics
import Foundation

/// Projector looks, taken from benchmarks/wall-targets/grid.html.
enum WallBoardStyle: String, CaseIterable, Identifiable {
    /// Clear-the-wall board: cyan targets, gold when hit.
    case metal
    /// grid.html with every box lit: glowing green boxes; a hit turns its box pale with a tick.
    case green
    /// Like green, but each box glows in its own colour so boxes are easy to tell apart.
    case neon
    /// grid.html's default: black boxes with glowing numbers that turn green when hit.
    case glow
    /// grid.html's B mode: black boxes, thick white lines, saturated green hits.
    case bright

    var id: String { rawValue }
    var title: String {
        switch self {
        case .metal: "Clear the wall"
        case .green: "Green"
        case .neon: "Neon"
        case .glow: "Glow"
        case .bright: "Bright room"
        }
    }
}

/// The board's corner dots: shown normally, or blinked large/hidden while the
/// camera finds them (see WallCornerFinder).
enum WallCornerDots {
    case normal, large, hidden
}

nonisolated enum WallRecordingState: Equatable, Sendable {
    case idle, recording, saving, saved
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "No recording"
        case .recording: return "Recording"
        case .saving: return "Saving video and shot data…"
        case .saved: return "Video and shot data saved"
        case .failed: return "Recording needs attention · open settings"
        }
    }
}

/// Board state shared by the phone screen and the projector window. Live ball
/// positions stay on the camera object so the projector does not redraw per frame.
@MainActor
final class WallTargetsModel: ObservableObject {
    static let shared = WallTargetsModel()
    @Published var arcadePresented = false
    @Published var arcadeSetupGuidePresented = false

    enum Calibration: Equatable { case required, searching, ready, failed }
    enum GameScreen: Equatable { case intro, board, results }
    @Published private(set) var gameScreen: GameScreen = .board
    @Published private(set) var game: WallGame
    @Published private(set) var reusableSetup: WallSetupReuse?
    var hasReusableSetup: Bool { reusableSetup != nil && calibration == .ready && wallReference != nil && mappingReport?.passed == true }

    func rememberSetup(frameSize: CGSize) {
        guard calibration == .ready, wallReference != nil, mappingReport?.passed == true else { return }
        reusableSetup = WallSetupReuse(corners: corners, frameSize: frameSize)
    }

    private var lastAcceptedContactTime: Double?
    @Published private(set) var bestClearTime: TimeInterval?
    @Published private(set) var previousBest: TimeInterval?
    @Published private(set) var isNewBest = false
    @Published private(set) var bestArcadeScore = 0
    @Published private(set) var memory: WallMemoryStrike?
    /// Keep alignment and the game clock running while the pattern is shown.
    /// Only Memory Strike has a phase in which ball input is deliberately ignored.
    var needsGameplayInference: Bool { game != .memoryStrike || memory?.phase == .recalling }
    @Published private(set) var meteors: WallMeteorDefence?
    @Published private(set) var crossCircle: WallCrossCircle?
    @Published private(set) var goalDuel: WallGoalDuel?
    @Published private(set) var fourInRow: WallFourInRow?
    @Published private(set) var territoryDuel: WallTerritoryDuel?
    @Published private(set) var copyMyShot: WallCopyMyShot?
    @Published private(set) var arcadeClock = WallGameClock()
    @Published private(set) var arcadeWon: Bool?
    @Published private(set) var calibration: Calibration = .required
    @Published private(set) var isPlaying = false
    @Published private(set) var sessionEnded = false
    @Published var recordingState: WallRecordingState = .idle
    @Published private(set) var wallReference: WallBallReference?
    @Published private(set) var referenceBox: Int?
    @Published private(set) var referenceProgress = 0.0
    @Published private(set) var referenceFailed = false
    @Published var isFocusing = false
    @Published private(set) var focusFailed = false
    @Published private(set) var checkingMapping = false
    @Published var mappingDotsVisible = false
    @Published private(set) var mappingReport: WallMappingCheck.Report?
    var mappingFailed: Bool { mappingReport.map { !$0.passed } ?? false }
    @Published var countdown: Int?
    @Published private(set) var showingGo = false
    @Published private(set) var contactPreview: WallImpactDetector.Impact?
    private var goToken = UUID()
    @Published var notice: String?
    @Published private(set) var alignmentStatus = WallBoardAlignment.Status.checking
    @Published private(set) var borderlineNotice: String?
    private var borderlineToken = UUID()
    private var alignmentPausedAt: Date?
    private var endedElapsed: TimeInterval?

    var alignmentNotice: String? {
        if isFocusing { return "Focusing on the wall · stand aside" }
        switch alignmentStatus {
        case .ready: return nil
        case .checking: return "Checking the four corner dots · stand aside"
        case .obscured: return "Paused · keep all four dots visible"
        case .shifted: return "Scoring paused · realigning the board"
        case .referenceRequired: return "Board size changed · tap to repeat setup"
        }
    }

    var timerStatus: String {
        if clearedAt != nil { return "CLEARED" }
        if sessionEnded { return "STOPPED" }
        if !isPlaying { return "SETUP" }
        if alignmentStatus != .ready { return "PAUSED" }
        return roundStart == nil ? "READY" : "LIVE"
    }

    struct Hit: Identifiable, Equatable {
        let id = UUID()
        let box: Int?
        let u, v: Double
        let at: Date
        var approachSpeed: Double? = nil
        var footprint: WallContactFootprint? = nil
        var brickDamage: [WallBrickDamage] = []
    }

    struct Clear: Equatable {
        let at: Date
        let seconds: TimeInterval
    }

    @Published private(set) var hits: [Hit] = []
    @Published private(set) var roundStart: Date?
    @Published private(set) var clearedAt: Date?
    /// Every cleared round since launch, for session results.
    @Published private(set) var clears: [Clear] = []
    @Published private(set) var projectorConnected = false
    /// Board corners in the camera frame, normalised 0...1 with a top-left
    /// origin, in order TL, TR, BR, BL. These are the four projected corner dots.
    @Published private(set) var corners: [CGPoint]
    @Published var cornerDots = WallCornerDots.normal
    @Published var style: WallBoardStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }

    private static let cornersKey = "wallTargets.corners"
    private static let styleKey = "wallTargets.style.v3"
    private static let gameKey = "wallTargets.selectedGame.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let selected = defaults.string(forKey: Self.gameKey).flatMap(WallGame.init(rawValue:)) ?? .clearTheWall
        game = selected
        bestArcadeScore = defaults.integer(forKey: selected.bestScoreKey)
        let best = defaults.double(forKey: selected.bestTimeKey)
        bestClearTime = best.isFinite && best > 0 ? best : nil
        style = defaults.string(forKey: Self.styleKey).flatMap(WallBoardStyle.init) ?? .metal
        let saved = (defaults.array(forKey: Self.cornersKey) as? [Double]) ?? []
        corners = saved.count == 8
            ? stride(from: 0, to: 8, by: 2).map { CGPoint(x: saved[$0], y: saved[$0 + 1]) }
            : Self.defaultCorners
    }

    private static let defaultCorners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                                         CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
    /// Still the placeholder corners: hits would land in the wrong boxes.
    var cornersNotSet: Bool { calibration != .ready }

    var boxesHit: Set<Int> {
        game == .brickBlast ? Set(hits.flatMap { $0.brickDamage.map(\.id) }) : Set(hits.compactMap(\.box))
    }
    var brickScore: Int { clearedBoxes.count * 100 }
    var lastHit: Hit? { hits.last }
    func remainingHealth(for box: Int) -> Int {
        let damage = game == .brickBlast
            ? hits.flatMap(\.brickDamage).filter { $0.id == box }.reduce(0) { $0 + $1.amount }
            : hits.filter { $0.box == box }.count
        return max(0, game.initialHealth(for: box) - damage)
    }
    var clearedBoxes: Set<Int> { Set(game.targetIDs.filter { remainingHealth(for: $0) == 0 }) }
    var damageRemaining: Int { game.targetIDs.reduce(0) { $0 + remainingHealth(for: $1) } }

    /// A selection is explicit, and cannot replace a running or saving round.
    @discardableResult
    func selectGame(_ selected: WallGame, preservingSetup: Bool = false) -> Bool {
        guard gameScreen != .board, !isPlaying, canStartGame else { return false }
        guard game != selected else { return true }
        game = selected
        bestArcadeScore = defaults.integer(forKey: selected.bestScoreKey)
        defaults.set(selected.rawValue, forKey: Self.gameKey)
        let best = defaults.double(forKey: selected.bestTimeKey)
        bestClearTime = best.isFinite && best > 0 ? best : nil
        if !preservingSetup || !hasReusableSetup { invalidateCalibration() }
        newRound()
        gameScreen = .intro
        return true
    }

    var gameMetadata: [String: Any] {
        var metadata: [String: Any] = ["game": game.rawValue, "gameTitle": game.title, "layout": game.layout.id,
         "targetCount": game.targetCount,
         "brickVisuals": "bevelled-rubble-v5",
         "brickAudio": "layered-masonry-v2",
         "continuousSurface": game.layout.continuousSurface,
         "destructionCoreRadius": WallBrickDestruction.coreRadius,
         "destructionShockRadius": WallBrickDestruction.shockRadius,
         "brickScore": brickScore,
         "impactMotionUnits": "image-plane ball diameters per second; visual only, not physical shot speed",
         "targets": game.layout.targets.map { ["id": $0.id, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], "health": $0.health, "faceInset": $0.faceInset] as [String: Any] },
         "ballReferenceMode": wallReference.map { $0.diameters.count == 1 ? "single-centre-hold-v1" : "legacy-six-point-v1" } ?? "pending-centre-hold",
         "initialTargetHealth": game.initialHealth,
         "remainingTargetHealth": game.targetIDs.map { remainingHealth(for: $0) },
         "destroyedTargets": clearedBoxes.sorted(),
         "gameRules": game == .brickBlast
            ? "Confirmed wall contacts break material within 1.15 ball radii and damage neighbours within 2.0 radii. One impact can affect multiple bricks; image-plane speed changes visuals only."
            : game.instructions]
        if game.isArcade {
            metadata["arcadeScore"] = arcadeScore
            metadata["arcadeWon"] = arcadeWon as Any? ?? NSNull()
            metadata["arcadeEvents"] = arcadeEvents.map(\.json)
            metadata["arcadeClock"] = arcadeClock.json
            metadata["arcadeTimeBasis"] = "Active monotonic host seconds; animation and hit test use contact capture time, excluding alignment pauses."
            metadata["arcadeSeed"] = memory?.seed ?? meteors?.seed ?? 0
            metadata["arcadeVisuals"] = game == .memoryStrike ? "projector-memory-cues-v3" : "metal-city-and-symbols-v2"
            if let memory {
                metadata["memorySymbols"] = ["star", "moon", "sun", "diamond"]
                metadata["memoryPattern"] = memory.pattern
                metadata["memoryRoundsCompleted"] = memory.completedRounds
                metadata["memoryLives"] = memory.lives
            }
            if let meteors {
                metadata["meteorWave"] = meteors.wave
                metadata["meteorShields"] = meteors.shields
                metadata["meteorsDestroyed"] = meteors.destroyed
                metadata["meteorConfirmationGrace"] = WallMeteorDefence.confirmationGrace
            }
            if game.isParty {
                metadata["arcadeVisuals"] = game == .crossCircle ? "projector-cross-circle-v3-hybrid" : "projector-party-v1"
                metadata["players"] = 2
                metadata["playerAssignment"] = "Alternating displayed turns; one shared ball; no person identification."
                metadata["partyFinished"] = partyFinished
                metadata["winner"] = partyWinner?.rawValue as Any? ?? NSNull()
                metadata["playerScores"] = [partyScore(.one), partyScore(.two)]
                if let fourInRow {
                    metadata["claimedCells"] = fourInRow.cells.map { ["cell": $0.key, "player": $0.value.rawValue] }
                    metadata["winningLine"] = fourInRow.winningLine
                    metadata["chipDrops"] = fourInRow.drops.map { ["cell": $0.cell, "player": $0.player.rawValue, "activeTime": $0.time] }
                    metadata["turnHandoverSeconds"] = WallFourInRow.handover
                }
                if let territoryDuel {
                    metadata["zoneOwners"] = territoryDuel.owners.map { ["zone": $0.key, "player": $0.value.rawValue] }
                    metadata["zoneVertices"] = WallTerritoryDuel.zones.map { ["zone": $0.id, "vertices": $0.vertices.map { [$0.x, $0.y] }] }
                    metadata["shotsPlayed"] = territoryDuel.shots
                    metadata["shotsPerPlayer"] = WallTerritoryDuel.shotsPerPlayer
                    metadata["shotSeconds"] = WallTerritoryDuel.shotSeconds
                    metadata["turnHandoverSeconds"] = WallTerritoryDuel.handover
                }
                if let copyMyShot {
                    metadata["copyChallenges"] = copyMyShot.challenges.map(\.json)
                    metadata["matchRadiusBoardUnits"] = WallCopyMyShot.radius
                    metadata["shotSeconds"] = WallCopyMyShot.shotSeconds
                    metadata["turnHandoverSeconds"] = WallCopyMyShot.handover
                    metadata["copyTarget"] = copyMyShot.target.map { [$0.x, $0.y] } as Any? ?? NSNull()
                }
                if let crossCircle {
                    metadata["claimedCells"] = crossCircle.cells.map { ["cell": $0.key, "player": $0.value.rawValue] }
                    metadata["winningLine"] = crossCircle.winningLine
                    metadata["turnHandoverSeconds"] = WallCrossCircle.handover
                }
                if let goalDuel {
                    metadata["goalShots"] = goalDuel.shots.map(\.json)
                    metadata["playerGoals"] = [goalDuel.goals(.one), goalDuel.goals(.two)]
                    metadata["shotSeconds"] = WallGoalDuel.shotSeconds
                    metadata["turnHandoverSeconds"] = WallGoalDuel.handover
                    metadata["keeperCollision"] = "Ball ellipse against visible robot parts at contact capture time."
                }
            }
        }
        return metadata
    }
    /// A new recording cannot replace a recording that is still being finalized.
    var canStartGame: Bool {
        guard !arcadeSetupGuidePresented else { return false }
        switch recordingState {
        // Failed sessions stay in their own recorder folder for investigation.
        // An explicit retry starts a separate folder after finalization returns.
        case .idle, .saved, .failed: return true
        case .recording, .saving: return false
        }
    }

    func showGameIntro() {
        pause()
        gameScreen = .intro
    }

    func showBoardForSettings() {
        pause()
        gameScreen = .board
    }

    /// Reacquire geometry and ball samples for every explicit attempt. Returning
    /// from results must never authorize scoring with stale setup evidence.
    @discardableResult
    func beginGameSetup(usingCurrentCorners: Bool = false, reusingSetup: Bool = false) -> Bool {
        guard canStartGame else { return false }
        // Do not show the previous round's saved status if this setup is stopped
        // before the camera has started its new recording.
        recordingState = .idle
        referenceFailed = false
        focusFailed = false
        notice = nil
        // Manual corners selected in the settings screen are an allowed starting
        // geometry. Mapping and ball reference must still be measured afresh.
        if reusingSetup && hasReusableSetup { alignmentStatus = .checking }
        else if usingCurrentCorners && calibration == .ready { _ = setCorners(corners) }
        else { invalidateCalibration() }
        newRound()
        return true
    }
    var clearTime: TimeInterval? {
        guard let roundStart, let clearedAt else { return nil }
        return clearedAt.timeIntervalSince(roundStart)
    }

    func elapsed(at date: Date) -> TimeInterval {
        clearTime ?? endedElapsed ?? roundStart.map { max(0, (alignmentPausedAt ?? date).timeIntervalSince($0)) } ?? 0
    }

    /// Deliver confirmed feedback synchronously with an accepted score. The cue
    /// must not wait for either the phone or external SwiftUI view to redraw.
    @discardableResult
    func accept(_ impact: WallImpactDetector.Impact, at date: Date = Date(),
                hostTime: Double = ProcessInfo.processInfo.systemUptime,
                onScored: (_ cleared: Bool) -> Void) -> Bool {
        if impact.borderline { recordBorderline(); return false }
        if game.isArcade { return acceptArcade(impact, at: date, hostTime: hostTime, onScored: onScored) }
        if game == .brickBlast {
            guard impact.t.isFinite, lastAcceptedContactTime.map({ impact.t > $0 }) ?? true else { return false }
        }
        guard record(box: impact.box, u: impact.u, v: impact.v, at: date, approachSpeed: impact.approachSpeed, footprint: impact.footprint) else { return false }
        if game == .brickBlast { lastAcceptedContactTime = impact.t }
        onScored(clearedAt != nil)
        return true
    }

    @discardableResult
    func record(box: Int?, u: Double, v: Double, at date: Date = Date(), approachSpeed: Double? = nil,
                footprint: WallContactFootprint? = nil) -> Bool {
        guard !game.isArcade, gameScreen == .board, isPlaying, calibration == .ready, alignmentStatus == .ready,
              u.isFinite, v.isFinite, clearedAt == nil, !sessionEnded else { return false }
        var damage: [WallBrickDamage] = []
        var primary = box
        if game == .brickBlast {
            guard let footprint, footprint.isValid else { return false }
            let health = Dictionary(uniqueKeysWithValues: game.targetIDs.map { ($0, remainingHealth(for: $0)) })
            damage = WallBrickDestruction.damage(at: CGPoint(x: u, y: v), footprint: footprint,
                                                layout: game.layout, health: health)
            guard !damage.isEmpty else { return false }
            // Primary is retained only for old log readers. Damage/animation use
            // the entire affected set, including a hit centred in a mortar gap.
            if !damage.contains(where: { $0.id == primary }) {
                primary = damage.min { a, b in
                    let ar = game.layout.target(a.id)!.frame, br = game.layout.target(b.id)!.frame
                    return hypot(ar.midX - u, ar.midY - v) < hypot(br.midX - u, br.midY - v)
                }?.id
            }
        } else {
            guard let box, game.targetIDs.contains(box), game.layout.target(u: u, v: v) == box else { return false }
        }
        if roundStart == nil { roundStart = date }
        hits.append(Hit(box: primary, u: u, v: v, at: date,
                        approachSpeed: approachSpeed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        footprint: footprint, brickDamage: damage))
        if clearedBoxes.count == game.targetCount, let roundStart {
            clearedAt = date
            let seconds = date.timeIntervalSince(roundStart)
            clears.append(Clear(at: date, seconds: seconds))
            if seconds.isFinite, seconds > 0, bestClearTime.map({ seconds < $0 }) ?? true {
                isNewBest = true
                bestClearTime = seconds
                defaults.set(seconds, forKey: game.bestTimeKey)
            }
            finishSession(at: date)
        }
        return true
    }

    func newRound() {
        pause()
        gameScreen = .board
        previousBest = bestClearTime
        isNewBest = false
        hits = []
        lastAcceptedContactTime = nil
        memory = nil; meteors = nil; crossCircle = nil; goalDuel = nil
        fourInRow = nil; territoryDuel = nil; copyMyShot = nil
        arcadeClock = WallGameClock(); arcadeWon = nil
        contactPreview = nil
        roundStart = nil
        clearedAt = nil
        sessionEnded = false
        endedElapsed = nil
    }

    /// Keep the impact map and final time until the next explicit session.
    func finishSession(at date: Date = Date(), hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        if !sessionEnded { endedElapsed = elapsed(at: date) }
        arcadeClock.pause(at: hostTime)
        pause()
        sessionEnded = true
        gameScreen = .results
    }

    /// Alignment updates preserve the round and wall-size samples. A material
    /// scale/perspective change instead invalidates those samples explicitly.
    func applyAlignment(_ update: WallBoardAlignment.Update, at date: Date = Date(),
                        hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        alignmentStatus = update.status
        if game.isArcade && isPlaying {
            if update.status == .ready { arcadeClock.resume(at: hostTime) }
            else { arcadeClock.pause(at: hostTime) }
        }
        if update.status != .ready && update.status != .obscured { contactPreview = nil }
        if update.status == .ready, WallBoard.validCalibration(update.corners) {
            corners = update.corners
            defaults.set(corners.flatMap { [Double($0.x), Double($0.y)] }, forKey: Self.cornersKey)
            if let paused = alignmentPausedAt, let start = roundStart, clearedAt == nil {
                roundStart = start.addingTimeInterval(date.timeIntervalSince(paused))
            }
            alignmentPausedAt = nil
        } else if isPlaying, alignmentPausedAt == nil {
            alignmentPausedAt = date
        }
        if update.status == .referenceRequired {
            reusableSetup = nil
            pause()
            wallReference = nil
            referenceFailed = true
            notice = "Board size changed · tap to repeat setup"
        }
    }

    func recordBorderline() {
        guard isPlaying, alignmentStatus == .ready, clearedAt == nil else { return }
        let token = UUID(); borderlineToken = token
        borderlineNotice = game.isArcade ? "Edge hit · aim inside the target"
            : game == .brickBlast ? "Edge hit · aim inside a brick" : "Borderline · aim farther inside the box"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.borderlineToken == token else { return }
            self.borderlineNotice = nil
        }
    }

    /// A tentative contact never changes the score, hit map, sound or round end.
    func showContactPreview(_ impact: WallImpactDetector.Impact?) {
        let allowed = isPlaying && !sessionEnded && calibration == .ready
            && (alignmentStatus == .ready || alignmentStatus == .obscured)
        let next = allowed ? impact : nil
        guard next != contactPreview else { return }
        contactPreview = next
        if let next {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                if self?.contactPreview == next { self?.contactPreview = nil }
            }
        }
    }

    func showGoCue() {
        guard isPlaying, !sessionEnded else { return }
        let token = UUID(); goToken = token
        showingGo = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if self?.goToken == token { self?.showingGo = false }
        }
    }

    @discardableResult
    func setCorners(_ points: [CGPoint]) -> Bool {
        reusableSetup = nil
        pause()
        wallReference = nil
        mappingReport = nil
        guard WallBoard.validCalibration(points) else { calibration = .failed; return false }
        corners = points
        calibration = .ready
        alignmentStatus = .ready
        defaults.set(points.flatMap { [Double($0.x), Double($0.y)] }, forKey: Self.cornersKey)
        return true
    }

    func beginCalibration() {
        reusableSetup = nil
        pause()
        wallReference = nil
        referenceFailed = false
        mappingReport = nil
        calibration = .searching
        focusFailed = false
        notice = nil
        newRound()
    }

    func invalidateCalibration() {
        reusableSetup = nil
        pause()
        wallReference = nil
        mappingReport = nil
        calibration = .required
        alignmentStatus = .checking
    }

    func calibrationFailed() {
        reusableSetup = nil
        pause()
        wallReference = nil
        calibration = .failed
        notice = "Can't see all four corners · tap to retry"
    }

    func alignmentSetupFailed() {
        invalidateCalibration()
        calibrationFailed()
        notice = "Corner positions could not be confirmed · tap to find them again"
    }

    func focusAcquisitionFailed() {
        calibrationFailed()
        focusFailed = true
        notice = "Camera could not settle focus · stand aside and tap to retry"
    }

    func beginMappingCheck() {
        pause()
        mappingReport = nil
        checkingMapping = true
        notice = "Checking the whole board · stand aside"
    }

    @discardableResult
    func finishMappingCheck(_ report: WallMappingCheck.Report) -> Bool {
        checkingMapping = false
        mappingDotsVisible = false
        mappingReport = report
        notice = report.passed ? "Board checked · ready for ball setup"
            : "Board check needs a retry · keep the phone still and the wall clear"
        return report.passed
    }

    @discardableResult
    func startPlay(at date: Date = Date(), hostTime: Double = ProcessInfo.processInfo.systemUptime,
                   seed: UInt64 = UInt64.random(in: 1...UInt64(UInt32.max))) -> Bool {
        guard !arcadeSetupGuidePresented, gameScreen == .board, !sessionEnded, clearedAt == nil, calibration == .ready, alignmentStatus == .ready,
              mappingReport?.passed == true, !checkingMapping,
              wallReference != nil, referenceBox == nil else { return false }
        countdown = nil
        notice = nil
        isPlaying = true
        if roundStart == nil { roundStart = date }
        if game.isArcade, arcadeClock.segments.isEmpty {
            arcadeClock.start(at: hostTime)
            if game == .memoryStrike { memory = WallMemoryStrike(seed: seed) }
            if game == .meteorDefence { meteors = WallMeteorDefence(seed: seed) }
            if game == .crossCircle { crossCircle = WallCrossCircle() }
            if game == .goalDuel { goalDuel = WallGoalDuel() }
            if game == .fourInRow { fourInRow = WallFourInRow() }
            if game == .territoryDuel { territoryDuel = WallTerritoryDuel() }
            if game == .copyMyShot { copyMyShot = WallCopyMyShot() }
        }
        return true
    }

    func pause() {
        arcadeClock.pause(at: ProcessInfo.processInfo.systemUptime)
        isPlaying = false
        contactPreview = nil
        showingGo = false
        goToken = UUID()
        checkingMapping = false
        mappingDotsVisible = false
        countdown = nil
        referenceBox = nil
        referenceProgress = 0
        alignmentPausedAt = nil
        borderlineToken = UUID()
        borderlineNotice = nil
    }

    func beginReference() {
        pause()
        wallReference = nil
        referenceFailed = false
        newRound()
        showReference(box: WallReferenceCollector.wallCentre, progress: 0)
    }

    func showReference(box: Int, progress: Double) {
        guard calibration == .ready, !isPlaying, (0...6).contains(box) else { return }
        referenceBox = box
        referenceProgress = max(0, min(1, progress))
        notice = "Hold the ball against the wall · keep it still for 3 seconds"
    }

    @discardableResult
    func finishReference(_ diameters: [Double]) -> Bool {
        pause()
        wallReference = calibration == .ready ? WallBallReference(diameters) : nil
        referenceFailed = wallReference == nil
        if referenceFailed { notice = "Samples did not match · tap to repeat setup" }
        return wallReference != nil
    }

    func setProjectorConnected(_ connected: Bool) {
        guard projectorConnected != connected else { return }
        // Invalidate before publishing the route so no shot can be accepted
        // between a scene change and the phone view reacting to it.
        invalidateCalibration()
        projectorConnected = connected
    }

    var arcadeScore: Int { memory?.score ?? meteors?.score ?? 0 }
    var arcadeEvents: [WallArcadeEvent] { memory?.events ?? meteors?.events ?? crossCircle?.events ?? goalDuel?.events ?? battleEvents }
    var partyFinished: Bool { crossCircle?.finished ?? goalDuel?.finished ?? fourInRow?.finished ?? territoryDuel?.finished ?? copyMyShot?.finished ?? false }
    var partyWinner: WallPartyPlayer? { crossCircle?.winner ?? goalDuel?.winner ?? fourInRow?.winner ?? territoryDuel?.winner ?? copyMyShot?.winner }
    var partyPlayer: WallPartyPlayer { crossCircle?.player ?? goalDuel?.player ?? fourInRow?.player ?? territoryDuel?.player ?? copyMyShot?.player ?? .one }
    var partyReadyAt: Double { crossCircle?.readyAt ?? goalDuel?.readyAt ?? fourInRow?.readyAt ?? territoryDuel?.readyAt ?? copyMyShot?.readyAt ?? 0 }
    private var battleEvents: [WallArcadeEvent] { fourInRow?.events ?? territoryDuel?.events ?? copyMyShot?.events ?? [] }
    func partyScore(_ player: WallPartyPlayer) -> Int {
        goalDuel?.goals(player) ?? territoryDuel?.score(player) ?? copyMyShot?.score(player) ?? 0
    }
    var partyResultTitle: String {
        guard partyFinished else { return "MATCH STOPPED" }
        return partyWinner.map { game == .crossCircle ? "\($0.mark) WINS!" : "\($0.name) WINS!" } ?? "IT'S A DRAW!"
    }
    func arcadeTime(at host: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        arcadeClock.time(at: host) ?? 0
    }
    /// Used only by isolated simulator/visual-audit models, never the live camera model.
    func freezeArcadePreview(at host: Double) { arcadeClock.pause(at: host) }
    /// A single phone-owned timer advances rules. Views on any display only
    /// render this state, so connecting a projector cannot run the game twice.
    @discardableResult
    func tickArcade(at date: Date = Date(), hostTime: Double = ProcessInfo.processInfo.systemUptime) -> [WallArcadeCue] {
        guard game.isArcade, isPlaying, alignmentStatus == .ready else { return [] }
        let before = arcadeEvents.count, time = arcadeTime(at: hostTime)
        if var state = memory { state.advance(at: time); if state != memory { memory = state } }
        if var state = meteors { state.advance(at: time); if state != meteors { meteors = state } }
        if var state = goalDuel { state.advance(at: time); if state != goalDuel { goalDuel = state } }
        if var state = territoryDuel { state.advance(at: time); if state != territoryDuel { territoryDuel = state } }
        if var state = copyMyShot { state.advance(at: time); if state != copyMyShot { copyMyShot = state } }
        finishArcadeIfNeeded(at: date, hostTime: hostTime)
        return arcadeEvents.dropFirst(before).compactMap(\.cue)
    }

    private func acceptArcade(_ impact: WallImpactDetector.Impact, at date: Date, hostTime: Double,
                              onScored: (Bool) -> Void) -> Bool {
        guard gameScreen == .board, isPlaying, !sessionEnded, calibration == .ready, alignmentStatus == .ready,
              impact.t.isFinite, impact.u.isFinite, impact.v.isFinite, impact.t <= hostTime,
              hostTime - impact.t <= 1.6, lastAcceptedContactTime.map({ impact.t > $0 }) ?? true,
              let contact = arcadeClock.time(at: impact.t) else { return false }
        lastAcceptedContactTime = impact.t
        let now = arcadeTime(at: hostTime), point = CGPoint(x: impact.u, y: impact.v)
        var target: Int?
        if var state = memory, let pad = game.layout.target(u: impact.u, v: impact.v) {
            if state.hit(target: pad, point: point, contact: contact, now: now) { target = pad }
            memory = state
        } else if var state = meteors, let footprint = impact.footprint {
            target = state.hit(point: point, footprint: footprint, contact: contact, now: now)
            meteors = state
        } else if var state = crossCircle {
            target = state.hit(point: point, contact: contact, now: now)
            crossCircle = state
        } else if var state = goalDuel, let footprint = impact.footprint {
            target = state.hit(point: point, footprint: footprint, contact: contact, now: now)?.id
            goalDuel = state
        } else if var state = fourInRow {
            target = state.hit(point: point, contact: contact, now: now); fourInRow = state
        } else if var state = territoryDuel {
            target = state.hit(point: point, contact: contact, now: now); territoryDuel = state
        } else if var state = copyMyShot {
            target = state.hit(point: point, contact: contact, now: now); copyMyShot = state
        }
        if let target {
            hits.append(Hit(box: target, u: impact.u, v: impact.v, at: date,
                            approachSpeed: impact.approachSpeed, footprint: impact.footprint))
        }
        finishArcadeIfNeeded(at: date, hostTime: hostTime)
        if target != nil { onScored(arcadeWon == true) }
        return target != nil
    }

    private func finishArcadeIfNeeded(at date: Date, hostTime: Double) {
        guard !sessionEnded, memory?.phase == .finished || meteors?.phase == .finished || partyFinished else { return }
        if game.isParty {
            clearedAt = date
            finishSession(at: date, hostTime: hostTime)
            return
        }
        arcadeWon = memory?.won ?? meteors?.won ?? false
        if arcadeWon == true { clearedAt = date }
        if arcadeScore > bestArcadeScore {
            bestArcadeScore = arcadeScore; isNewBest = true
            defaults.set(arcadeScore, forKey: game.bestScoreKey)
        }
        finishSession(at: date, hostTime: hostTime)
    }
}
#endif
