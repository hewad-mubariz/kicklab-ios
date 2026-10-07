import Foundation
import simd

/// Capture guidance only: a mapped surface does not prove ball/ground contact.
struct ShotGeometryReadiness {
    struct Surface {
        let id: String
        let normal: SIMD3<Float>
        let offset: Float
        let cameraHeight: Float
        let area: Float

        var suitable: Bool {
            normal.x.isFinite && normal.y.isFinite && normal.z.isFinite &&
                offset.isFinite && cameraHeight.isFinite && area.isFinite &&
                normal.y >= 0.98 && abs(simd_length(normal) - 1) < 0.001 &&
                (0.3...3).contains(cameraHeight) && area >= 1
        }
    }

    private struct History {
        let start: Double
        let normal: SIMD3<Float>
        var minOffset: Float
        var maxOffset: Float
    }

    private var histories: [String: History] = [:]
    private var lastTime: Double?

    mutating func reset() {
        histories = [:]; lastTime = nil
    }

    mutating func update(time: Double, trackingNormal: Bool, surfaces: [Surface]) -> Bool {
        guard time.isFinite, trackingNormal else { reset(); return false }
        if let previous = lastTime, time <= previous || time - previous > 0.2 {
            reset()
        }
        lastTime = time
        var next: [String: History] = [:]
        for surface in surfaces where surface.suitable {
            var history = histories[surface.id] ?? History(start: time,
                normal: surface.normal, minOffset: surface.offset, maxOffset: surface.offset)
            history.minOffset = min(history.minOffset, surface.offset)
            history.maxOffset = max(history.maxOffset, surface.offset)
            if history.maxOffset - history.minOffset > 0.04 ||
                simd_length(history.normal - surface.normal) > 0.02 {
                history = History(start: time, normal: surface.normal,
                    minOffset: surface.offset, maxOffset: surface.offset)
            }
            next[surface.id] = history
        }
        histories = next
        return next.values.contains { time - $0.start >= 0.5 }
    }
}
