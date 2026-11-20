#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

/// Synthetic display states in an isolated model. No camera observations or
/// player records enter this model; the audit only renders shipping game views.
@MainActor struct WallAuditScenario {
    let model: WallTargetsModel
    func configure(_ game: WallGame,state: String) {
        model.showGameIntro();model.selectGame(game);model.newRound();model.style = .metal
        model.setCorners([CGPoint(x:0.15,y:0.15),CGPoint(x:0.85,y:0.15),CGPoint(x:0.85,y:0.85),CGPoint(x:0.15,y:0.85)])
        model.finishMappingCheck(.init(status:.passed,cornersNormalised:model.corners.map{[Double($0.x),Double($0.y)]},
            frameWidth:1280,frameHeight:720,samples:[],limitCells:WallMappingCheck.limit))
        model.finishReference([0.04])
        if state == "reference" {
            model.beginReference();model.showReference(box:WallReferenceCollector.wallCentre,progress:0.65);return
        }
        if game.isArcade { prepareArcadePreview(state:game == .meteorDefence && state == "impact" ? "meteor-impact":state);return }
        let start=Date().addingTimeInterval(-18)
        model.startPlay(at:start)
        if state == "playing" { return }
        let sequence=state == "won" ? game.layout.targets.flatMap{Array(repeating:$0.id,count:$0.health)}
            : game == .brickBlast ? [12,12,11,11,13,13,5,5]:[4,5]
        for (index,id) in sequence.enumerated() {
            let rect=game.layout.target(id)!.frame
            model.record(box:id,u:rect.midX,v:rect.midY,
                at:state == "impact" ? Date():start.addingTimeInterval(Double(index+1)*0.15),
                approachSpeed:18,footprint:.preview)
        }
        if state == "won" { model.recordingState = .saved }
    }
    func prepareArcadePreview(state: String) {
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
        if state == "impact",let memory=model.memory,memory.phase == .recalling {
            let pad=model.game.layout.target(memory.sequence[memory.cursor])!.frame
            model.accept(.init(t:host,x:600,y:300,d:44,turn:90,u:pad.midX,v:pad.midY,box:nil,footprint:.preview),hostTime:host) { _ in }
            model.freezeArcadePreview(at:host+0.25)
            return
        }
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

}
#endif
