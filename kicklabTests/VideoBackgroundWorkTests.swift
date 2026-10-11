import XCTest
@testable import kicklab

final class VideoBackgroundWorkTests: XCTestCase {
    func testAccuracyComparisonPinsCPUWithoutBackgroundGrantAndDoesNotLeak() async throws {
        let lease = VideoWorkLease(allowed: false, cpuOnly: false, backgroundGPU: false)
        try await VideoWorkExecution.$lease.withValue(lease) {
            try await VideoWorkExecution.$accuracyComparison.withValue(true) {
                try await VideoWorkExecution.detached {
                    XCTAssertTrue(VideoWorkExecution.isAnalysisStudy)
                    XCTAssertTrue(VideoWorkExecution.cpuOnly)
                    XCTAssertTrue(VideoWorkExecution.modelCPUOnly)
                    XCTAssertFalse(VideoWorkExecution.canAnalyzeInBackground)
                    VideoWorkExecution.$modelAccelerationStudy.withValue(true) {
                        XCTAssertTrue(VideoWorkExecution.cpuOnly)
                        XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
                        lease.setForeground(false)
                        XCTAssertTrue(VideoWorkExecution.modelCPUOnly)
                    }
                }.value
            }
            XCTAssertFalse(VideoWorkExecution.cpuOnly)
            XCTAssertFalse(VideoWorkExecution.isAnalysisStudy)
        }
        XCTAssertFalse(VideoWorkExecution.accuracyComparison)
    }

    func testModelStudyFollowsForegroundWithoutChangingImageOrBackgroundPolicy() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        try await VideoWorkExecution.$lease.withValue(lease) {
            try await VideoWorkExecution.$modelAccelerationStudy.withValue(true) {
                try await VideoWorkExecution.detached {
                    XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
                    XCTAssertTrue(VideoWorkExecution.cpuOnly)
                    lease.setForeground(false)
                    XCTAssertTrue(VideoWorkExecution.modelCPUOnly)
                    XCTAssertTrue(VideoWorkExecution.canAnalyzeInBackground)
                    lease.setForeground(true)
                    XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
                }.value
            }
            XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
        }
        XCTAssertFalse(VideoWorkExecution.modelAccelerationStudy)
    }

    func testNormalJobAcceleratesModelAndFallsBackOnCPUWhenInactive() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        try await VideoWorkExecution.$lease.withValue(lease) {
            try await VideoWorkExecution.detached {
                XCTAssertFalse(VideoWorkExecution.isAnalysisStudy)
                XCTAssertTrue(VideoWorkExecution.followsModelLifecycle)
                XCTAssertTrue(VideoWorkExecution.cpuOnly)
                XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
                lease.setForeground(false)
                XCTAssertTrue(VideoWorkExecution.modelCPUOnly)
                XCTAssertTrue(VideoWorkExecution.canAnalyzeInBackground)
                lease.setForeground(true)
                XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
            }.value
        }
        XCTAssertFalse(VideoWorkExecution.followsModelLifecycle)
    }

    func testNormalAccelerationDoesNotGrantDeniedBackgroundRuntime() {
        let lease = VideoWorkLease(allowed: false, cpuOnly: false, backgroundGPU: false)
        VideoWorkExecution.$lease.withValue(lease) {
            XCTAssertFalse(VideoWorkExecution.modelCPUOnly)
            XCTAssertFalse(VideoWorkExecution.canAnalyzeInBackground)
            lease.setForeground(false)
            XCTAssertTrue(VideoWorkExecution.modelCPUOnly)
            XCTAssertFalse(VideoWorkExecution.canAnalyzeInBackground)
        }
    }

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

    func testForegroundStudyInheritsAccelerationButNotCPUBackgroundPermission() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        try await VideoWorkExecution.$lease.withValue(lease) {
            try await VideoWorkExecution.$foregroundAccelerationStudy.withValue(true) {
                let values = try await VideoWorkExecution.detached {
                    (VideoWorkExecution.cpuOnly, VideoWorkExecution.canAnalyzeInBackground)
                }.value
                XCTAssertFalse(values.0)
                XCTAssertFalse(values.1)
            }
            // The experiment must not change subsequent normal/background work.
            XCTAssertTrue(VideoWorkExecution.cpuOnly)
            XCTAssertTrue(VideoWorkExecution.canAnalyzeInBackground)
        }
        XCTAssertFalse(VideoWorkExecution.foregroundAccelerationStudy)
    }

    func testAcceleratedStudyPausesBeforeBackgroundFramesUntilCancelled() async throws {
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        let worker = Task {
            try await VideoWorkExecution.$lease.withValue(lease) {
                try await VideoWorkExecution.$foregroundAccelerationStudy.withValue(true) {
                    var pacer = VideoAnalysisPacer(thermalState: { .nominal }, isBackground: { true })
                    _ = try await pacer.beginFrame { _ in }
                }
            }
        }
        lease.onExpiration { worker.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        lease.expire()
        do {
            try await worker.value
            XCTFail("CPU-only background permission must not admit accelerated frames")
        } catch is CancellationError {}
    }
}
