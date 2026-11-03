import Foundation

/// Builds an immutable rendering resource once, outside the caller's actor. Preview reads never
/// wait for the build; exports can wait on their worker. The lock only protects the small state,
/// never shader compilation, disk I/O, GPU work or completion callbacks.
nonisolated final class EffectResourcePreparation<Value: Sendable>: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Value, Error>) -> Void
    private let condition = NSCondition()
    private let build: @Sendable () throws -> Value
    private var started = false
    private var result: Result<Value, Error>?
    private var completions: [Completion] = []

    init(build: @escaping @Sendable () throws -> Value) { self.build = build }

    var resultIfReady: Result<Value, Error>? {
        condition.lock(); defer { condition.unlock() }
        return result
    }

    func prepare(completion: Completion? = nil) {
        condition.lock()
        if let result {
            condition.unlock()
            completion?(result)
            return
        }
        if let completion { completions.append(completion) }
        let shouldStart = !started
        started = true
        condition.unlock()
        guard shouldStart else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let made = autoreleasepool { Result { try build() } }
            condition.lock()
            result = made
            let waiting = completions
            completions.removeAll()
            condition.broadcast()
            condition.unlock()
            for completion in waiting { completion(made) }
        }
    }

    /// Only for synchronous off-screen renders such as export and picker icons. Live preview
    /// must use resultIfReady and arrange a redraw in prepare's completion instead.
    func waitUntilReady() throws -> Value {
        prepare()
        condition.lock()
        while result == nil { condition.wait() }
        let ready = result!
        condition.unlock()
        return try ready.get()
    }
}
