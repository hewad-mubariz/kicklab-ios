import Foundation

/// A selected person's lower box edge is only a floor proxy. A foreground
/// occluder can remove the legs while leaving the head in the same place.
/// Retain the last complete extent briefly; never refresh it from a stale box.
nonisolated struct PlayerGroundEstimate {
    static let signature = "|player-ground-v1"
    private var reference: (id: Int, box: PersonBox, time: Int)?
    private var lastTime: Int?
    private let lifetimeMs = 1_200

    mutating func reset() { reference = nil; lastTime = nil }

    mutating func update(player: ActivePlayerSelection, timestampMs: Int) -> Double? {
        if let lastTime, timestampMs <= lastTime || timestampMs-lastTime > lifetimeMs { reset() }
        lastTime = timestampMs
        if reference?.id != player.id { reference = nil }
        guard let id = player.id, player.state == .locked, player.observed,
              let box = player.box, [box.x,box.y,box.width,box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return current(at: timestampMs) }
        if let value = reference {
            let old = value.box
            let sameTop = abs((box.y-box.height/2)-(old.y-old.height/2)) <= 0.15*old.height
            let lostLegs = box.height < 0.8*old.height && old.bottom-box.bottom > 0.15*old.height
            if sameTop && lostLegs { return current(at: timestampMs) }
        }
        reference = (id,box,timestampMs)
        return box.bottom
    }
    private func current(at timestampMs: Int) -> Double? {
        guard let value = reference, timestampMs-value.time <= lifetimeMs else { return nil }
        return value.box.bottom
    }
}
