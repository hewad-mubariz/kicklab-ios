import Testing
@testable import kicklab

struct RFWorkerAdmissionTests {
    @Test func aContactCanReserveOnlyOneFreshTrackingExposure() {
        #expect(RFWorkerAdmissionPolicy.permits(occupied: false, contactRequested: true,
            interleaves: true, purpose: "regular"))
        // The reservation stays occupied while queued, running, and awaiting
        // consumption. None of those phases may accumulate another image.
        for contact in [false, true] {
            for purpose in ["regular", "impact_gap"] {
                #expect(!RFWorkerAdmissionPolicy.permits(occupied: true, contactRequested: contact,
                    interleaves: true, purpose: purpose))
            }
        }
    }
    @Test func aDelayedImpactRetryCannotQueueBehindContactWork() {
        #expect(!RFWorkerAdmissionPolicy.permits(occupied: false, contactRequested: true,
            interleaves: true, purpose: "impact_gap"))
        #expect(RFWorkerAdmissionPolicy.permits(occupied: false, contactRequested: false,
            interleaves: true, purpose: "impact_gap"))
    }
    @Test func shippingSchedulingRemainsUnchangedWithoutTheExperiment() {
        #expect(!RFWorkerAdmissionPolicy.enabled(arguments: []))
        #expect(RFWorkerAdmissionPolicy.enabled(arguments: ["--rf-interleave-contact"]))
        #expect(!RFWorkerAdmissionPolicy.permits(occupied: false, contactRequested: true,
            interleaves: false, purpose: "regular"))
        #expect(RFWorkerAdmissionPolicy.permits(occupied: false, contactRequested: false,
            interleaves: false, purpose: "regular"))
    }
}
