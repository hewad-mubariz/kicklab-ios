import CoreGraphics
import Foundation
import Metal

/// Two owned CPU canvases/textures, leased until GPU completion. A slot may be
/// reused only after its lease is released; resizing replaces an idle slot.
nonisolated final class BallMaterialTexturePool: @unchecked Sendable {
    enum Failure: LocalizedError {
        case allocation
        var errorDescription: String? { "Couldn’t prepare the ball material buffer." }
    }
    fileprivate final class Slot {
        let context: CGContext
        let texture: MTLTexture
        var busy = false // guarded by the pool lock
        init(device: MTLDevice, width: Int, height: Int) throws {
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Failure.allocation }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            self.context = context; self.texture = texture
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        }
    }
    final class Lease: @unchecked Sendable {
        private let owner: BallMaterialTexturePool
        fileprivate let slot: Slot
        private let releaseLock = NSLock()
        private var released = false
        var context: CGContext { slot.context }
        var texture: MTLTexture { slot.texture }
        fileprivate init(owner: BallMaterialTexturePool, slot: Slot) { self.owner = owner; self.slot = slot }
        /// Call only after all encoded GPU reads have completed. Idempotent so
        /// the error path and deinit cannot release a subsequently reused slot.
        func release() {
            releaseLock.lock(); defer { releaseLock.unlock() }
            guard !released else { return }
            released = true
            owner.release(slot)
        }
        deinit { release() }
        func upload() {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: context.data!, bytesPerRow: context.bytesPerRow)
        }
    }
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var allocations = 0
    var allocationCount: Int { lock.lock(); defer { lock.unlock() }; return allocations }
    var retainedSlotCount: Int { lock.lock(); defer { lock.unlock() }; return slots.count }

    func acquire(device: MTLDevice, width: Int, height: Int) throws -> Lease? {
        lock.lock(); defer { lock.unlock() }
        let index: Int
        if let matching = slots.firstIndex(where: { !$0.busy && $0.texture.width == width && $0.texture.height == height }) {
            index = matching
        } else if let idle = slots.firstIndex(where: { !$0.busy }) {
            slots[idle] = try Slot(device: device, width: width, height: height)
            allocations += 1; index = idle
        } else if slots.count < 2 {
            slots.append(try Slot(device: device, width: width, height: height))
            allocations += 1; index = slots.count - 1
        } else { return nil }
        let slot = slots[index]
        slot.busy = true
        // Reset all channels, including the old ball region and fully empty
        // mask frames. The top-left transform is established only on allocation.
        slot.context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return Lease(owner: self, slot: slot)
    }
    private func release(_ slot: Slot) { lock.lock(); defer { lock.unlock() }; slot.busy = false }
    /// In-flight leases keep their own resources alive. Their completion never
    /// puts retired slots back into this pool after teardown or a skin change.
    func removeAll() { lock.lock(); defer { lock.unlock() }; slots.removeAll() }
}
