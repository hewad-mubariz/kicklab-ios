import Testing
@testable import kicklab

struct ContactFrameWindowTests {
    private typealias Stamp = ContactFrameWindow.Stamp

    @Test(arguments: [30, 60, 120, 240])
    func floorWindowRetainsItsRequiredApproachAtHighFrameRates(fps: Int) {
        var buffered: [Stamp] = []
        let contact = Stamp(index: fps, timestampMs: 1000)
        for i in 0...fps*3 {
            let latest = Stamp(index: i, timestampMs: Int((Double(i)*1000/Double(fps)).rounded()))
            buffered.append(latest)
            let retained = ContactFrameWindow.retainedIndices(buffered, latest: latest,
                pendingIndex: i >= fps+3 ? fps : nil)
            buffered.removeAll { !retained.contains($0.index) }
            #expect(buffered.count <= ContactFrameWindow.maximumBufferedFrames)
        }
        let indices = ContactFrameWindow.groundIndices(buffered, around: contact)
        let times = buffered.filter { indices.contains($0.index) }.map { $0.timestampMs-1000 }.sorted()
        #expect((7...13).contains(times.count))
        #expect(times.first! <= -200)
        #expect(times.last! >= 25)
        #expect(zip(times,times.dropFirst()).allSatisfy { $1-$0 <= 110 })
    }

    @Test func absentCandidateRetainsRealNeighborsButCannotBridgeALongGap() {
        var buffered: [Stamp] = []
        for i in 0...180 {
            let latest = Stamp(index: i, timestampMs: i*17)
            if i != 60 { buffered.append(latest) }
            let retained = ContactFrameWindow.retainedIndices(buffered, latest: latest,
                pendingIndex: i >= 63 ? 60 : nil, pendingTimestampMs: i >= 63 ? 1020 : nil)
            buffered.removeAll { !retained.contains($0.index) }
            #expect(buffered.count <= ContactFrameWindow.maximumBufferedFrames)
        }
        #expect(!buffered.contains { $0.index == 60 })
        #expect(buffered.contains { $0.index == 59 })
        #expect(buffered.contains { $0.index == 61 })
    }

    @Test(arguments: [15, 30, 60, 120, 240])
    func motionWindowSpansRealTimeAtEveryFrameRate(fps: Int) throws {
        let frames = (0...fps*2).map { Stamp(index: $0, timestampMs: Int((Double($0)*1000/Double(fps)).rounded())) }
        let contact = frames[fps]
        let indices = ContactFrameWindow.motionIndices(frames, around: contact)
        let times = frames.filter { indices.contains($0.index) }.map { $0.timestampMs-contact.timestampMs }
        #expect(indices.contains(contact.index))
        #expect(indices.count <= 7)
        #expect(times.contains { (-100 ... -50).contains($0) })
        #expect(times.contains { (25...130).contains($0) })
        #expect(times.allSatisfy { (-100...150).contains($0) })
    }

    @Test(arguments: [15, 24, 30, 60, 120, 240])
    func trackedFootWindowStartsEarlierWithoutExceedingSevenSamples(fps: Int) {
        let frames = (0...fps*3).map { Stamp(index:$0,timestampMs:Int((Double($0)*1000/Double(fps)).rounded())) }
        let contact = frames[fps*2]
        let indices = ContactFrameWindow.trackedFootIndices(frames,around:contact)
        let times = frames.filter { indices.contains($0.index) }
            .map { $0.timestampMs-contact.timestampMs }.sorted()
        #expect(indices.contains(contact.index))
        #expect((5...7).contains(indices.count))
        #expect(times.first! <= -150)
        #expect(times.last! >= 67)
        #expect(times.allSatisfy { (-225...125).contains($0) })
        #expect(zip(times,times.dropFirst()).allSatisfy { $1-$0 <= 85 })
    }

    @Test func trackedFootWindowKeepsRoundedPostContactFrame() {
        let offsets = [-200, -167, -100, -67, 0, 34, 101]
        let frames = offsets.enumerated().map { Stamp(index:$0.offset,timestampMs:1000+$0.element) }
        let indices = ContactFrameWindow.trackedFootIndices(frames,around:frames[4])
        let times = frames.filter { indices.contains($0.index) }
            .map { $0.timestampMs-1000 }.sorted()
        #expect(times == offsets)
    }

    @Test func fastConfirmationUsesOnlyAlreadyArrivedObservations() {
        let frames = (0...126).map { Stamp(index: $0, timestampMs: Int((Double($0)*1000/120).rounded())) }
        let indices = ContactFrameWindow.motionIndices(frames, around: frames[120])
        let times = frames.filter { indices.contains($0.index) }.map(\.timestampMs)
        #expect(times.min() == 900)
        #expect(times.max() == 1050)
        #expect(indices.count <= 7)
        // The old +/-3 frame window spans only 50 ms and cannot satisfy the
        // foot rule's >=50 ms approach plus >=25 ms departure.
        #expect(frames[123].timestampMs-frames[117].timestampMs < 75)
    }

    @Test(arguments: [15, 30, 60, 120, 240])
    func slowConfirmationKeepsApproachAndHandNeighborsWithinMemoryBound(fps: Int) {
        var buffered: [Stamp] = []
        let contactIndex = fps
        for index in 0...fps*4 {
            let latest = Stamp(index: index, timestampMs: Int((Double(index)*1000/Double(fps)).rounded()))
            buffered.append(latest)
            let pending = index >= contactIndex+3 ? contactIndex : nil
            let retained = ContactFrameWindow.retainedIndices(buffered, latest: latest, pendingIndex: pending)
            buffered.removeAll { !retained.contains($0.index) }
            #expect(buffered.count <= ContactFrameWindow.maximumBufferedFrames)
        }
        // At 15 fps nine earlier frames exceed the existing 500 ms history;
        // retention must not claim to reconstruct observations already expired.
        let firstNeighbor = fps >= 30 ? contactIndex-9 : contactIndex
        #expect((firstNeighbor...contactIndex+3).allSatisfy { index in buffered.contains { $0.index == index } })
        let contact = Stamp(index: contactIndex, timestampMs: 1000)
        let tracked = ContactFrameWindow.trackedFootIndices(buffered,around:contact)
        let trackedTimes = buffered.filter { tracked.contains($0.index) }.map { $0.timestampMs-1000 }
        #expect(tracked.contains(contactIndex))
        if fps >= 60 { #expect(trackedTimes.contains { (-225 ... -175).contains($0) }) }
        #expect(tracked.count <= 7)
        let motion = ContactFrameWindow.motionIndices(buffered, around: contact)
        let times = buffered.filter { motion.contains($0.index) }.map(\.timestampMs)
        #expect(times.contains { (900...950).contains($0) })
        #expect(times.contains { (1025...1130).contains($0) })
        let released = ContactFrameWindow.retainedIndices(buffered, latest: .init(index: fps*4, timestampMs: 4000), pendingIndex: nil)
        #expect(!released.contains(contactIndex))
        #expect(released.count <= 29)
    }

    @Test func gapsCannotBeFilledWithDistantOrInventedFrames() {
        let contact = Stamp(index: 5, timestampMs: 1000)
        let frames = [Stamp(index: 0, timestampMs: 500), contact, Stamp(index: 8, timestampMs: 1500)]
        #expect(ContactFrameWindow.motionIndices(frames, around: contact) == [5])
    }
}
