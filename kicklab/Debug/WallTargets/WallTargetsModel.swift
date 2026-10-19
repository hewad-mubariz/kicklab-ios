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

    enum Calibration: Equatable { case required, searching, ready, failed }
    enum GameScreen: Equatable { case intro, board, results }
    @Published private(set) var gameScreen: GameScreen = .board
    @Published private(set) var bestClearTime: TimeInterval?
    @Published private(set) var previousBest: TimeInterval?
    @Published private(set) var isNewBest = false
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
    private static let bestTimeKey = "wallTargets.clearTheWall.bestActiveSeconds.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let best = defaults.double(forKey: Self.bestTimeKey)
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

    var boxesHit: Set<Int> { Set(hits.compactMap(\.box)) }
    var lastHit: Hit? { hits.last }
    /// A new recording cannot replace a recording that is still being finalized.
    var canStartGame: Bool {
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
    func beginGameSetup(usingCurrentCorners: Bool = false) -> Bool {
        guard canStartGame else { return false }
        // Do not show the previous round's saved status if this setup is stopped
        // before the camera has started its new recording.
        recordingState = .idle
        referenceFailed = false
        focusFailed = false
        notice = nil
        // Manual corners selected in the settings screen are an allowed starting
        // geometry. Mapping and ball reference must still be measured afresh.
        if usingCurrentCorners && calibration == .ready { _ = setCorners(corners) }
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
                onScored: (_ cleared: Bool) -> Void) -> Bool {
        if impact.borderline { recordBorderline(); return false }
        guard record(box: impact.box, u: impact.u, v: impact.v, at: date) else { return false }
        onScored(clearedAt != nil)
        return true
    }

    @discardableResult
    func record(box: Int?, u: Double, v: Double, at date: Date = Date()) -> Bool {
        guard gameScreen == .board, isPlaying, calibration == .ready, alignmentStatus == .ready, u.isFinite, v.isFinite,
              let box, (1...6).contains(box), WallBoard.box(u: u, v: v) == box else { return false }
        guard clearedAt == nil, !sessionEnded else { return false }
        if roundStart == nil { roundStart = date }
        hits.append(Hit(box: box, u: u, v: v, at: date))
        if boxesHit.count == 6, let roundStart {
            clearedAt = date
            let seconds = date.timeIntervalSince(roundStart)
            clears.append(Clear(at: date, seconds: seconds))
            if seconds.isFinite, seconds > 0, bestClearTime.map({ seconds < $0 }) ?? true {
                isNewBest = true
                bestClearTime = seconds
                defaults.set(seconds, forKey: Self.bestTimeKey)
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
        contactPreview = nil
        roundStart = nil
        clearedAt = nil
        sessionEnded = false
        endedElapsed = nil
    }

    /// Keep the impact map and final time until the next explicit session.
    func finishSession(at date: Date = Date()) {
        if !sessionEnded { endedElapsed = elapsed(at: date) }
        pause()
        sessionEnded = true
        gameScreen = .results
    }

    /// Alignment updates preserve the round and wall-size samples. A material
    /// scale/perspective change instead invalidates those samples explicitly.
    func applyAlignment(_ update: WallBoardAlignment.Update, at date: Date = Date()) {
        alignmentStatus = update.status
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
            pause()
            wallReference = nil
            referenceFailed = true
            notice = "Board size changed · tap to repeat setup"
        }
    }

    func recordBorderline() {
        guard isPlaying, alignmentStatus == .ready, clearedAt == nil else { return }
        let token = UUID(); borderlineToken = token
        borderlineNotice = "Borderline · aim farther inside the box"
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
        pause()
        wallReference = nil
        mappingReport = nil
        calibration = .required
        alignmentStatus = .checking
    }

    func calibrationFailed() {
        pause()
        wallReference = nil
        calibration = .failed
        notice = "Can't see all four corners · tap to retry"
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
    func startPlay(at date: Date = Date()) -> Bool {
        guard gameScreen == .board, !sessionEnded, clearedAt == nil, calibration == .ready, alignmentStatus == .ready,
              mappingReport?.passed == true, !checkingMapping,
              wallReference != nil, referenceBox == nil else { return false }
        countdown = nil
        notice = nil
        isPlaying = true
        if roundStart == nil { roundStart = date }
        return true
    }

    func pause() {
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
        showReference(box: 1, progress: 0)
    }

    func showReference(box: Int, progress: Double) {
        guard calibration == .ready, !isPlaying, (1...6).contains(box) else { return }
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

    func setProjectorConnected(_ connected: Bool) { projectorConnected = connected }
}
#endif
