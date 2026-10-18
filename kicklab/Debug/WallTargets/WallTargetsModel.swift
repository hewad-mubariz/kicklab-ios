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

/// Board state shared by the phone screen and the projector window. Live ball
/// positions stay on the camera object so the projector does not redraw per frame.
@MainActor
final class WallTargetsModel: ObservableObject {
    static let shared = WallTargetsModel()

    enum Calibration: Equatable { case required, searching, ready, failed }
    @Published private(set) var calibration: Calibration = .required
    @Published private(set) var isPlaying = false
    @Published private(set) var wallReference: WallBallReference?
    @Published private(set) var referenceBox: Int?
    @Published private(set) var referenceProgress = 0.0
    @Published private(set) var referenceFailed = false
    @Published var isFocusing = false
    @Published private(set) var focusFailed = false
    @Published var countdown: Int?
    @Published var notice: String?
    @Published private(set) var alignmentStatus = WallBoardAlignment.Status.checking
    @Published private(set) var borderlineNotice: String?
    private var borderlineToken = UUID()
    private var alignmentPausedAt: Date?

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

    /// "Clear the board": every box hit at least once. The phone sits on a
    /// tripod, so the next hit a few seconds after a clear starts a new round.
    static let newRoundDelay: TimeInterval = 3

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
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    var clearTime: TimeInterval? {
        guard let roundStart, let clearedAt else { return nil }
        return clearedAt.timeIntervalSince(roundStart)
    }

    func elapsed(at date: Date) -> TimeInterval {
        clearTime ?? roundStart.map { max(0, (alignmentPausedAt ?? date).timeIntervalSince($0)) } ?? 0
    }

    func record(box: Int?, u: Double, v: Double, at date: Date = Date()) {
        guard isPlaying, calibration == .ready, alignmentStatus == .ready, u.isFinite, v.isFinite,
              let box, (1...6).contains(box), WallBoard.box(u: u, v: v) == box else { return }
        if let clearedAt, date.timeIntervalSince(clearedAt) >= Self.newRoundDelay { newRound() }
        guard clearedAt == nil else { return }   // brief pause after a clear
        if roundStart == nil { roundStart = date }
        hits.append(Hit(box: box, u: u, v: v, at: date))
        if boxesHit.count == 6, let roundStart {
            clearedAt = date
            clears.append(Clear(at: date, seconds: date.timeIntervalSince(roundStart)))
        }
    }

    func newRound() {
        hits = []
        roundStart = nil
        clearedAt = nil
    }

    /// Alignment updates preserve the round and wall-size samples. A material
    /// scale/perspective change instead invalidates those samples explicitly.
    func applyAlignment(_ update: WallBoardAlignment.Update, at date: Date = Date()) {
        alignmentStatus = update.status
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

    @discardableResult
    func setCorners(_ points: [CGPoint]) -> Bool {
        pause()
        wallReference = nil
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
        calibration = .searching
        focusFailed = false
        notice = nil
        newRound()
    }

    func invalidateCalibration() {
        pause()
        wallReference = nil
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

    @discardableResult
    func startPlay(at date: Date = Date()) -> Bool {
        guard calibration == .ready, alignmentStatus == .ready, wallReference != nil, referenceBox == nil else { return false }
        countdown = nil
        notice = nil
        isPlaying = true
        if roundStart == nil { roundStart = date }
        return true
    }

    func pause() {
        isPlaying = false
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
