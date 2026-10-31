import Foundation

@main struct ObservedFallContracts {
    static func main() throws {
        let views = try JSONDecoder().decode([BallObservation].self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain:message,code:checks) }
            checks += 1
        }
        func measure(_ v: [BallObservation], time: Int = 28100) -> Double? {
            ObservedFallAmplitude.measure(v,contactFrame:840,through:time)
        }
        try check(abs(measure(views)! - 0.0191884994506836) < 0.0000001, "Observed descent")
        try check(measure(Array(views.reversed())) == measure(views), "Input ordering")
        try check(measure(views,time:28033) == nil, "No future release borrowing")
        for missing in [838,839,840,841,842] {
            try check(measure(views.filter { $0.frameIndex != missing }) == nil, "Missing exposure \(missing)")
        }
        try check(measure(views + [views.first { $0.frameIndex == 840 }!]) == nil, "Duplicate")
        for kind in 0..<7 {
            let altered = views.map { original -> BallObservation in
                var b = original
                if b.frameIndex == 840 {
                    switch kind {
                    case 0: b.confidence=0.69
                    case 1: b.y = .nan
                    case 2: b.x=0
                    case 3: b.width *= 2
                    case 4: b.height=0
                    case 5: b.timestampMs += 30
                    default: b.y=0.99
                    }
                }
                return b
            }
            try check(measure(altered) == nil, "Invalid measurement \(kind)")
        }
        try check(measure(views.map { var b=$0;b.y=0.5;return b }) == nil, "Stationary ball")
        try check(measure(views.map { var b=$0;b.y=0.4+Double(b.frameIndex-836)*0.01;return b }) == nil, "No rebound")
        let shifted = views.map { var b=$0;b.timestampMs+=10000;return b }
        try check(measure(shifted,time:38100) == measure(views), "No clip timestamp dependency")
        let offset = views.map { var b=$0;b.y+=0.5;return b }
        let bottoms = Dictionary(uniqueKeysWithValues:offset.map { ($0.frameIndex,1.5) })
        let adjusted = ObservedFallAmplitude.measure(offset,contactFrame:840,through:28100,imageBottoms:bottoms)
        try check(abs(adjusted!-measure(views)!) < 0.0000001, "Camera coordinate offset")
        try check(CounterConfig().usesObservedFallAmplitude != true, "Default unchanged")
        print("PASS: \(checks) observed-fall contracts")
    }
}
