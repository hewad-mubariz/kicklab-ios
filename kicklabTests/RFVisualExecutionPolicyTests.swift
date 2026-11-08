import Foundation
import XCTest
@testable import kicklab

final class RFVisualExecutionPolicyTests: XCTestCase {
    private func mode(_ device: String = "iPhone18,2", visualOnly: Bool = true,
                      isRF: Bool = true, arguments: [String] = []) -> RFVisualExecutionPolicy.Mode {
        RFVisualExecutionPolicy.select(visualOnly: visualOnly, isProductionRF: isRF,
            hardwareIdentifier: device, arguments: arguments)
    }
    func testOnlyMeasuredRFDeviceAutomaticallyOverlapsFrames() {
        XCTAssertEqual(mode(), .async2)
        for device in ["iPhone12,5", "iPhone13,2", "iPhone18,1", "unknown"] {
            XCTAssertEqual(mode(device), .serial, device)
        }
        XCTAssertEqual(mode(isRF: false), .serial)
    }
    func testCountingNeverInheritsAppearanceExecution() {
        for flags in [[], ["--visual-async2"], ["--visual-batch2"], ["--visual-serial"]] {
            XCTAssertEqual(mode(visualOnly: false, arguments: flags), .serial)
        }
    }
    func testSerialOverrideWinsAndExperimentalModesRemainExplicit() {
        XCTAssertEqual(mode(arguments: ["--visual-serial", "--visual-async2"]), .serial)
        XCTAssertEqual(mode(arguments: ["--visual-batch2"]), .batch2)
        XCTAssertEqual(mode("unknown", arguments: ["--visual-async2"]), .async2)
    }
    func testCPUUnsupportedAndWarmerExecutionUseSingleFrames() {
        let value = mode()
        XCTAssertTrue(value.canBatch(supported: true, cpuOnly: false, thermal: .nominal))
        XCTAssertFalse(value.canBatch(supported: false, cpuOnly: false, thermal: .nominal))
        XCTAssertFalse(value.canBatch(supported: true, cpuOnly: true, thermal: .nominal))
        for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
            XCTAssertFalse(value.canBatch(supported: true, cpuOnly: false, thermal: state))
        }
        // A subsequent pair can resume after recovery; there is no stale latch.
        XCTAssertTrue(value.canBatch(supported: true, cpuOnly: false, thermal: .nominal))
        XCTAssertFalse(RFVisualExecutionPolicy.Mode.serial.canBatch(supported: true, cpuOnly: false, thermal: .nominal))
    }
    func testAutomaticAndExplicitAsyncShareOnlyTheAsyncCacheIdentity() {
        XCTAssertEqual(mode().cacheSuffix, mode(arguments: ["--visual-async2"]).cacheSuffix)
        XCTAssertNotEqual(mode().cacheSuffix, mode(arguments: ["--visual-batch2"]).cacheSuffix)
        XCTAssertNotEqual(mode().cacheSuffix, mode(arguments: ["--visual-serial"]).cacheSuffix)
        XCTAssertEqual(mode().batchSize, 2)
        XCTAssertEqual(mode(visualOnly: false).batchSize, 1)
    }
}
