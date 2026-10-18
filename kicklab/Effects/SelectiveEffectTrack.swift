import AVFoundation
import Foundation

/// Position-only sidecar for trails/glows. Never supplies replacement masks or
/// changes the live counter. A missing observation is never filled by prediction.
nonisolated enum SelectiveEffectTrack {
    static let signature = "selective-positions-v5-gap120-step90-score55-drift20-turn40-retry2"
    /// Retry at most two adjacent source frames after an empty query in a
    /// bounded gap. Never turn an absent ball into an unbounded search.
    struct QueryCursor {
        let times: [Double]
        private var index = 0, retries = 0
        private var retryDeadline = -Double.infinity
        init(_ times: [Double]) { self.times = times }
        mutating func take(at time: Double, allowRetry: Bool) -> Bool {
            let tolerance = 1.0 / 120 + 0.0001
            while index < times.count && times[index] < time-tolerance { index += 1 }
            if index < times.count && abs(times[index]-time) <= tolerance {
                index += 1; retries = allowRetry ? 2 : 0; retryDeadline = time+0.04
                return true
            }
            if retries > 0 && time <= retryDeadline {
                retries -= 1; return true
            }
            return false
        }
        mutating func accepted() { retries = 0 }
    }
    struct Span: Sendable { var start: Double; var end: Double }
    struct Plan: Sendable {
        let spans: [Span]
        let duration: Double
        let queries: [Double]
        let rejectedTimes: Set<Double>
        var seconds: Double { spans.reduce(0) { $0 + $1.end - $1.start } }
        func contains(_ time: Double) -> Bool {
            var lo = 0, hi = spans.count
            while lo < hi { let mid = (lo + hi) / 2; if spans[mid].end < time { lo = mid + 1 } else { hi = mid } }
            return lo < spans.count && spans[lo].start <= time
        }
    }
    static func valid(_ f: RecordedFrame) -> Bool {
        f.detected && [f.time,f.x,f.y,f.width,f.height,f.score].allSatisfy(\.isFinite)
            && f.time >= 0 && f.width > 0 && f.height > 0 && f.score >= 0.05
    }
    static func eligible(_ frames: [RecordedFrame]) -> Bool {
        !frames.isEmpty && frames.allSatisfy { f in
            guard valid(f), let id = f.identity, id.isValid,
                  id.coordinates == "capture-buffer; normalized upright detector coordinates" else { return false }
            return abs(id.seconds - f.time) <= 0.002
        }
    }
    static func canReuse(source: URL, frames: [RecordedFrame]) async throws -> Bool {
        guard eligible(frames), let identity = frames.first?.identity else { return false }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let size = EffectVideoGeometry.displaySize(naturalSize: try await video.load(.naturalSize),
            transform: try await video.load(.preferredTransform))
        let duration = try await asset.load(.duration).seconds
        return frames.allSatisfy { f in
            f.time <= duration && f.identity?.width == identity.width && f.identity?.height == identity.height
        } && abs(size.width / size.height - Double(identity.width) / Double(identity.height)) < 0.001
    }
    static func plan(frames: [RecordedFrame], duration: Double) -> Plan {
        guard duration.isFinite, duration > 0 else { return Plan(spans: [], duration: 0, queries: [], rejectedTimes: []) }
        let ordered = frames.filter(valid).sorted { $0.time < $1.time }
        var rejected = Set(ordered.filter { $0.score < 0.55 }.map(\.time))
        // RFBufferedPixelTrack inherits the last RF confidence verbatim. That
        // score cannot certify a tracked position. If the intermediate run
        // disagrees with its bounding observations, ask RF for fresh pixels.
        // The straight line is only a suspicion test, never an output position;
        // legitimate curved motion is therefore measured again, not flattened.
        var start = 0
        while start+1 < ordered.count {
            var end = start+1
            while end < ordered.count && ordered[end].score == ordered[start].score { end += 1 }
            if end < ordered.count && end > start+1 {
                let a = ordered[start], b = ordered[end], dt = b.time-a.time
                if dt > 0 && dt <= 0.30 {
                    let w = max(a.width,b.width), h = max(a.height,b.height)
                    let suspect = ordered[(start+1)..<end].contains { f in
                        let u = (f.time-a.time)/dt
                        return hypot((f.x-a.x-(b.x-a.x)*u)/w,(f.y-a.y-(b.y-a.y)*u)/h) > 0.20
                    }
                    if suspect { rejected.formUnion(ordered[(start+1)..<end].map(\.time)) }
                }
            }
            start = end
        }
        if ordered.count > 2 {
            for i in 1..<(ordered.count - 1) {
                let a = ordered[i-1], f = ordered[i], b = ordered[i+1], dt = b.time-a.time
                guard dt > 0, dt <= 0.15 else { continue }
                let w = max(a.width,b.width), h = max(a.height,b.height)
                guard hypot((b.x-a.x)/w,(b.y-a.y)/h) < 1 else { continue }
                let u = (f.time-a.time)/dt
                let offset = hypot((f.x-(a.x+(b.x-a.x)*u))/w,(f.y-(a.y+(b.y-a.y)*u))/h)
                let scale = max(f.width/w,w/f.width,f.height/h,h/f.height)
                if offset > 0.75 || scale > 1.8 { rejected.insert(f.time) }
            }
        }
        let trusted = ordered.filter { !rejected.contains($0.time) }
        var queries = Array(rejected), regions: [Span] = []
        func add(_ a:Double,_ b:Double) {
            let start = max(0,a),end = min(duration,b)
            if end > start { regions.append(Span(start:start,end:end)) }
        }
        // Even a gap shorter than the rendering limit can hide a kick. Use
        // incoming/outgoing motion to flag likely curvature, then measure that
        // interval more densely. No extrapolated centre enters the sidecar.
        if ordered.count > 3 {
            for i in 1..<(ordered.count-2) {
                let p=ordered[i-1], a=ordered[i], b=ordered[i+1], n=ordered[i+2]
                let gap=b.time-a.time, before=a.time-p.time, after=n.time-b.time
                guard gap > 0.06, gap <= 0.30, before > 0, before <= 0.20,
                      after > 0, after <= 0.20 else { continue }
                let dx=((n.x-b.x)/after-(a.x-p.x)/before)/max(a.width,b.width)
                let dy=((n.y-b.y)/after-(a.y-p.y)/before)/max(a.height,b.height)
                guard hypot(dx,dy)*gap/8 > 0.12 else { continue }
                add(a.time,b.time)
                let segments=Int(ceil(gap/0.04))
                queries += (1..<segments).map { a.time+gap*Double($0)/Double(segments) }
            }
        }
        for t in rejected { add(t-0.05,t+0.05) }
        if let first = trusted.first, let last = trusted.last {
            if first.time > 0.05 {
                add(0,first.time)
                queries += stride(from:0.0,to:first.time-0.015,by:0.09)
            }
            if duration-last.time > 0.05 {
                add(last.time,duration)
                queries += stride(from:last.time+0.09,to:duration,by:0.09)
            }
            for (a,b) in zip(trusted,trusted.dropFirst()) where b.time-a.time > BallEffectTrack.maximumGap {
                add(a.time,b.time)
                let segments = Int(ceil((b.time-a.time)/0.09))
                queries += (1..<segments).map { a.time+(b.time-a.time)*Double($0)/Double(segments) }
            }
        } else {
            add(0,duration);queries += stride(from:0.0,to:duration,by:0.09)
        }
        var merged: [Span] = []
        for span in regions.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count-1].end = max(last.end,span.end)
            } else { merged.append(span) }
        }
        var unique: [Double] = []
        for time in queries.sorted() where time >= 0 && time < duration {
            if unique.last.map({time-$0 >= 1.0/60}) ?? true { unique.append(time) }
        }
        return Plan(spans:merged,duration:duration,queries:unique,rejectedTimes:rejected)
    }
    static func positionOnly(_ f: RecordedFrame) -> RecordedFrame {
        var result = f
        result.ballMask = nil; result.usesBallMasks = false
        result.isVisualMaskRepair = false; result.isVisualRecovery = false
        return result
    }
    static func refine(source: URL, frames: [RecordedFrame],
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> [RecordedFrame] {
        let digest = try SessionAnalysisStore.sourceDigest(source)
        let seed = try SessionAnalysisStore.digest(SessionAnalysisStore.frameData(frames))
        let key = SessionAnalysisStore.digest(Data("\(signature)|\(digest)|\(seed)|\(SessionAnalysisStore.visualPipelineSignature())".utf8))
        if ProcessInfo.processInfo.arguments.contains("--analysis-ignore-cache") {
            return try await compute(source: source, frames: frames, onProgress: onProgress)
        }
        return try await SessionAnalysisStore.shared.prepare(key: key, onProgress: onProgress) { progress in
            try await compute(source: source, frames: frames, onProgress: progress)
        }
    }
    private static func compute(source: URL, frames: [RecordedFrame],
                                onProgress: @escaping @Sendable (Double) -> Void) async throws -> [RecordedFrame] {
        try await VideoAnalysisScheduler.shared.perform {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let asset = AVURLAsset(url: source), duration = try await asset.load(.duration)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw failure(1) }
            let composition = try await EffectVideoGeometry.composition(track: video, duration: duration,
                shortEdge: 720, frameDuration: CMTime(value: 1, timescale: 60))
            let work = plan(frames: frames, duration: duration.seconds)
            let retained = frames.filter { !work.rejectedTimes.contains($0.time) }.map(positionOnly)
            guard !work.queries.isEmpty else { onProgress(1); return retained }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition; output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? failure(2) }
            defer { reader.cancelReading() }
            let detector = try BallDetector()
            var association = BallPlausibility(policy: detector.plausibilityPolicy)
            var repaired: [RecordedFrame] = [], index = 0, failures = 0, calls = 0
            var anchorIndex = 0, queries = QueryCursor(work.queries)
            let anchors = retained.sorted { $0.time < $1.time }
            let start = ProcessInfo.processInfo.systemUptime
            var pacer = VideoAnalysisPacer()
            while true {
                let frameStart = try await pacer.beginFrame { _ in }
                guard let sample = output.copyNextSampleBuffer() else { break }
                let time = sample.presentationTimeStamp.seconds
                defer { index += 1; if index % 15 == 0 { onProgress(min(0.99,time/work.duration)) } }
                // Replay trusted anchors into the same elapsed-time association
                // gate; no interpolated position is treated as an observation.
                while anchorIndex < anchors.count && anchors[anchorIndex].time <= time {
                    let f = anchors[anchorIndex]; anchorIndex += 1
                    _ = association.accept(Detection(score:f.score,x:f.x,y:f.y,width:f.width,height:f.height),
                        frame:index,timestampMs:Int(f.time*1000))
                }
                let bounded = anchorIndex > 0 && anchorIndex < anchors.count
                    && anchors[anchorIndex].time-anchors[anchorIndex-1].time <= 1.0
                let requested = queries.take(at:time,allowRetry:bounded)
                guard requested, let pixels = CMSampleBufferGetImageBuffer(sample) else {
                    try await pacer.finishFrame(started: frameStart); continue
                }
                let found: Detection?
                do { found = try autoreleasepool { try detector.effectPosition(in:pixels) }; failures = 0; calls += 1 }
                catch { failures += 1; if failures >= 3 { throw error }; try await pacer.finishFrame(started: frameStart); continue }
                try await pacer.finishFrame(started: frameStart)
                guard let found, let ball = association.accept(found,frame:index,timestampMs:Int(time*1000)) else { continue }
                queries.accepted()
                repaired.append(RecordedFrame(time:time,x:ball.x,y:ball.y,width:ball.width,height:ball.height,
                    score:ball.score,smoothedX:ball.x,smoothedY:ball.y,vy:0,motion:.unknown,detected:true,person:nil,
                    identity:RecordedFrameIdentity(index:index,time:sample.presentationTimeStamp,
                        width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),coordinates:"composition-720-sdr-v1")))
            }
            if reader.status == .failed { throw reader.error ?? failure(3) }
            try Task.checkCancellation(); onProgress(1)
            NSLog("Selective effects: %.2fs source, %.2fs repair spans, %d RF calls, %d retained, %d fresh, %.2fs elapsed",
                duration.seconds,work.seconds,calls,retained.count,repaired.count,ProcessInfo.processInfo.systemUptime-start)
            let originalTimes = retained.map(\.time).sorted()
            let additions = repaired.filter { f in
                var lo=0,hi=originalTimes.count
                while lo<hi {let mid=(lo+hi)/2;if originalTimes[mid]<f.time {lo=mid+1}else{hi=mid}}
                return ![lo-1,lo].contains { originalTimes.indices.contains($0) && abs(originalTimes[$0]-f.time)<0.003 }
            }
            return (retained+additions).sorted { $0.time < $1.time }
        }
    }
    private static func failure(_ code: Int) -> NSError { NSError(domain:"SelectiveEffects",code:code) }
}
