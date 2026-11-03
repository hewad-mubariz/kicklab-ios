import Combine
import UIKit

/// Storage identity is independent of rank and of the short-lived download URL.
nonisolated struct PlayerPhotoReference: Hashable, Sendable {
    let playerID: UUID
    let path: String
}

/// Shared by list rows, details and the profile editor for the current account.
/// Cache decoded pixels, coalesce concurrent loads, and never retain signed URLs.
@MainActor
final class PlayerPhotoCache: ObservableObject {
    private struct Photo {
        let data: Data
        let image: UIImage
        let loadedAt: Date
        var accessedAt: Date
        var cost: Int { data.count + (image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
    }
    private struct Request {
        let id: UUID
        let task: Task<Data?, Never>
    }
    @Published private(set) var revision = 0
    private var generation = UUID()
    private var versions: [PlayerPhotoReference: Int] = [:]
    private var photos: [PlayerPhotoReference: Photo] = [:]
    private var requests: [PlayerPhotoReference: Request] = [:]
    private let maximumBytes: Int
    private let lifetime: TimeInterval
    private let now: () -> Date

    init(maximumBytes: Int = 16 * 1_024 * 1_024, lifetime: TimeInterval = 300,
         now: @escaping () -> Date = Date.init) {
        self.maximumBytes = maximumBytes; self.lifetime = lifetime; self.now = now
    }

    func identity(for reference: PlayerPhotoReference) -> String {
        "\(generation)-\(reference.playerID)-\(reference.path)-\(versions[reference, default: 0])"
    }

    func image(for reference: PlayerPhotoReference) -> UIImage? { photos[reference]?.image }
    func isLoading(_ reference: PlayerPhotoReference) -> Bool { requests[reference] != nil }

    @discardableResult
    func load(_ reference: PlayerPhotoReference, fetch: @escaping @MainActor () async throws -> Data) async -> Data? {
        if var photo = photos[reference], now().timeIntervalSince(photo.loadedAt) < lifetime {
            photo.accessedAt = now(); photos[reference] = photo
            return photo.data
        }
        if let request = requests[reference] { return await request.task.value }
        let id = UUID()
        let task = Task<Data?, Never> { @MainActor in
            defer {
                if self.requests[reference]?.id == id {
                    self.requests[reference] = nil; self.revision += 1
                }
            }
            do {
                let data = try await fetch()
                guard self.requests[reference]?.id == id, !Task.isCancelled else { return nil }
                try self.store(data, for: reference)
                return data
            } catch {
                // Retry on the next appearance, retaining any already shown photo.
                return self.requests[reference]?.id == id ? self.photos[reference]?.data : nil
            }
        }
        requests[reference] = Request(id: id, task: task); revision += 1
        return await task.value
    }

    func store(_ data: Data, for reference: PlayerPhotoReference) throws {
        guard data.count <= 2_097_152, let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0,
              image.size.width * image.scale <= 2_048, image.size.height * image.scale <= 2_048 else {
            throw PlayerDataError.requestFailed
        }
        requests.removeValue(forKey: reference)?.task.cancel()
        let date = now()
        photos[reference] = Photo(data: data, image: image, loadedAt: date, accessedAt: date)
        while photos.values.reduce(0, { $0 + $1.cost }) > maximumBytes,
              let oldest = photos.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            photos[oldest] = nil
        }
        revision += 1
    }

    func remove(_ reference: PlayerPhotoReference) {
        versions[reference, default: 0] += 1
        requests.removeValue(forKey: reference)?.task.cancel()
        photos[reference] = nil; revision += 1
    }

    func reset() {
        requests.values.forEach { $0.task.cancel() }
        requests = [:]; photos = [:]; versions = [:]; generation = UUID(); revision += 1
    }
}
