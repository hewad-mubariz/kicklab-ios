#if DEBUG
import Foundation
import Metal

/// Explicit diagnostic launch only. Streams small samples to disk so the probe
/// does not retain a growing history while measuring preparation itself.
nonisolated enum PreparationMemoryProbe {
    private static let recorder: Recorder? = {
        guard ProcessInfo.processInfo.arguments.contains("--effects-memory-probe") else { return nil }
        return try? Recorder()
    }()

    static func stage(_ name: String) { recorder?.stage(name) }
    static func finish() { recorder?.finish() }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let file: FileHandle
        private let device = MTLCreateSystemDefaultDevice()
        private let start = ProcessInfo.processInfo.systemUptime
        private var phase = "starting"
        private var closed = false
        private var sampler: Task<Void, Never>?

        init() throws {
            let name = SessionDesignReview.argument("--effects-folder") ?? "preparation-memory"
            let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("memory.jsonl")
            try Data().write(to: url, options: .atomic)
            file = try FileHandle(forWritingTo: url)
            sampler = Task.detached { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }

        func stage(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            phase = name
            writeSample()
        }

        private func sample() {
            lock.lock(); defer { lock.unlock() }
            writeSample()
        }

        private func writeSample() {
            guard !closed else { return }
            let row: [String: Any] = [
                "phase": phase, "elapsed_s": ProcessInfo.processInfo.systemUptime - start,
                "app_mib": DetectorPerformance.memoryMB(),
                "metal_mib": Double(device?.currentAllocatedSize ?? 0) / 1_048_576,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue
            ]
            if var data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) {
                data.append(10)
                try? file.write(contentsOf: data)
            }
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            phase = "finished"; writeSample()
            closed = true
            sampler?.cancel(); sampler = nil
            try? file.close()
        }
    }
}
#endif
