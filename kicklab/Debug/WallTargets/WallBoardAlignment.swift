#if DEBUG
import CoreGraphics
import Foundation

/// Tracks four circular corner markers, independently of ball detection. A
/// missing / clipped marker never becomes a predicted corner or permission to score.
nonisolated enum WallCornerTracker {
    struct Image {
        let width, height: Int
        let luma: [UInt8]

        init(width: Int, height: Int, luma: [UInt8]) {
            self.width = width; self.height = height; self.luma = luma
        }

        init(bgra: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, near corners: [CGPoint]? = nil) {
            self.width = width; self.height = height
            var values = [UInt8](repeating: 0, count: width * height)
            var regions = [CGRect(x: 0, y: 0, width: width, height: height)]
            if let corners, WallBoard.validCalibration(corners) {
                let seed = corners.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
                let boardHeight = (distance(seed[0], seed[3]) + distance(seed[1], seed[2])) / 2
                let radius = max(2.5, boardHeight * (0.032 / 0.72) / 2)
                // Include every candidate's largest sampling ring, not just its
                // centre. Avoid converting the rest of the 720p frame every check.
                let margin = min(64, max(24, boardHeight * 0.24)) + ceil(radius * 1.25 * 2) + 3
                regions = seed.map { CGRect(x: $0.x - margin, y: $0.y - margin, width: margin * 2, height: margin * 2) }
            }
            for region in regions {
                let x0 = max(0, Int(floor(region.minX))), x1 = min(width, Int(ceil(region.maxX)))
                let y0 = max(0, Int(floor(region.minY))), y1 = min(height, Int(ceil(region.maxY)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { for x in x0..<x1 {
                    let p = bgra + y * rowBytes + x * 4
                    values[y * width + x] = UInt8((Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8)
                } }
            }
            luma = values
        }
    }

    private struct Candidate {
        let point: CGPoint
        let score: Double
    }

    /// Normalised TL, TR, BR, BL. Search is local, but wide enough to reacquire
    /// a small bump. The four displacements must agree; room highlights alone
    /// cannot replace an occluded corner.
    static func corners(in image: Image, near normalised: [CGPoint]) -> [CGPoint]? {
        guard WallBoard.validCalibration(normalised), image.width > 0, image.height > 0,
              image.luma.count == image.width * image.height else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let seed = normalised.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let boardHeight = (distance(seed[0], seed[3]) + distance(seed[1], seed[2])) / 2
        // The normal marker's diameter is 0.032 screen heights, the board 0.72.
        let radius = max(2.5, boardHeight * (0.032 / 0.72) / 2)
        let search = min(64, max(24, boardHeight * 0.24))
        let choices = seed.map { candidates(in: image, near: $0, radius: radius, search: search) }
        guard choices.allSatisfy({ !$0.isEmpty }) else { return nil }
        let coherence = max(7, boardHeight * 0.045)
        var best: (score: Double, points: [CGPoint])?
        for index in 0..<4 { for anchor in choices[index] {
            let dx = anchor.point.x - seed[index].x, dy = anchor.point.y - seed[index].y
            var points: [CGPoint] = [], total = 0.0
            for j in 0..<4 {
                let expected = CGPoint(x: seed[j].x + dx, y: seed[j].y + dy)
                let nearby = choices[j].filter { distance($0.point, expected) <= coherence }
                guard let match = nearby.max(by: {
                    $0.score - distance($0.point, expected) < $1.score - distance($1.point, expected)
                }) else { break }
                points.append(match.point)
                total += match.score - distance(match.point, expected) * 0.5
            }
            guard points.count == 4 else { continue }
            let result = points.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }
            guard WallBoard.validCalibration(result) else { continue }
            if best == nil || total > best!.score { best = (total, result) }
        } }
        return best?.points
    }

    private static func candidates(in image: Image, near p: CGPoint, radius: Double, search: Double) -> [Candidate] {
        var found: [Candidate] = []
        for scale in [0.75, 1.0, 1.25] {
            let r = radius * scale, margin = Int(ceil(r * 2.0)) + 1
            let x0 = max(margin, Int(p.x - search)), x1 = min(image.width - margin - 1, Int(p.x + search))
            let y0 = max(margin, Int(p.y - search)), y1 = min(image.height - margin - 1, Int(p.y + search))
            guard x0 <= x1, y0 <= y1 else { continue }
            let core = [(0.0, 0.0), (0.4, 0.0), (-0.4, 0.0), (0.0, 0.4), (0.0, -0.4)]
                .map { Int(($0.1 * r).rounded()) * image.width + Int(($0.0 * r).rounded()) }
            let ring = (0..<12).map { i -> Int in
                let angle = Double(i) * .pi / 6
                return Int((sin(angle) * r * 1.8).rounded()) * image.width + Int((cos(angle) * r * 1.8).rounded())
            }
            for y in stride(from: y0, through: y1, by: 2) { for x in stride(from: x0, through: x1, by: 2) {
                let i = y * image.width + x
                let centre = core.reduce(0.0) { $0 + Double(image.luma[i + $1]) } / Double(core.count)
                let samples = ring.map { Double(image.luma[i + $0]) }
                // A grid line has bright samples on opposite sides of its
                // centre. A corner dot has a dark surround, even where one
                // side touches the board stroke. Reject lines before ranking.
                let opposite = (0..<6).map { (samples[$0] + samples[$0 + 6]) / 2 }.max()!
                guard centre - opposite >= 4 else { continue }
                let surround = samples.sorted()
                let contrast = centre - surround.reduce(0, +) / Double(surround.count)
                let isolation = centre - surround[9]
                guard contrast >= 9, isolation >= 4 else { continue }
                let score = (contrast + isolation) / 2
                found.append(Candidate(point: CGPoint(x: x, y: y), score: score))
            } }
        }
        // Nonmaximum suppression keeps neighbouring samples of one dot from
        // filling the candidate list. All four corners still need real evidence.
        var selected: [Candidate] = []
        for c in found.sorted(by: { $0.score > $1.score }) {
            guard selected.allSatisfy({ distance($0.point, c.point) > max(4, radius) }) else { continue }
            selected.append(c)
            if selected.count == 12 { break }
        }
        return selected
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

/// Owns the scoring permission and geometry together. Geometry is frozen while
/// ready. A short occlusion retains evidence, but cannot release a score until
/// three checks confirm the same geometry. Drift or expiry invalidates that evidence.
nonisolated struct WallBoardAlignment {
    enum Status: String, Sendable { case checking, ready, obscured, shifted, referenceRequired }
    struct Update: Equatable, Sendable {
        var status: Status
        var corners: [CGPoint]
        var revision: Int
        var evidenceEpoch: Int = 0
    }
    static let interval = 0.15
    static let maximumAge = 0.30
    static let tolerancePixels = 3.0
    static let evidenceRetention = 0.8
    private(set) var update: Update
    private let referenceCorners: [CGPoint]?
    private var pending: [[CGPoint]] = []
    private var pendingSince: Double?
    private var lastCheck = -Double.infinity
    private var lastVisible = -Double.infinity
    private var obscuredSince: Double?

    init(corners: [CGPoint], referenceCorners: [CGPoint]? = nil) {
        update = Update(status: .checking, corners: corners, revision: 0)
        self.referenceCorners = referenceCorners
    }

    // Never let unconfirmed candidates walk the search along a grid line.
    var searchCorners: [CGPoint] { update.corners }
    func shouldCheck(at time: Double) -> Bool { time - lastCheck >= Self.interval }
    func canScore(at time: Double) -> Bool { update.status == .ready && time - lastVisible <= Self.maximumAge }
    func canRetainEvidence(at time: Double) -> Bool {
        canScore(at: time) || (update.status == .obscured && obscuredSince.map {
            time - $0 <= Self.evidenceRetention
        } == true)
    }

    private mutating func discardEvidence() {
        obscuredSince = nil
        update.evidenceEpoch += 1
    }

    mutating func observe(_ points: [CGPoint]?, at time: Double, size: CGSize) {
        let consecutive = time - lastCheck <= Self.maximumAge
        lastCheck = time
        guard update.status != .referenceRequired else { return }
        if let since = obscuredSince, time - since > Self.evidenceRetention { discardEvidence() }
        guard let points, WallBoard.validCalibration(points), size.width > 0, size.height > 0 else {
            if update.status == .ready {
                if consecutive { obscuredSince = time } else { discardEvidence() }
            }
            pending = []; pendingSince = nil
            changeStatus(.obscured)
            return
        }
        lastVisible = time
        if update.status == .ready, consecutive, Self.displacement(points, update.corners, size: size) <= Self.tolerancePixels {
            pending = []; pendingSince = nil
            return
        }
        let moved = Self.displacement(points, update.corners, size: size) > Self.tolerancePixels
        if update.status == .ready || (obscuredSince != nil && (moved || !consecutive)) {
            discardEvidence()
            changeStatus(.shifted)
        }
        if !consecutive || (pending.last.map({ Self.displacement($0, points, size: size) > Self.tolerancePixels }) ?? true) {
            pending = []; pendingSince = time
        }
        pending.append(points)
        if pending.count > 3 { pending.removeFirst() }
        guard pending.count == 3, time - (pendingSince ?? time) >= 2 * Self.interval - 0.01 else { return }
        let stable = (0..<4).map { i in
            CGPoint(x: pending.map { $0[i].x }.sorted()[1], y: pending.map { $0[i].y }.sorted()[1])
        }
        guard pending.allSatisfy({ Self.displacement($0, stable, size: size) <= Self.tolerancePixels }) else { return }
        if let referenceCorners, Self.referenceChanged(from: referenceCorners, to: stable, size: size) {
            pending = []; pendingSince = nil
            discardEvidence()
            changeStatus(.referenceRequired)
            return
        }
        // Keep the exact old transform when revalidating a brief dropout. Mixing
        // even a small geometry change into a pending trajectory is unnecessary.
        if obscuredSince == nil || Self.displacement(stable, update.corners, size: size) > Self.tolerancePixels {
            discardEvidence()
            update.corners = stable
        }
        obscuredSince = nil
        update.revision += 1
        update.status = .ready
        pending = []; pendingSince = nil
    }

    private mutating func changeStatus(_ status: Status) {
        if update.status != status { update.status = status; update.revision += 1 }
    }

    static func displacement(_ a: [CGPoint], _ b: [CGPoint], size: CGSize) -> Double {
        guard a.count == 4, b.count == 4 else { return .infinity }
        return zip(a, b).map { hypot(($0.x - $1.x) * size.width, ($0.y - $1.y) * size.height) }.max()!
    }

    /// Translation / small rotations do not change the ball's wall size. A zoom,
    /// distance or perspective change can; every side and diagonal must agree.
    static func referenceChanged(from a: [CGPoint], to b: [CGPoint], size: CGSize) -> Bool {
        guard a.count == 4, b.count == 4 else { return true }
        for (i, j) in [(0, 1), (1, 2), (2, 3), (3, 0), (0, 2), (1, 3)] {
            func length(_ p: [CGPoint]) -> Double { hypot((p[i].x - p[j].x) * size.width, (p[i].y - p[j].y) * size.height) }
            let old = length(a), new = length(b)
            guard old > 0, (0.94...1.06).contains(new / old) else { return true }
        }
        return false
    }
}
#endif
