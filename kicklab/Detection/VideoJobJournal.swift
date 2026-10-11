import Foundation

/// Explains interrupted jobs after process termination; does not claim that iOS
/// can resume a renderer after force quit. No media URLs or account data stored.
@MainActor
struct VideoJobJournal {
    let defaults: UserDefaults
    private let key = "juggledude.video.inflight"
    func begin(_ identifier: String, title: String) {
        var jobs = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        jobs[identifier] = title; defaults.set(jobs, forKey: key)
    }
    func finish(_ identifier: String) {
        var jobs = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        jobs[identifier] = nil; defaults.set(jobs, forKey: key)
    }
    func consumeInterruptedCount() -> Int {
        let count = defaults.dictionary(forKey: key)?.count ?? 0
        defaults.removeObject(forKey: key)
        return count
    }
}
