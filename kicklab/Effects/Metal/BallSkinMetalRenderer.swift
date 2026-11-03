import CoreGraphics
import Foundation
import Metal
import simd
import UIKit

/// Optional acceleration for artwork skins. A refused/failed GPU draw returns nil so the
/// caller renders the same pose on CPU. Lab skins retain their separate GPU requirement.
nonisolated final class BallSkinMetalRenderer: @unchecked Sendable {
    static let shared: BallSkinMetalRenderer? = try? BallSkinMetalRenderer()
    private static let activity = Activity()
    #if DEBUG
    @TaskLocal static var forceCPUForReview = false
    @TaskLocal static var failDrawForReview = false
    private static let cpuReviewRun = ProcessInfo.processInfo.environment["BALL_SKIN_CPU_REVIEW"] == "1"
    #endif

    /// Install on the main thread before previews or export workers can start. Off-main
    /// renderers read the locked snapshot, never synchronously dispatch to the UI thread.
    @MainActor static func observeApplication() { activity.observe() }

    static var isAllowed: Bool {
        #if DEBUG
        if forceCPUForReview || cpuReviewRun { return false }
        #endif
        if VideoWorkExecution.accuracyComparison { return false }
        if let lease = VideoWorkExecution.lease {
            guard !lease.isCancelled else { return false }
            return (activity.isActive && lease.isForeground) || (lease.canContinue && lease.backgroundGPU)
        }
        return activity.isActive
    }

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        @MainActor private var observers: [NSObjectProtocol] = []
        var isActive: Bool { lock.withLock { active } }
        private func set(_ value: Bool) { lock.withLock { active = value } }
        @MainActor func observe() {
            guard observers.isEmpty else { return }
            set(UIApplication.shared.applicationState == .active)
            observers = [
                NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(false) },
                NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(true) }
            ]
        }
    }

    private struct Uniforms { var pose: SIMD4<Float>; var options: SIMD4<UInt32> }
    private let lock = NSLock()
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState
    // Two 3.5 MiB maps plus one 256 KiB output. CPU artwork retention remains independently bounded.
    private var maps: [BallSkin: (MTLBuffer, MTLBuffer)] = [:]
    private var order: [BallSkin] = []
    private var output: MTLBuffer?
    #if DEBUG
    private var completedDraws = 0
    #endif

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let kernel = device.makeDefaultLibrary()?.makeFunction(name: "ballArtworkSphere") else {
            throw NSError(domain: "BallSkinMetal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ball shader unavailable"])
        }
        self.device = device; self.queue = queue
        pipeline = try device.makeComputePipelineState(function: kernel)
    }

    /// The order is part of BallSkinSphere.metal's contract; picker order is independent.
    private static func shaderID(_ skin: BallSkin) -> UInt32? {
        switch skin {
        case .classic: 0; case .stealth: 1; case .matrix: 2; case .gold: 3
        case .arctic: 4; case .crimson: 5; case .galaxy: 6; case .chrome: 7
        case .graffiti: 8; case .aurora: 9; case .metal: 10; case .lava: 11
        case .pearl: 12; case .volt: 13
        default: nil
        }
    }

    func image(skin: BallSkin, size: Int, pose: simd_quatf, rgba: [UInt8], normals: [UInt8],
               permitsGPU: () -> Bool = { BallSkinMetalRenderer.isAllowed }) -> CGImage? {
        guard permitsGPU(), let id = Self.shaderID(skin), [144, 256].contains(size),
              rgba.count == 1024*512*4, normals.count == 1024*512*3,
              pose.vector.x.isFinite, pose.vector.y.isFinite, pose.vector.z.isFinite, pose.vector.w.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        if maps[skin] == nil {
            guard let colour = rgba.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
                  let normal = normals.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
            if order.count == 2 { maps.removeValue(forKey: order.removeFirst()) }
            maps[skin] = (colour, normal)
        }
        order.removeAll { $0 == skin }; order.append(skin)
        if output == nil { output = device.makeBuffer(length: 256*256*4, options: .storageModeShared) }
        guard let output, let map = maps[skin], let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var uniforms = Uniforms(pose: pose.vector, options: SIMD4(UInt32(size), id, 0, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(map.0, offset: 0, index: 0); encoder.setBuffer(map.1, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        let width = pipeline.threadExecutionWidth
        let height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        // The app may have backgrounded while this worker waited for another render.
        guard permitsGPU() else { return nil }
        #if DEBUG
        if Self.failDrawForReview { return nil }
        #endif
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil,
              let provider = CGDataProvider(data: Data(bytes: output.contents(), count: size*size*4) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size*4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        #if DEBUG
        if image != nil { completedDraws += 1 }
        #endif
        return image
    }

    #if DEBUG
    var completedDrawsForReview: Int { lock.withLock { completedDraws } }
    var retainedBytesForReview: Int {
        lock.withLock { maps.values.reduce(0) { $0 + $1.0.length + $1.1.length } + (output?.length ?? 0) }
    }
    #endif
}
