import Foundation

/// Numeric proof for on-device heel/toe contact recovery.
/// Same fixed predicate as low-contact-study/shoe_probe.py, evaluated again from
/// the saved five observations rather than trusting a supplied acceptance flag.
nonisolated struct ShoeContactProof: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable { let x,y,visibility,presence:Double }
    struct Ball: Codable, Equatable, Sendable { let x,y,width,height,confidence:Double }
    struct Sample: Codable, Equatable, Sendable {
        let ms:Int; let pose:[Point]; let ball:Ball
        func point(_ side:BodySide,_ part:Int)->Point {pose[(side == .left ? [23,27,29,31] : [24,28,30,32])[part]]}
        var visible:Bool {
            pose.count == 33 && ball.confidence >= 0.7 && (0...1).contains(ball.x) && (0...1).contains(ball.y)
            && ball.width > 0 && ball.height > 0 && BodySide.allCases.allSatisfy { side in
                (0...3).allSatisfy { part in
                    let p=point(side,part)
                    return min(p.visibility,p.presence) >= 0.65 && (0...1).contains(p.x) && (0...1).contains(p.y)
                }
            }
        }
        func distance(_ side:BodySide)->Double {
            [(1,3),(2,3),(1,2)].map { i,j in
                let a=point(side,i),c=point(side,j)
                let ax=(a.x-ball.x)/ball.width,ay=(a.y-ball.y)/ball.height
                let cx=(c.x-ball.x)/ball.width,cy=(c.y-ball.y)/ball.height
                let dx=cx-ax,dy=cy-ay,t=max(0,min(1,-(ax*dx+ay*dy)/max(dx*dx+dy*dy,1e-12)))
                return hypot(ax+t*dx,ay+t*dy)
            }.min()!
        }
    }
    let candidateMs:Int,side:BodySide,samples:[Sample]
    var impactMs:Int {samples[2].ms}
    var availableMs:Int {samples.map(\.ms).max() ?? Int.max}
    var valid:Bool {
        guard samples.count == 5,samples.allSatisfy(\.visible),
              samples.allSatisfy({abs($0.ms-candidateMs)<=235}) else {return false}
        let a=samples[0],n=samples[1],b=samples[2],c=samples[3],d=samples[4],w=b.ball.width,h=b.ball.height
        guard abs(b.ms-candidateMs)<=50,(65...134).contains(b.ms-a.ms),(20...40).contains(b.ms-n.ms),
              [c,d].allSatisfy({(65...167).contains($0.ms-b.ms)}),(25...70).contains(d.ms-c.ms),
              samples.map({$0.ball.width}).max()! <= 1.35*samples.map({$0.ball.width}).min()!,
              samples.map({$0.ball.height}).max()! <= 1.35*samples.map({$0.ball.height}).min()!,
              b.ball.y-a.ball.y >= 0.35*h,[c,d].allSatisfy({b.ball.y-$0.ball.y>=0.2*h}),
              b.distance(side)<=0.65,
              b.ball.y <= (1...3).map({b.point(side,$0).y}).max()!+0.1*h else{return false}
        let support=samples.map{$0.point(side.opposite,1)}
        guard support.map(\.x).max()!-support.map(\.x).min()! <= 0.25*w,
              support.map(\.y).max()!-support.map(\.y).min()! <= 0.25*h else{return false}
        func lift(_ s:Sample)->Double {(a.point(side,3).y-s.point(side,3).y)/h}
        func relativeLift(_ s:Sample,_ anchor:BodySide,_ part:Int)->Double {
            ((a.point(side,3).y-a.point(anchor,part).y)-(s.point(side,3).y-s.point(anchor,part).y))/h
        }
        return lift(n)>=0.08 && lift(b)>=0.12 && relativeLift(b,side,0)>=0.08 && relativeLift(b,side.opposite,1)>=0.08
            && a.distance(side)-b.distance(side)>=0.25
            && [c,d].allSatisfy({$0.distance(side)-b.distance(side)>=0.2})
            && [c,d].allSatisfy({(b.ball.y-b.point(side,3).y)-($0.ball.y-$0.point(side,3).y)>=0.2*h})
    }
}


nonisolated enum ShoeContactRules {
    /// Same ordering and five-observation search as the frozen Python probe.
    /// Only already-arrived observations can enter a proof.
    static func proof(_ input: [ShoeContactProof.Sample], at ms: Int, through now: Int,
                      player: ActivePlayerSelection?) -> ShoeContactProof? {
        guard let player, player.canMatchPose, player.observed, player.peopleCount == 1,
              let box = player.box else { return nil }
        let samples = input.filter { abs($0.ms-ms) <= 235 && $0.ms <= now && $0.visible }
            .sorted { $0.ms < $1.ms }
        guard samples.count <= 24, Set(samples.map(\.ms)).count == samples.count else { return nil }
        for b in samples where abs(b.ms-ms) <= 50 {
            for a in samples where (65...134).contains(b.ms-a.ms) {
                for n in samples where (20...40).contains(b.ms-n.ms) {
                    for c in samples where (65...167).contains(c.ms-b.ms) {
                        for d in samples where (65...167).contains(d.ms-b.ms) && (25...70).contains(d.ms-c.ms) {
                            for side in BodySide.allCases {
                                let proof = ShoeContactProof(candidateMs: ms, side: side, samples: [a,n,b,c,d])
                                let hip = b.point(side, 0)
                                if proof.valid, abs(hip.x-box.x) <= box.width/2, abs(hip.y-box.y) <= box.height/2 {
                                    return proof
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
}
