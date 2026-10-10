import CoreML
import Vision

/// Configure each Vision stage explicitly for jobs that must run without a GPU.
/// A request belongs to its analysis worker; this does not make it shareable.
nonisolated enum VisionComputePolicy {
    enum ConfigurationError: Error { case cpuUnavailable }

    static func configure(_ request: VNRequest, cpuOnly: Bool = VideoWorkExecution.cpuOnly) throws {
        guard cpuOnly else { return }
        let stages = try request.supportedComputeStageDevices
        guard !stages.isEmpty else { throw ConfigurationError.cpuUnavailable }
        for (stage, devices) in stages {
            guard let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) else { throw ConfigurationError.cpuUnavailable }
            request.setComputeDevice(cpu, for: stage)
        }
    }
}
