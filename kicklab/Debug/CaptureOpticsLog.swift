#if DEBUG
import Foundation

/// Periodic camera readings for every debug recording, including ordinary
/// recordings made without Final tests. Never retains a frame or changes camera
/// settings. File work runs off the capture queue.
nonisolated final class CaptureOpticsLog: @unchecked Sendable {
    struct Entry: Codable {
        let source: String
        let final: Bool
        let capture: CaptureCadenceSnapshot
    }

    let url: URL
    private let source: String
    private let queue = DispatchQueue(label: "kicklab.capture.optics-log", qos: .utility)
    // Owned exclusively by queue.
    private var handle: FileHandle?
    private var closed = false

    init(source: URL, directory: URL? = nil) {
        self.source = source.lastPathComponent
        let directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureDiagnostics", isDirectory: true)
        url = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jsonl")
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: url)
                handle = try FileHandle(forWritingTo: url)
            } catch {
                closed = true
            }
        }
    }

    func append(_ capture: CaptureCadenceSnapshot) {
        queue.async { [self] in write(capture, final: false) }
    }

    func finish(_ capture: CaptureCadenceSnapshot, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            write(capture, final: true)
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            closed = true
            completion?()
        }
    }

    private func write(_ capture: CaptureCadenceSnapshot, final: Bool) {
        guard !closed, let handle else { return }
        do {
            var data = try JSONEncoder().encode(Entry(source: source, final: final, capture: capture))
            data.append(10)
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            self.handle = nil
            closed = true
        }
    }

    deinit { try? handle?.close() }
}
#endif
