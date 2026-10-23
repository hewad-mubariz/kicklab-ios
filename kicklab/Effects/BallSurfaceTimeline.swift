import AVFoundation
import Foundation
import simd

/// Small immutable pose timeline. Replays, seeking, and exports sample the same
/// source-derived orientation. Uncertain increments hold; there is no timer spin.
nonisolated struct BallSurfaceTimeline: Sendable {
    struct Entry: Sendable {
        let time: Double
        let orientation: simd_quatf
        let accepted: Bool
        var visible: Bool = true
        /// Colour of the real ball's white panels in this frame (0-255), if measurable.
        var white: SIMD3<Float>? = nil
    }
    static let initial = simd_quatf(angle:0.35,axis:SIMD3(0,1,0))*simd_quatf(angle:0.18,axis:SIMD3(1,0,0))
    let entries: [Entry]
    let elapsed: Double
    let acceptedCount: Int
    /// Robust source-edge estimate; nil leaves the existing box-based estimate.
    let photographicExposure: Double?
    private let trusted: [Bool]
    /// `entries` orientations with short rejected runs bridged; see `bridged`.
    private let rendered: [simd_quatf]
    /// Longest rejected run, between measured increments, that is bridged.
    static let maximumBridge = 0.3
    init(entries: [Entry], elapsed: Double, photographicExposure: Double? = nil) {
        self.entries=entries;self.elapsed=elapsed
        self.photographicExposure = photographicExposure
        rendered = Self.bridged(entries)
        acceptedCount=entries.reduce(0) {$0+($1.accepted ? 1:0)}
        var confidence = [Bool](repeating: false, count: entries.count)
        var low = 0, high = 0, visible = 0, accepted = 0
        for i in entries.indices {
            while high < entries.count, entries[high].time <= entries[i].time + 0.2 {
                if entries[high].visible { visible += 1; if entries[high].accepted { accepted += 1 } }
                high += 1
            }
            while low < high, entries[low].time < entries[i].time - 0.2 {
                if entries[low].visible { visible -= 1; if entries[low].accepted { accepted -= 1 } }
                low += 1
            }
            confidence[i] = entries[i].visible && visible >= 6 && Double(accepted) / Double(max(1,visible)) >= 0.7
        }
        trusted = confidence
    }

    enum Status: String, Sendable {
        case measured, littleMotion, uncertain, notVisible
        var label: String {
            switch self {
            case .measured: return "Source spin"
            case .littleMotion: return "Little visible spin"
            case .uncertain: return "Spin uncertain"
            case .notVisible: return "Ball not tracked"
            }
        }
    }

    /// Confidence belongs to a visible interval, not the length of the movie.
    var usesSourceRotation: Bool { trusted.contains(true) }

    func status(at time: Double) -> Status {
        guard time.isFinite, !entries.isEmpty else { return .uncertain }
        let i = index(at: time)
        guard abs(entries[i].time-time) < 0.06, entries[i].visible else { return .notVisible }
        guard trusted[i], entries[i].accepted else { return .uncertain }
        guard i > 0, entries[i-1].visible else { return .measured }
        let dt = entries[i].time - entries[i-1].time
        guard dt > 0, dt < 0.06 else { return .uncertain }
        let angle = abs((entries[i-1].orientation.inverse * entries[i].orientation).angle)
        return Double(angle)/dt < 0.08 ? .littleMotion : .measured
    }

    private func index(at time: Double) -> Int {
        var low = 0, high = entries.count
        while low < high { let middle = (low+high)/2; if entries[middle].time < time { low=middle+1 } else { high=middle } }
        if low == entries.count { return entries.count-1 }
        if low > 0, abs(entries[low-1].time-time) < abs(entries[low].time-time) { return low-1 }
        return low
    }

    /// Scene light as the real ball's white panels show it: per-channel median of
    /// frames within ±0.5 s, so the replacement's tint cannot flicker with panel
    /// rotation. Nil when fewer than five frames measured a white.
    func light(at time: Double) -> SIMD3<Float>? {
        guard time.isFinite, !entries.isEmpty else { return nil }
        var low = 0, high = entries.count
        while low < high { let m = (low+high)/2; if entries[m].time < time-0.5 { low = m+1 } else { high = m } }
        var values = [SIMD3<Float>]()
        var i = low
        while i < entries.count, entries[i].time <= time+0.5 { if let w = entries[i].white { values.append(w) }; i += 1 }
        guard values.count >= 5 else { return nil }
        func median(_ c: Int) -> Float { let v = values.map { $0[c] }.sorted(); return v[v.count/2] }
        return SIMD3(median(0), median(1), median(2))
    }

    /// Bright, low-saturation pixels inside 0.8 of the ball radius: the white panels.
    static func white(pixels: CVPixelBuffer, center: CGPoint, radius: Double) -> SIMD3<Float>? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA, radius >= 4 else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), stride = CVPixelBufferGetBytesPerRow(pixels)
        var samples = [(Float, SIMD3<Float>)](); samples.reserveCapacity(576)
        for j in 0..<24 { for i in 0..<24 {
            let dx = (Double(i)+0.5)/24*2-1, dy = (Double(j)+0.5)/24*2-1
            guard dx*dx+dy*dy < 0.64 else { continue }
            let x = Int(center.x+dx*radius), y = Int(center.y+dy*radius)
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            let p = base+y*stride+x*4
            let rgb = SIMD3<Float>(Float(p[2]), Float(p[1]), Float(p[0]))
            let mx = rgb.max(), mn = rgb.min()
            guard mx > 0, (mx-mn)/mx < 0.35 else { continue }
            samples.append((0.2126*rgb.x+0.7152*rgb.y+0.0722*rgb.z, rgb))
        } }
        guard samples.count >= 40 else { return nil }
        samples.sort { $0.0 > $1.0 }
        let top = samples.prefix(max(4, samples.count/10))
        return top.reduce(SIMD3<Float>.zero) { $0+$1.1 }/Float(top.count)
    }

    func renderOrientation(at time: Double) -> simd_quatf? {
        // Short rejected runs carry the spin measured on both sides; longer or
        // one-sided gaps hold the last observed pose. Never replace uncertainty
        // with decorative timer rotation, or report it as zero spin.
        pose(at: time) { rendered[$0] }
    }

    /// Measured poses only: rejected increments hold.
    func orientation(at time: Double) -> simd_quatf {
        pose(at: time) { entries[$0].orientation }
    }

    private func pose(at time: Double, _ value: (Int) -> simd_quatf) -> simd_quatf {
        guard time.isFinite,let first=entries.first,time>=first.time else {return Self.initial}
        var low=0,high=entries.count
        while low<high {
            let middle=(low+high)/2
            if entries[middle].time<time {low=middle+1} else {high=middle}
        }
        guard low>0 else {return value(0)}
        guard low<entries.count else {return value(entries.count-1)}
        let a=entries[low-1],b=entries[low],gap=b.time-a.time
        guard gap>0,gap<0.1 else {return value(low-1)}
        return simd_slerp(value(low-1),value(low),Float(max(0,min(1,(time-a.time)/gap))))
    }

    /// Spin is nearly constant between touches, but blur right after a kick rejects
    /// several increments in a row. Holding there froze the replacement and lost that
    /// rotation for the rest of the clip. A run of at most `maximumBridge` between
    /// measured increments advances at the measured rates on either side, blended
    /// across the run. Later poses keep their measured increments: right-multiplying
    /// by a constant leaves every `pose(i) * pose(i-1).inverse` unchanged.
    private static func bridged(_ entries: [Entry]) -> [simd_quatf] {
        // Radians per second, as a rotation vector, for each measured increment.
        let rates: [SIMD3<Float>?] = entries.indices.map { i in
            guard i > 0, entries[i].accepted else { return nil }
            let dt = Float(entries[i].time-entries[i-1].time)
            guard dt > 0 else { return nil }
            let d = entries[i].orientation*entries[i-1].orientation.inverse
            let angle = d.angle > .pi ? d.angle-2 * .pi : d.angle
            return abs(angle) > 1e-7 ? d.axis*angle/dt : .zero
        }
        func mean(_ values: [SIMD3<Float>]) -> SIMD3<Float> { values.reduce(.zero, +)/Float(values.count) }
        var result = entries.map(\.orientation)
        var correction: simd_quatf?
        var i = 1
        while i < entries.count {
            guard rates[i] == nil else {
                if let c = correction { result[i] = simd_normalize(entries[i].orientation*c) }
                i += 1; continue
            }
            var end = i
            while end < entries.count && rates[end] == nil { end += 1 }
            let anchor = i-1
            if rates[anchor] != nil, end < entries.count, entries[end].time-entries[anchor].time <= maximumBridge {
                let before = mean((max(1, anchor-2)...anchor).compactMap { rates[$0] })
                let after = mean((end...min(entries.count-1, end+2)).compactMap { rates[$0] })
                let span = entries[end].time-entries[anchor].time
                for k in i..<end {
                    let w = before+(after-before)*Float((entries[k].time-entries[anchor].time)/span)
                    let step = w*Float(entries[k].time-entries[k-1].time), angle = simd_length(step)
                    let q = angle > 1e-7 ? simd_quatf(angle: angle, axis: step/angle) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    result[k] = simd_normalize(q*result[k-1])
                }
                // The rejected run held the anchor's measured pose.
                correction = entries[end-1].orientation.inverse*result[end-1]
            } else if let c = correction {
                for k in i..<end { result[k] = simd_normalize(entries[k].orientation*c) }
            }
            i = end
        }
        return result
    }

    static func prepare(source: URL, track: BallEffectTrack) async throws -> Self {
        try await BallSurfaceMotionCache.shared.prepare(source:source,track:track)
    }

    #if DEBUG
    /// Independent rotation measurement for paired pipeline reviews.
    static func analyzeForReview(source: URL, track: BallEffectTrack) async throws -> Self {
        try await analyze(source:source,track:track)
    }
    #endif

    fileprivate static func analyze(source: URL, track: BallEffectTrack) async throws -> Self {
        let scoped=source.startAccessingSecurityScopedResource()
        defer {if scoped {source.stopAccessingSecurityScopedResource()}}
        let start=ProcessInfo.processInfo.systemUptime
        let asset=AVURLAsset(url:source)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else {
            throw NSError(domain:"KickLab.SurfaceMotion",code:1,userInfo:[NSLocalizedDescriptionKey:"No video track."])
        }
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        // Analyze the source cadence. Do not throw away the 120 fps frames that
        // disambiguate fast backspin; output video can still be 30/60 fps.
        let duration = try await asset.load(.duration)
        let composition = try await EffectVideoGeometry.composition(track:video,duration:duration,shortEdge:720)
        output.videoComposition=composition
        output.alwaysCopiesSampleData=false;reader.add(output)
        guard reader.startReading() else {throw reader.error!}
        defer {if reader.status == .reading {reader.cancelReading()}}
        var entries=[Entry](),pose=initial,previous:BallSurfaceMotion.Gray?,previousTime:Double?
        var exposure = BallExposureCalibration(duration: duration.seconds, frameDuration: composition.frameDuration.seconds)
        while true {
            try await VideoWorkExecution.checkpoint(requiresGPU: false)
            guard let buffer = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            let time=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            autoreleasepool {
                guard time.isFinite,let pixels=CMSampleBufferGetImageBuffer(buffer),
                      let sample=track.replacementGuide(at:time),sample.confidence>=0.3,
                      let fitted=BallReplacementFootprint.fit(pixels:pixels,sample:sample),
                      let current=BallSurfaceMotion.patch(pixels:pixels,center:fitted.center,
                          radius:fitted.radii.reduce(0,+)/Double(fitted.radii.count)) else {
                    previous=nil;previousTime=nil
                    entries.append(Entry(time:time,orientation:pose,accepted:false,visible:false));return
                }
                var accepted=false
                if exposure.shouldMeasure(at: time) {
                    let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                    if let velocity = track.velocity(at: time, size: size),
                       let blur = BallReplacementMotionBlur.measured(pixels: pixels, body: fitted,
                            suggested: track.smear(at: time, size: size)) {
                        exposure.observe(time: time, smear: blur, velocity: velocity)
                    }
                }
                if let previous,let previousTime,time>previousTime,time-previousTime<0.06 {
                    let result=BallSurfaceMotion.estimate(previous:previous,current:current)
                    if result.accepted {
                        accepted=true
                        let vector=SIMD3<Float>(result.rotation),angle=simd_length(vector)
                        if angle>1e-7 {pose=simd_normalize(simd_quatf(angle:angle,axis:vector/angle)*pose)}
                    }
                }
                entries.append(Entry(time:time,orientation:pose,accepted:accepted,
                    white:Self.white(pixels:pixels,center:fitted.center,radius:fitted.radii.reduce(0,+)/Double(fitted.radii.count))))
                previous=current;previousTime=time
            }
        }
        guard reader.status == .completed else {throw reader.error ?? NSError(domain:"KickLab.SurfaceMotion",code:2)}
        return Self(entries:entries,elapsed:ProcessInfo.processInfo.systemUptime-start,photographicExposure:exposure.estimate)
    }
}

/// Two compact cached timelines, at most one analysis in flight. Concurrent HDR
/// preview and original-file export must never cancel one another's requests.
private actor BallSurfaceMotionCache {
    static let shared=BallSurfaceMotionCache()
    private var completed: [(String,BallSurfaceTimeline)] = []
    private var pending: [String:Task<BallSurfaceTimeline,Error>] = [:]
    private var tail: Task<BallSurfaceTimeline,Error>?

    func prepare(source: URL,track: BallEffectTrack) async throws -> BallSurfaceTimeline {
        let content = try SessionAnalysisStore.sourceDigest(source)
        let samples = track.samples.map { [$0.time, Double($0.center.x), Double($0.center.y),
            Double($0.boxSize?.width ?? 0), Double($0.boxSize?.height ?? 0), $0.confidence] }
        let signature = try JSONEncoder().encode(samples)
        let requested = SessionAnalysisStore.digest(Data("spin-v4-photo-exposure|\(SessionAnalysisStore.pipelineSignature())|\(content)|".utf8) + signature)
        let folder = URL.cachesDirectory.appendingPathComponent("SessionSpin-v3", isDirectory: true)
        let file = folder.appendingPathComponent(requested + ".json")
        if let value=completed.first(where:{$0.0==requested})?.1 {return value}
        if let task=pending[requested] {return try await task.value}
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16*1024*1024,
           let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(StoredSurfaceTimeline.self, from: data), saved.isValid {
            let value = saved.timeline
            completed.append((requested,value)); if completed.count > 2 { completed.removeFirst() }
            return value
        }
        let previous=tail
        let task=VideoWorkExecution.detached {
            if let previous {_ = await previous.result}
            try Task.checkCancellation()
            return try await BallSurfaceTimeline.analyze(source:source,track:track)
        }
        pending[requested]=task;tail=task
        do {
            let value=try await task.value
            pending[requested]=nil
            completed.append((requested,value))
            if let data = try? JSONEncoder().encode(StoredSurfaceTimeline(value)), data.count < 16*1024*1024 {
                try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try? data.write(to:file,options:.atomic)
                let files = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
                let sorted = files.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for old in sorted.dropFirst(4) where old != file { try? FileManager.default.removeItem(at:old) }
            }
            if completed.count>2 {completed.removeFirst(completed.count-2)}
            if pending.isEmpty {tail=nil}
            return value
        } catch {
            pending[requested]=nil
            if pending.isEmpty {tail=nil}
            throw error
        }
    }
}

nonisolated private struct StoredSurfaceTimeline: Codable {
    struct Row: Codable {
        let time: Double
        let q: [Float]
        let accepted: Bool
        let visible: Bool
        var white: [Float]? = nil
    }
    let rows: [Row]
    let elapsed: Double
    var photographicExposure: Double?
    init(_ value: BallSurfaceTimeline) {
        rows = value.entries.map { Row(time:$0.time,q:[$0.orientation.vector.x,$0.orientation.vector.y,
            $0.orientation.vector.z,$0.orientation.vector.w],accepted:$0.accepted,visible:$0.visible,
            white:$0.white.map { [$0.x,$0.y,$0.z] }) }
        elapsed = value.elapsed
        photographicExposure = value.photographicExposure
    }
    var isValid: Bool {
        elapsed.isFinite && (photographicExposure.map { $0.isFinite && $0 > 0 } ?? true)
            && rows.allSatisfy { $0.time.isFinite && $0.q.count == 4 && $0.q.allSatisfy(\.isFinite) }
            && zip(rows,rows.dropFirst()).allSatisfy { $0.time < $1.time }
    }
    var timeline: BallSurfaceTimeline {
        BallSurfaceTimeline(entries:rows.map { .init(time:$0.time,
            orientation:simd_quatf(vector:SIMD4($0.q[0],$0.q[1],$0.q[2],$0.q[3])),
            accepted:$0.accepted,visible:$0.visible,
            white:$0.white.flatMap { $0.count == 3 && $0.allSatisfy(\.isFinite) ? SIMD3($0[0],$0[1],$0[2]) : nil }) },
            elapsed:elapsed,photographicExposure:photographicExposure)
    }
}
