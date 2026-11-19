import Foundation

/// The foot that met the ball.
nonisolated enum TouchFoot: String, Codable, Sendable {
    case left = "L", right = "R"

    /// One letter per touch (L, R or U), or nil when no touch has a foot, so old sessions stay unchanged.
    static func letters(_ touches: [RecordedTouch]) -> String? {
        touches.contains { $0.foot != nil } ? String(touches.map { $0.foot?.rawValue.first ?? "U" }) : nil
    }

    /// Gives saved letters back to touches in the same order; a length mismatch leaves them unknown.
    static func apply(_ letters: String?, to touches: [RecordedTouch]) -> [RecordedTouch] {
        guard let letters, letters.count == touches.count else { return touches }
        return zip(touches, letters).map { touch, letter in
            var touch = touch
            touch.foot = TouchFoot(rawValue: String(letter))
            return touch
        }
    }
}

/// Which foot met the ball, read from the body poses the counter already computed for its contact checks.
/// It never asks for a pose itself, so counting does no extra work and its decisions are unchanged.
///
/// The rule is the analytics lab's (scripts/graphs/feet/classify.py, 33/33 on the owner's clip): from 0.067 s
/// before the contact to the contact, the raised foot is the higher ankle, and it is the person's left foot
/// when it sits on the person's left of the standing ankle. Which image side is the person's left comes from
/// the hips over the whole session, because Vision's own left/right names swap when the legs cross.
nonisolated final class TouchFootRecorder: @unchecked Sendable {
    private struct Ankles { let left, right: PoseLandmark; let aspect: Double }
    private let lock = NSLock()
    private var ankles: [Int: Ankles] = [:]
    private var hipsLeftOnImageRight = 0, hipPairs = 0

    /// One selected-player pose, at its frame's time in the counter's clock. `aspect` is width / height.
    func record(timestampMs: Int, pose: BodyPose, aspect: Double) {
        lock.lock(); defer { lock.unlock() }
        if let l = pose.ankles[.left], let r = pose.ankles[.right], min(l.confidence, r.confidence) >= 0.3, aspect > 0 {
            ankles[timestampMs] = Ankles(left: l, right: r, aspect: aspect)
        }
        if let l = pose.hips[.left], let r = pose.hips[.right], min(l.confidence, r.confidence) >= 0.1 {
            hipPairs += 1
            if l.x > r.x { hipsLeftOnImageRight += 1 }
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        ankles = [:]; hipsLeftOnImageRight = 0; hipPairs = 0
    }

    /// Recorded poses so far (ankle pairs, hip pairs).
    var counts: (ankles: Int, hips: Int) {
        lock.lock(); defer { lock.unlock() }
        return (ankles.count, hipPairs)
    }

    /// The foot of each contact, at its time in the counter's clock; nil where the counter saw no usable pose.
    func feet(atContactMs contacts: [Int]) -> [TouchFoot?] {
        lock.lock(); defer { lock.unlock() }
        guard hipPairs > 0 else { return contacts.map { _ in nil } }
        let facing: Double = hipsLeftOnImageRight * 2 > hipPairs ? 1 : -1
        let times = ankles.keys.sorted()
        func foot(_ contact: Int, from: Int, to: Int) -> TouchFoot?? {
            var num = 0.0, den = 0.0, seen = false
            var low = 0, high = times.count
            while low < high { let mid = (low + high) / 2; if times[mid] < contact + from { low = mid + 1 } else { high = mid } }
            for time in times[low...] {
                guard time <= contact + to else { break }
                let a = ankles[time]!
                seen = true
                let (up, down) = a.left.y < a.right.y ? (a.left, a.right) : (a.right, a.left)
                // 8 px at 1080 px wide, as a fraction of the height.
                let lift = down.y - up.y
                guard lift >= 8 / 1080 * a.aspect else { continue }
                num += (up.x > down.x ? 1 : -1) * facing * lift
                den += lift
            }
            guard seen else { return .none }
            let agree = den > 0 ? num / den : 0
            return .some(abs(agree) >= 0.5 ? (agree > 0 ? .left : .right) : nil)
        }
        return contacts.map { contact in
            // The lab's window first; if the counter has no pose in it, the nearest frames around the contact.
            if let found = foot(contact, from: -68, to: 1) { return found }
            return foot(contact, from: -120, to: 34) ?? nil
        }
    }
}
