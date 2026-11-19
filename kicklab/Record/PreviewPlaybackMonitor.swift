import AVFoundation
import Combine
import UIKit

@MainActor final class PreviewPlaybackMonitor: ObservableObject {
    private var task: Task<Void, Never>?
    private weak var player: AVPlayer?
    private var readiness = PreviewReadiness()
    private var hasFrame = false
    private var hasSeek = false
    private var inactivityObserver: NSObjectProtocol?

    func start(_ player: AVPlayer, onFailure: @escaping @MainActor (String) -> Void) {
        stop()
        self.player = player
        readiness = PreviewReadiness()
        hasFrame = false; hasSeek = false
        inactivityObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readiness.suspend() }
        }
        task = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player else { return }
                if player.status == .failed || player.currentItem?.status == .failed {
                    let message = player.currentItem?.error?.localizedDescription
                        ?? player.error?.localizedDescription ?? "Video playback failed."
                    stop(); onFailure(message); return
                }
                if readiness.timedOut(now: ProcessInfo.processInfo.systemUptime,
                    active: UIApplication.shared.applicationState == .active) {
                    stop(); onFailure(String(localized: "Couldn’t display this video.",
                        bundle: AppLanguage.bundle, locale: AppLanguage.locale)); return
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
    }

    func presented(by player: AVPlayer) {
        guard self.player === player else { return }
        hasFrame = true
        if hasSeek { readiness.presented() }
    }

    func seekCompleted(by player: AVPlayer) {
        guard self.player === player else { return }
        hasSeek = true
        if hasFrame { readiness.presented() }
    }

    func stop() {
        if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) }
        inactivityObserver = nil
        task?.cancel(); task = nil; player = nil
    }
}
