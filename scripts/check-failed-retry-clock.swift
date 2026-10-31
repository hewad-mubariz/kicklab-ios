import Foundation
@main struct FailedRetryClockContracts {
    static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ reason:String) throws {
            guard condition else { throw NSError(domain:reason,code:checks) };checks+=1
        }
        func restore(_ current:Double=100.045,_ submitted:Double=100.045,_ previous:Double=100,_ accepted:Bool=false)->Double? {
            RFFailedRetryClock.restoredClock(current:current,submitted:submitted,previous:previous,accepted:accepted)
        }
        try check(restore()==100,"A completed failed retry restores its own charge")
        try check(restore(100.045,100.045,100,true)==nil,"Successful recovery keeps its timing")
        try check(restore(100.100)==nil,"Do not roll back a newer regular job")
        try check(restore(100)==nil,"Do not restore the same retry twice")
        try check(restore(100.045,100.045,100.05)==nil,"Reject reversed history")
        try check(restore(100.045,100.045,100.045)==nil,"Reject equal prior time")
        try check(restore(.nan)==nil && restore(.infinity)==nil,"Reject invalid current time")
        try check(restore(100.045,.nan)==nil,"Reject invalid submitted time")
        try check(restore(100.045,100.045,-.infinity)==nil,"Require real prior admission")
        try check(restore(200.045,200.045,200)==200,"Clock translation invariance")
        let failed=restore()!
        try check(RFSourceCadence.rateReady(version:0,now:100.1,due:100.1,targetHz:12,lastAny:failed,lastRegular:100),"Restore next ordinary opportunity")
        try check(!RFSourceCadence.rateReady(version:0,now:100.066,due:100.066,targetHz:12,lastAny:failed,lastRegular:100),"Keep regular rate bound")
        try check(!RFFailedRetryClock.enabled(arguments:[]),"Default unchanged")
        #if DEBUG
        try check(RFFailedRetryClock.enabled(arguments:["--rf-failed-retry-clock-v1"]),"Explicit opt-in")
        #else
        try check(!RFFailedRetryClock.enabled(arguments:["--rf-failed-retry-clock-v1"]),"Release unchanged")
        #endif
        let conflict=["--rf-failed-retry-clock-v1","--rf-independent-regular-clock-v1"]
        try check(!RFFailedRetryClock.enabled(arguments:conflict) && !RFIndependentRegularClock.enabled(arguments:conflict),"No combined clock experiments")
        for v in 1...4 { try check(!RFFailedRetryClock.enabled(arguments:["--rf-failed-retry-clock-v1","--rf-source-cadence-v\(v)"]),"No source-grid experiment") }
        print("PASS: \(checks) failed-retry clock contracts")
    }
}
