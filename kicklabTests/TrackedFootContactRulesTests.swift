import Testing
@testable import kicklab

struct TrackedFootContactRulesTests {
    @Test func allowsStableTrackedContactInsideLandmarkMargin() {
        let contactMs = 1000
        let samples = [900, 967, 1000, 1034, 1067].map { timestamp in
            let isSeed = timestamp == 900
            let isContact = timestamp == contactMs
            return FootPoseSample(
                pose: .init(timestampMs:timestamp,
                    ball:.init(x:0.4,y:isSeed ? 0.4 : isContact ? 0.59 : 0.4),
                    width:0.2,height:0.2,confidence:0.95,imageAspect:1,joints:[:]),
                ankles:[.left:.init(x:0.4,y:0.75),.right:.init(x:0.7,y:0.9)],
                landmarks:[
                    .leftHip:.init(x:0.4,y:0.5),
                    .leftKnee:.init(x:0.4,y:0.55),
                    .leftAnkle:.init(x:0.4,y:0.75),
                    .rightAnkle:.init(x:0.7,y:0.9)
                ])
        }
        let track = [
            (900,0.75),(967,0.76),(1000,0.80),(1034,0.85),(1067,0.86)
        ].map { value in
            TrackedFootContactRules.Observation(timestampMs:value.0,
                point:.init(x:0.4,y:value.1),roundTripError:0.001,spread:0.01,retainedPoints:9)
        }
        let plan = TrackedFootContactRules.Plan(side:.left,seedMs:900,
            seed:.init(x:0.4,y:0.75),shin:0.2)

        #expect(TrackedFootContactRules.contactTime(samples,track:track,plan:plan,at:contactMs) == contactMs)
    }
}
