import Foundation

@main struct ContactWindowClockContracts {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: checks) }
            checks += 1
        }
        var clock = ContactWindowClock()
        try check(clock.admit(source: 22.766,now:100), "Initial slot")
        try check(clock.admit(source: 23.1,now:100.278), "Bounded delivery jitter")
        try check(abs(clock.nextWall! - 100.6) < 0.000001, "Credit must be repaid")
        try check(!clock.admit(source: 23.434,now:100.54), "No cumulative credit")
        try check(clock.admit(source: 23.434,now:100.58), "Next bounded slot")
        try check(!clock.admit(source: 23.6,now:101), "Source interval unchanged")
        try check(clock.admit(source: 25,now:103), "Idle resets debt")
        try check(!clock.admit(source:25.334,now:103.26), "More than a frame early")
        try check(!clock.admit(source:.nan,now:104), "Invalid source")
        try check(!clock.admit(source:25.334,now:.infinity), "Invalid clock")
        try check(!clock.admit(source:24,now:104), "Reversed source")
        var accelerated = ContactWindowClock()
        var admitted = 0
        for i in 0..<3000 {
            let wall = 100 + Double(i) * 0.01
            if accelerated.admit(source:Double(i)*0.334,now:wall) { admitted += 1 }
            let capacity = 1 + Int(floor((wall-100+accelerated.credit+0.000001)/accelerated.interval))
            try check(admitted <= capacity, "Sustained wall rate exceeded")
        }
        var offline = ContactWindowClock()
        try check(offline.admit(source:0,now:0,enforceWall:false), "Offline initial")
        try check(offline.admit(source:0.3,now:0,enforceWall:false), "Offline source clock")
        try check(!offline.admit(source:0.4,now:0,enforceWall:false), "Offline source spacing")
        try check(!ContactWindowClock.enabled(arguments:[]), "Default off")
        #if DEBUG
        try check(ContactWindowClock.enabled(arguments:["--contact-window-clock-v1"]), "Debug opt-in")
        #else
        try check(!ContactWindowClock.enabled(arguments:["--contact-window-clock-v1"]), "Release unchanged")
        #endif
        print("PASS: \(checks) contact-window clock contracts")
    }
}
