import CoreImage
import CoreVideo
import Foundation
import Vision

/// Analysis-queue owned storage and lazy Vision inference. This component knows
/// pixels, landmarks and confidence; it does not decide whether a touch counts.
nonisolated final class ContactObservationStore {
    struct Frame {
        let index: Int
        let timestampMs: Int
        let pixels: CVPixelBuffer
        let ball: Detection
        var player: ActivePlayerSelection? = nil
        var isContactRecheck = false
    }
    private let context = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly])
    private var pixelPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private(set) var frames: [Frame] = []
    private var legacyFrameIndices: Set<Int> = []
    /// Keep existing hand/ground evidence identical when the motion cache grows.
    var immediateFrames: [Frame] { frames.filter { legacyFrameIndices.contains($0.index) } }
    private var pendingFrame: Int?
    private var timestamps: [Int: Int] = [:]
    private var originalMissingBallFrames: Set<Int> = []
    var originalMissingBallTimestampsMs: [Int] {
        originalMissingBallFrames.compactMap { timestamps[$0] }
    }
    func timestamp(at index: Int) -> Int? { timestamps[index] }
    typealias Pose = BodyPose
    private var poseCache: [Int: Pose] = [:]
    private var otherPoseCache: [Int: [Pose]] = [:]
    private var selections: [Int: ActivePlayerSelection] = [:]
    func selection(at index: Int) -> ActivePlayerSelection? {
        selections[index] ?? frames.first(where: { $0.index == index })?.player
    }
    func otherPoses(for frame: Frame) -> [Pose] { otherPoseCache[frame.index] ?? [] }
    private(set) var handPoseRequests = 0
    private(set) var poseRequests = 0
    private(set) var poseCacheHits = 0
    private(set) var warmUpMS = 0.0
    private(set) var peakBufferedFrames = 0
    private(set) var lastError: String?
    private var warmed = false
    private let request = VNDetectHumanBodyPoseRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()

    init() {
        do {
            try VisionComputePolicy.configure(request)
            try VisionComputePolicy.configure(handRequest)
        }
        catch { lastError = error.localizedDescription }
    }

    func discardFrames() {
        frames.removeAll(keepingCapacity: true)
        legacyFrameIndices.removeAll(keepingCapacity: true)
        poseCache.removeAll(keepingCapacity: true)
        otherPoseCache.removeAll(keepingCapacity: true)
        selections.removeAll(keepingCapacity: true)
        pendingFrame = nil
        timestamps.removeAll(keepingCapacity: true)
        originalMissingBallFrames.removeAll(keepingCapacity: true)
    }

    /// A slow reversal can be confirmed after the rolling image cache expires.
    /// Pin dense contact neighbors plus a bounded window sampled in time.
    /// High-FPS input must not erase the approach before motion is confirmed.
    func retainContactFrames(around index: Int?) { pendingFrame = index }

    func reset() {
        discardFrames()
        if let pixelPool { CVPixelBufferPoolFlush(pixelPool, .excessBuffers) }
        context.clearCaches()
        poseRequests = 0
        poseCacheHits = 0
        handPoseRequests = 0
        peakBufferedFrames = 0
        lastError = nil
    }

    /// Called on the owning analysis queue during preparation, before capture
    /// opens its writer. Keep Vision's cold model load out of a live contact.
    /// No camera image or every-frame pose inference is needed for warmup.
    func warmUp() {
        guard !warmed, lastError == nil else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { warmUpMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 288, 512, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
              let pixels else { return }
        context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 288, height: 512)), to: pixels)
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels).perform([request, handRequest])
            warmed = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func store(_ pixels: CVPixelBuffer, frameIndex: Int, timestampMs: Int,
               ball: Detection?, orientLandscapeAsPortrait: Bool = true, player: ActivePlayerSelection? = nil) {
        guard lastError == nil else { return }
        timestamps[frameIndex] = timestampMs
        selections[frameIndex] = player
        selections = selections.filter { $0.key >= frameIndex-64 || $0.key == pendingFrame }
        timestamps = timestamps.filter { $0.key >= frameIndex-64 || $0.key == pendingFrame }
        if ball == nil { originalMissingBallFrames.insert(frameIndex) }
        originalMissingBallFrames = Set(originalMissingBallFrames.filter { timestamps[$0] != nil })
        legacyFrameIndices = Set(frames.filter { frame in
            guard legacyFrameIndices.contains(frame.index) else { return false }
            let pinned = pendingFrame.map { ($0-9 ... $0+3).contains(frame.index) } ?? false
            return pinned || (frameIndex-frame.index <= 15 && timestampMs-frame.timestampMs <= 500)
        }.map(\.index))
        defer {
            let retained = ContactFrameWindow.retainedIndices(
                frames.map { .init(index: $0.index, timestampMs: $0.timestampMs) },
                latest: .init(index: frameIndex, timestampMs: timestampMs), pendingIndex: pendingFrame,
                pendingTimestampMs: pendingFrame.flatMap { timestamps[$0] })
            frames.removeAll { !retained.contains($0.index) }
            poseCache = poseCache.filter { retained.contains($0.key) }
            otherPoseCache = otherPoseCache.filter { retained.contains($0.key) }
            peakBufferedFrames = max(peakBufferedFrames, frames.count)
        }
        guard let ball else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        if orientLandscapeAsPortrait && image.extent.width > image.extent.height { image = image.oriented(.right) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let buffer = frameBuffer(width: Int(image.extent.width), height: Int(image.extent.height)) else { return }
        context.render(image, to: buffer)
        frames.append(Frame(index: frameIndex, timestampMs: timestampMs, pixels: buffer, ball: ball, player: player))
        legacyFrameIndices.insert(frameIndex)
    }

    /// Recycle only images that no longer belong to the contact window. Core
    /// Video retains the backing surface while a Frame or Vision request owns
    /// it, so a new observation cannot overwrite pending contact evidence.
    private func frameBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pixelPool == nil || poolSize != size {
            var pool: CVPixelBufferPool?
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary,
                                          &pool) == kCVReturnSuccess else { return nil }
            pixelPool = pool
            poolSize = size
        }
        guard let pixelPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelPool, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    func hands(for frame: Frame, recordErrors: Bool = true) -> [[HandLandmark]]? {
        do {
            handPoseRequests += 1
            try VNImageRequestHandler(cvPixelBuffer: frame.pixels).perform([handRequest])
            return try (handRequest.results ?? []).map { observation in
                let recognized = try observation.recognizedPoints(.all)
                let groups: [[VNHumanHandPoseObservation.JointName]] = [
                    [.wrist], [.thumbIP, .thumbTip], [.indexDIP, .indexTip],
                    [.middleDIP, .middleTip], [.ringDIP, .ringTip], [.littleDIP, .littleTip]]
                return groups.enumerated().flatMap { group, names in
                    names.compactMap { name -> HandLandmark? in
                        guard let point = recognized[name] else { return nil }
                        return .init(finger: group, x: point.location.x, y: 1-point.location.y,
                                     confidence: Double(point.confidence))
                    }
                }
            }
        } catch {
            if recordErrors { lastError = error.localizedDescription }
            return nil
        }
    }

    func pose(for frame: Frame, recordErrors: Bool = true) -> Pose? {
        if let cached = poseCache[frame.index] { poseCacheHits += 1; return cached }
        return autoreleasepool {
            do {
                poseRequests += 1
                try VNImageRequestHandler(cvPixelBuffer: frame.pixels).perform([request])
                let rawPoses = request.results ?? []
                let names: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
                    (.nose, .nose), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
                    (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
                    (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
                    (.leftHip, .leftHip), (.rightHip, .rightHip),
                    (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
                    (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)]
                let poses: [Pose] = try rawPoses.prefix(8).map { observation in
                    let recognized = try observation.recognizedPoints(.all)
                    var result = Pose()
                    for (name,joint) in names {
                        guard let point = recognized[joint] else { continue }
                        if point.confidence >= 0.3 { result.joints[name] = .init(x: point.location.x, y: 1-point.location.y) }
                        let landmark = PoseLandmark(x: point.location.x, y: 1-point.location.y,
                                                    confidence: Double(point.confidence))
                        result.landmarks[name] = landmark
                        switch name {
                        case .leftWrist: result.wrists[.left] = landmark
                        case .rightWrist: result.wrists[.right] = landmark
                        case .leftHip: result.hips[.left] = landmark
                        case .rightHip: result.hips[.right] = landmark
                        case .leftAnkle: result.ankles[.left] = landmark
                        case .rightAnkle: result.ankles[.right] = landmark
                        default: break
                        }
                    }
                    return result
                }
                let selected = ActivePlayerPoseMatcher.index(in: poses, selection: frame.player)
                let result = selected.map { poses[$0] } ?? Pose()
                otherPoseCache[frame.index] = poses.enumerated().filter { $0.offset != selected }.map(\.element)
                poseCache[frame.index] = result
                return result
            } catch {
                if recordErrors {
                    lastError = error.localizedDescription
                    discardFrames()
                }
                return nil
            }
        }
    }
}

// Full-app diagnostic: insert measured pixels without trimming later evidence.
//  Do not call chronological store() with an
// older frame: that would trim later evidence and change its retention semantics.
extension ContactObservationStore {
    nonisolated func insertRecheckedContact(_ pixels: CVPixelBuffer, frameIndex: Int,
                                timestampMs: Int, ball: Detection) -> Bool {
        guard lastError == nil, timestamps[frameIndex] == timestampMs,
              !frames.contains(where: { $0.index == frameIndex }),
              frames.count < ContactFrameWindow.maximumBufferedFrames else { return false }
        var image = CIImage(cvPixelBuffer: pixels)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let buffer = frameBuffer(width: Int(image.extent.width), height: Int(image.extent.height)) else { return false }
        context.render(image, to: buffer)
        frames.append(Frame(index: frameIndex, timestampMs: timestampMs, pixels: buffer, ball: ball,
                            player: selection(at: frameIndex), isContactRecheck: true))
        frames.sort { $0.index < $1.index }
        legacyFrameIndices.insert(frameIndex)
        peakBufferedFrames = max(peakBufferedFrames, frames.count)
        return true
    }
}
