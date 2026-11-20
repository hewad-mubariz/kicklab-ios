#if WALL_GAMES_PREVIEW
import Foundation

/// Consumer read model over the original recording folder. Training video,
/// detections, timing and power logs remain untouched alongside the result.
struct WallArcadeRecord: Identifiable {
    let folder: URL
    let created: Date
    let game: WallGame?
    let title: String
    let headline: String
    let value: String
    let detail: String
    let activeSeconds: Double
    let hits: Int
    let completed: Bool
    let finalized: Bool
    let playStart: Double
    var id: URL { folder }
    var video: URL? {
        let file=folder.appendingPathComponent("video.mov")
        return finalized && FileManager.default.fileExists(atPath:file.path) ? file:nil
    }
    var clock: String { Self.time(activeSeconds) }
    static func time(_ seconds: Double) -> String {
        let value=Int(max(0,min(seconds.isFinite ? seconds:0, 86400)))
        return String(format:"%d:%02d",value/60,value%60)
    }
    init?(folder: URL) {
        guard let data=try? Data(contentsOf:folder.appendingPathComponent("session.json")),
              let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
        self.folder=folder
        created=(json["created"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) } ?? .distantPast
        let challenge=(json["challengeEnd"] ?? json["challenge"]) as? [String:Any] ?? [:]
        let topBins=(json["game"] as? String == "top-bins") || (json["mode"] as? String == "top-bins") || challenge["mode"] as? String == "top-bins"
        let parsed=(json["game"] as? String).flatMap(WallGame.init(rawValue:))
        guard topBins || parsed != nil else { return nil }
        game=parsed
        title=topBins ? "Top Bins":parsed!.title
        finalized=json["status"] as? String == "completed"
        let seconds=json["activePlaySeconds"] as? Double ?? 0
        activeSeconds=seconds.isFinite ? max(0,seconds):0
        let shotCount=(challenge["shots"] as? [[String:Any]])?.count ?? 0
        hits=topBins ? shotCount:(json["scoredHits"] as? [[String:Any]])?.count ?? 0
        let reason=json["stopReason"] as? String ?? ""
        completed=["round_complete","round_lost"].contains(reason) || (json["partyFinished"] as? Bool == true) || (topBins && shotCount == 5)
        playStart=(json["phases"] as? [[String:Any]])?.first(where: { $0["phase"] as? String == "playing" })?["t"] as? Double ?? 0
        if topBins {
            headline=completed ? "ROUND COMPLETE":"ROUND STOPPED"
            value="\(challenge["score"] as? Int ?? 0)"
            detail="POINTS · \(shotCount) OF 5 SHOTS"
        } else if let game=parsed,game.isParty {
            let winner=json["winner"] as? Int
            headline=completed ? winner.map { "PLAYER \($0) WINS" } ?? "IT'S A DRAW":"MATCH STOPPED"
            if let scores=(json["playerGoals"] ?? json["playerScores"]) as? [Int], scores.count==2,
               [.goalDuel,.territoryDuel,.copyMyShot].contains(game) {
                value="\(scores[0]) – \(scores[1])";detail="PLAYER 1 · PLAYER 2"
            } else {
                value=completed ? winner.map { game == .crossCircle ? ($0==1 ? "X":"O") : "P\($0)" } ?? "DRAW":"—"
                detail="\(hits) CONFIRMED SHOTS"
            }
        } else if let game=parsed,game.isArcade {
            headline=completed ? (json["arcadeWon"] as? Bool == true ? "CHALLENGE COMPLETE":"GAME OVER"):"ROUND STOPPED"
            value="\(json["arcadeScore"] as? Int ?? 0)";detail="POINTS"
        } else if parsed == .brickBlast {
            let broken=(json["destroyedTargets"] as? [Int])?.count ?? 0
            let total=json["targetCount"] as? Int ?? 30
            headline=completed ? (json["newPersonalBest"] as? Bool == true ? "NEW PERSONAL BEST":"WALL CLEARED"):"ROUND STOPPED"
            value="\(json["brickScore"] as? Int ?? broken*100)"
            detail="POINTS · \(broken)/\(total) BRICKS"
        } else {
            headline=completed ? (json["newPersonalBest"] as? Bool == true ? "NEW PERSONAL BEST":"WALL CLEARED"):"ROUND STOPPED"
            value=String(format:"%.1f",activeSeconds);detail="SECONDS OF PLAY"
        }
    }
    static func all() -> [Self] {
        let urls=(try? FileManager.default.contentsOfDirectory(at:WallTargetsRecorder.root,includingPropertiesForKeys:nil)) ?? []
        return urls.compactMap { Self(folder:$0) }.sorted { $0.created > $1.created }
    }
}
#endif
