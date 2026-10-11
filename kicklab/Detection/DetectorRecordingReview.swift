#if DEBUG
import Darwin
import Foundation

/// Memory helper for local accuracy tests; never included in distributed builds.
nonisolated enum DetectorRecordingReview {
    static func memory() -> (current: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return result == KERN_SUCCESS
            ? (Double(info.phys_footprint), Double(info.ledger_phys_footprint_peak)) : nil
    }

}
#endif
