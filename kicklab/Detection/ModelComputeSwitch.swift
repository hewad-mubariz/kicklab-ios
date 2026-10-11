import Foundation

/// Owned by one serial inference worker. Switching the execution backend never
/// replaces the detector, tracker, counter, input tensor or pending frame.
nonisolated final class ModelComputeSwitch<Model> {
    private var model: Model
    private let load: (Bool) throws -> Model
    private(set) var cpuOnly: Bool
    private(set) var switches = 0
    private(set) var reloadSeconds = 0.0

    init(cpuOnly: Bool, load: @escaping (Bool) throws -> Model) throws {
        self.load = load
        self.model = try load(cpuOnly)
        self.cpuOnly = cpuOnly
    }

    var current: Model { model }

    private func select(cpuOnly requested: Bool) throws -> Model {
        if requested != cpuOnly {
            let start = ProcessInfo.processInfo.systemUptime
            let replacement = try load(requested)
            model = replacement
            cpuOnly = requested
            switches += 1
            reloadSeconds += ProcessInfo.processInfo.systemUptime - start
        }
        return model
    }

    func perform<T>(cpuOnly policy: () -> Bool, _ operation: (Model) throws -> T) throws -> T {
        try Task.checkCancellation()
        let initialCPU = policy()
        do { return try operation(select(cpuOnly: initialCPU)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // An app can leave foreground between checking its state and
            // submitting GPU work. Retry the same immutable input once on CPU,
            // before any detection/counter state consumes a prediction.
            guard !initialCPU, policy() else { throw error }
            try Task.checkCancellation()
            return try operation(select(cpuOnly: true))
        }
    }

    func performAsync<T>(cpuOnly policy: () -> Bool,
                         _ operation: (Model) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let initialCPU = policy()
        do { return try await operation(select(cpuOnly: initialCPU)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard !initialCPU, policy() else { throw error }
            try Task.checkCancellation()
            return try await operation(select(cpuOnly: true))
        }
    }
}
