import Foundation

@main struct IndependentRegularClockContracts {
    static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ reason:String) throws {
            guard condition else { throw NSError(domain:reason,code:checks) };checks+=1
        }
        func ready(_ now:Double,_ regular:Double,_ any:Double,_ independent:Bool=true,_ hz:Double=12)->Bool {
            RFIndependentRegularClock.rateReady(now:now,targetHz:hz,lastAny:any,
                lastRegular:regular,independent:independent)
        }
        // A regular exposure at100.000, then an old-image retry at100.045.
        // The next regular opportunity at100.100 must not be delayed to100.133.
        try check(!ready(100.100,100,100.045,false),"Reproduce shared-clock suppression")
        try check(ready(100.100,100,100.045),"Keep the next ordinary exposure eligible")
        try check(!ready(100.066,100,100.045),"Keep full regular rate interval")
        try check(!ready(100.080,100,100.045),"Do not adopt half-interval burst guard")
        try check(ready(100.133,100,100.045,false),"Baseline eventually admits its later exposure")
        try check(ready(200.100,200,200.045),"No absolute-clock dependency")
        try check(!ready(100.100,100,100.045,true,8),"Respect a slower regular rate")
        try check(!ready(101,100,100.045,true,0),"No admission at zero rate")
        try check(ready(100,-.infinity,-.infinity),"First regular exposure")
        try check(!RFIndependentRegularClock.enabled(arguments:[]),"Default unchanged")
        #if DEBUG
        try check(RFIndependentRegularClock.enabled(arguments:["--rf-independent-regular-clock-v1"]),"Explicit debug opt-in")
        #else
        try check(!RFIndependentRegularClock.enabled(arguments:["--rf-independent-regular-clock-v1"]),"Release remains off")
        #endif
        for grid in 1...4 {
            try check(!RFIndependentRegularClock.enabled(arguments:["--rf-independent-regular-clock-v1","--rf-source-cadence-v\(grid)"]),"Do not combine with source-grid experiments")
        }
        // Bursty arrivals and frequent retries cannot buy extra regular jobs.
        var last = -Double.infinity, count=0
        for i in 0..<10_000 {
            let now=100+Double(i)*0.001
            if ready(now,last,now-0.010) {
                try check(!last.isFinite || now-last>=1.0/12,"Regular wall-rate cap")
                last=now;count+=1
            }
            try check(count<=1+Int(floor((now-100)*12+0.000001)),"No rate debt or catch-up burst")
        }
        print("PASS: \(checks) independent regular-clock checks")
    }
}
