import XCTest
@testable import kicklab

final class ModelComputeSwitchTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testAcceleratedLoadFailureUsesCPUAndDoesNotRetryEachForegroundFrame() async throws {
        var loads = [Bool]()
        let backend = try ModelComputeSwitch(cpuOnly: false, allowsCPUFallbackOnLoadFailure: true) { cpu in
            loads.append(cpu)
            if !cpu { throw Failure.unavailable }
            return "cpu model"
        }
        XCTAssertEqual(loads, [false, true])
        XCTAssertTrue(backend.cpuOnly)
        XCTAssertNotNil(backend.acceleratedLoadFailure)
        for requested in [false, false, true, false] {
            XCTAssertEqual(try backend.perform(cpuOnly: { requested }) { $0 }, "cpu model")
        }
        let result = try await backend.performAsync(cpuOnly: { false }) { $0 }
        XCTAssertEqual(result, "cpu model")
        XCTAssertEqual(loads, [false, true])
        XCTAssertEqual(backend.switches, 0)
    }

    func testFailedForegroundLoadRetainsTheExistingCPUModel() throws {
        var loads = [Bool]()
        let backend = try ModelComputeSwitch(cpuOnly: true, allowsCPUFallbackOnLoadFailure: true) { cpu in
            loads.append(cpu)
            if !cpu { throw Failure.unavailable }
            return "existing cpu model"
        }
        for _ in 0..<3 {
            XCTAssertEqual(try backend.perform(cpuOnly: { false }) { $0 }, "existing cpu model")
        }
        XCTAssertEqual(loads, [true, false])
        XCTAssertTrue(backend.cpuOnly)
        XCTAssertNotNil(backend.acceleratedLoadFailure)
        XCTAssertEqual(backend.switches, 0)
    }

    func testLoadFallbackIsOptInAndDoesNotHideCPUFailure() throws {
        var loads = [Bool]()
        XCTAssertThrowsError(try ModelComputeSwitch<Bool>(cpuOnly: false) { cpu in
            loads.append(cpu); throw Failure.unavailable
        })
        XCTAssertEqual(loads, [false])
        loads = []
        XCTAssertThrowsError(try ModelComputeSwitch<Bool>(cpuOnly: false, allowsCPUFallbackOnLoadFailure: true) { cpu in
            loads.append(cpu); throw Failure.unavailable
        })
        XCTAssertEqual(loads, [false, true])
    }

    func testCancelledAcceleratedLoadDoesNotTryCPU() throws {
        var loads = [Bool]()
        XCTAssertThrowsError(try ModelComputeSwitch<Bool>(cpuOnly: false, allowsCPUFallbackOnLoadFailure: true) { cpu in
            loads.append(cpu); throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(loads, [false])
    }

    func testBackgroundTransitionRetriesSameInputOnCPU() throws {
        var background = false
        var loads = [Bool]()
        let backend = try ModelComputeSwitch(cpuOnly: false) { cpu in
            loads.append(cpu)
            return cpu
        }
        let input = [3, 5, 8]
        var submitted = [[Int]]()
        let output = try backend.perform(cpuOnly: { background }) { cpu in
            submitted.append(input)
            if !cpu { background = true; throw Failure.unavailable }
            return input.reduce(0, +)
        }
        XCTAssertEqual(output, 16)
        XCTAssertEqual(submitted, [input, input])
        XCTAssertEqual(loads, [false, true])
        XCTAssertTrue(backend.cpuOnly)
        _ = try backend.perform(cpuOnly: { true }) { $0 }
        XCTAssertEqual(loads.count, 2)
    }

    func testUnrelatedFailureIsNotRetried() throws {
        let backend = try ModelComputeSwitch(cpuOnly: false) { $0 }
        var calls = 0
        XCTAssertThrowsError(try backend.perform(cpuOnly: { false }) { _ -> Int in
            calls += 1
            throw Failure.unavailable
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(backend.switches, 0)
    }

    func testFailedReplacementPreservesWorkingBackend() throws {
        let backend = try ModelComputeSwitch(cpuOnly: false) { cpu in
            if cpu { throw Failure.unavailable }
            return "accelerated"
        }
        XCTAssertThrowsError(try backend.perform(cpuOnly: { true }) { $0 })
        XCTAssertFalse(backend.cpuOnly)
        XCTAssertEqual(try backend.perform(cpuOnly: { false }) { $0 }, "accelerated")
        XCTAssertEqual(backend.switches, 0)
    }

    func testOperationCancellationIsNeverConvertedIntoARetry() throws {
        var background = false
        var loads = 0
        let backend = try ModelComputeSwitch(cpuOnly: false) { cpu in loads += 1; return cpu }
        XCTAssertThrowsError(try backend.perform(cpuOnly: { background }) { _ -> Bool in
            background = true
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(backend.switches, 0)
    }

    func testCancellationPreventsBackgroundRetry() async throws {
        let worker = Task {
            var background = false
            var calls = 0
            let backend = try ModelComputeSwitch(cpuOnly: false) { $0 }
            do {
                _ = try backend.perform(cpuOnly: { background }) { _ -> Bool in
                    calls += 1
                    background = true
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw Failure.unavailable
                }
                XCTFail("Cancelled work must not retry")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            return calls
        }
        let calls = try await worker.value
        XCTAssertEqual(calls, 1)
    }

    func testAsyncBatchRetriesBeforeReturningAnyResults() async throws {
        var background = false
        let backend = try ModelComputeSwitch(cpuOnly: false) { $0 }
        let output = try await backend.performAsync(cpuOnly: { background }) { cpu in
            if !cpu { background = true; throw Failure.unavailable }
            return [1, 2]
        }
        XCTAssertEqual(output, [1, 2])
        XCTAssertEqual(backend.switches, 1)
    }
}
