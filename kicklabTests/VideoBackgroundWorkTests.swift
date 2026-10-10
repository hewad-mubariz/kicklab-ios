import XCTest
@testable import kicklab

final class VideoBackgroundWorkTests: XCTestCase {
    func testGrantedJobAdmitsBackgroundFramesAndExpiryCancelsWork() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        let worker = Task {
            try await VideoWorkExecution.$lease.withValue(lease) {
                var pacer = VideoAnalysisPacer(thermalState: { .nominal }, isBackground: { true })
                _ = try await pacer.beginFrame { _ in }
                XCTAssertTrue(VideoWorkExecution.cpuOnly)
                while true { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
        lease.onExpiration { worker.cancel() }
        try await Task.sleep(for: .milliseconds(40))
        lease.expire()
        do { try await worker.value; XCTFail("Expired work must stop") } catch is CancellationError {}
        XCTAssertFalse(lease.canContinue)
    }

    func testDetachedWorkerInheritsOnlyItsOwnLease() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        let inherited = try await VideoWorkExecution.$lease.withValue(lease) {
            try await VideoWorkExecution.detached { VideoWorkExecution.lease === lease }.value
        }
        XCTAssertTrue(inherited)
        XCTAssertNil(VideoWorkExecution.lease)
        XCTAssertFalse(VideoWorkExecution.cpuOnly)
        lease.revoke()
        XCTAssertFalse(lease.canContinue)
        XCTAssertFalse(lease.isCancelled)
    }
}
