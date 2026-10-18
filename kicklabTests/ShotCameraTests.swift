import AVFoundation
import Metal
import XCTest
@testable import kicklab

/// The camera track: editing, the replay clock, the per-frame plan and its two renderers.
final class ShotCameraTests: XCTestCase {
    // MARK: Fixtures

    /// The ball rests until 0.5 s, then flies up and away, shrinking; the kicker stands to its left.
    private func flight(person: Bool = true) -> BallEffectTrack {
        BallEffectTrack(frames: (0...90).map { i in
            let t = Double(i) / 60, f = min(1, max(0, (t - 0.5) / 0.8))
            let x = 0.6 + 0.1 * f, y = 0.8 - 0.45 * f, w = 0.08 - 0.06 * f
            return RecordedFrame(time: t, x: x, y: y, width: w, height: w * 9 / 16, score: 0.9, smoothedX: x, smoothedY: y,
                                 vy: 0, motion: .unknown, detected: true,
                                 person: person ? PersonBox(x: 0.4, y: 0.55, width: 0.25, height: 0.5) : nil)
        })
    }
    private func still(x: Double = 0.75, y: Double = 0.6) -> BallEffectTrack {
        BallEffectTrack(frames: [0, 0.02, 0.04, 0.06].map { t in
            RecordedFrame(time: t, x: x, y: y, width: 0.04, height: 0.07, score: 0.9, smoothedX: x, smoothedY: y,
                          vy: 0, motion: .unknown, detected: true, person: nil)
        })
    }
    private func plan(_ clips: [ShotCameraClip], ball: BallEffectTrack? = nil, strike: Double = 0.5, duration: Double = 1.5,
                      aspect: Double = 9.0 / 16) -> ShotCameraPlan {
        ShotCameraPlan(track: ShotCameraTrack(clips: clips, strike: strike), ball: ball ?? flight(), flight: nil,
                       duration: duration, aspect: aspect)
    }
    private func clip(_ move: ShotCameraMove, _ start: Double, _ end: Double, _ change: (inout ShotMoveSettings) -> Void = { _ in }) -> ShotCameraClip {
        var settings = ShotMoveSettings.defaults(for: move)
        change(&settings)
        return ShotCameraClip(move: move, start: start, end: end, settings: settings)
    }

    // MARK: Track editing

    func testInsertedMovesNeverOverlapAndGiveWayOnlyWhenNeeded() {
        var track = ShotCameraTrack()
        track.insert(.impact, range: 0.4...1.0, duration: 2)
        track.insert(.chase, range: 0.9...1.8, duration: 2)
        XCTAssertEqual(track.clips.map(\.move), [.impact, .chase])
        XCTAssertEqual(track.clips[0].end, 0.9, accuracy: 0.0001, "The overlapped neighbour is trimmed back, not removed")
        track.insert(.ramp, range: 0.3...1.9, duration: 2)
        XCTAssertEqual(track.clips.map(\.move), [.ramp], "Neighbours with nothing useful left are removed")
        for (a, b) in zip(track.clips, track.clips.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testNewMovesFitBesideExistingOnes() throws {
        var track = ShotCameraTrack()
        track.insert(.impact, range: 0.38...1.0, duration: 2)
        let fitted = try XCTUnwrap(track.fit(0.2...1.6, duration: 2))
        XCTAssertEqual(fitted.lowerBound, 1.0, accuracy: 0.0001, "A follow move starts where the hit ends")
        XCTAssertEqual(fitted.upperBound, 1.6, accuracy: 0.0001)
        track.insert(.chase, range: fitted, duration: 2)
        XCTAssertEqual(track.clips.map(\.move), [.impact, .chase])
        track.insert(.lens, range: 0...0.38, duration: 2)
        track.insert(.spotlight, range: 1.6...2, duration: 2)
        XCTAssertNil(track.fit(0.5...0.9, duration: 2), "A full track has no room")
    }

    func testMovingTheStrikeCarriesTheMovesOnIt() {
        var track = ShotCameraTrack(clips: [clip(.impact, 0.4, 1.0), clip(.follow, 1.0, 1.5)], strike: nil)
        track.moveStrike(from: 0.5, to: 0.7, duration: 2)
        XCTAssertEqual(track.strike, 0.7)
        XCTAssertEqual(track.clips[0].start, 0.6, accuracy: 1e-9, "The punch stays on the strike")
        XCTAssertEqual(track.clips[1].end, 1.7, accuracy: 1e-9)
        // Blocks stop at the end of the shot; the strike still goes where it was put.
        track.moveStrike(from: 0.7, to: 1.5, duration: 2)
        XCTAssertEqual(track.clips[1].end, 2, accuracy: 1e-9)
        XCTAssertEqual(track.clips[0].start, 0.9, accuracy: 1e-9)
        XCTAssertEqual(track.strike, 1.5)
    }

    func testMovingAndTrimmingStopAtNeighboursAndSnap() throws {
        var track = ShotCameraTrack()
        let a = track.insert(.impact, range: 0.2...0.6, duration: 3)
        let b = track.insert(.chase, range: 1.0...1.6, duration: 3)
        track.move(b, toStart: 0.3, duration: 3)
        XCTAssertEqual(try XCTUnwrap(track.clip(b)).start, 0.6, accuracy: 0.0001, "A block slides up to its neighbour, never into it")
        track.move(b, toStart: 1.95, duration: 3, snaps: [2.53], within: 0.05)
        XCTAssertEqual(try XCTUnwrap(track.clip(b)).end, 2.53, accuracy: 0.0001, "Either edge snaps")
        track.trim(a, edge: .end, to: 0.21, duration: 3)
        XCTAssertEqual(try XCTUnwrap(track.clip(a)).length, ShotCameraTrack.minimumLength, accuracy: 0.0001)
        track.trim(a, edge: .start, to: -1, duration: 3)
        XCTAssertEqual(try XCTUnwrap(track.clip(a)).start, 0)
        track.trim(a, edge: .end, to: 0.48, duration: 3, snaps: [0.5], within: 0.03)
        XCTAssertEqual(try XCTUnwrap(track.clip(a)).end, 0.5, accuracy: 0.0001)
    }

    func testReplacingAMoveKeepsItsTimeAndResetsItsSettings() throws {
        var track = ShotCameraTrack()
        let id = track.insert(.ramp, range: 0.4...0.9, duration: 2)
        track.update(id) { $0.rate = 0.5 }
        track.replace(id, with: .replay)
        let clip = try XCTUnwrap(track.clip(id))
        XCTAssertEqual(clip.move, .replay)
        XCTAssertEqual(clip.start, 0.4); XCTAssertEqual(clip.end, 0.9)
        XCTAssertEqual(clip.settings, .defaults(for: .replay))
    }

    // MARK: Replay clock

    func testRampRoundTripsAndSlowsOnlyItsRange() {
        for rate in [0.25, 0.5, 1.0] {
            for smooth in [false, true] {
                let track = ShotCameraTrack(clips: [clip(.ramp, 1.3, 2.1) { $0.rate = rate; $0.smooth = smooth }])
                let timeline = ShotEditTimeline(track: track, duration: 4)
                for source in stride(from: 0.0, through: 4, by: 0.007) {
                    XCTAssertEqual(timeline.sourceTime(for: timeline.outputTime(for: source)), source, accuracy: 0.00001)
                }
                XCTAssertEqual(timeline.outputTime(for: 1), 1, accuracy: 0.00001)
                XCTAssertEqual(timeline.outputTime(for: 3.1) - timeline.outputTime(for: 3), 0.1, accuracy: 0.00001)
                XCTAssertEqual(timeline.outputTime(for: 1.71) - timeline.outputTime(for: 1.7), 0.01 / rate, accuracy: 0.00001)
            }
        }
    }

    func testFreezeHoldsOneFrameAndResumes() {
        let timeline = ShotEditTimeline(track: ShotCameraTrack(clips: [clip(.freeze, 1.2, 2) { $0.hold = 1.5 }]), duration: 4)
        XCTAssertEqual(timeline.outputDuration, 5.5, accuracy: 0.00001)
        XCTAssertEqual(timeline.sourceTime(for: 2.6), 1.2)
        XCTAssertEqual(timeline.sourceTime(for: 3), 1.5, accuracy: 0.00001)
        XCTAssertEqual(timeline.outputTime(for: 1.2), 1.2, accuracy: 0.00001)
        XCTAssertEqual(timeline.locate(2).segment.kind, .hold)
    }

    func testReplayPlaysThroughRewindsAndReplaysSlowly() {
        let timeline = ShotEditTimeline(track: ShotCameraTrack(clips: [clip(.replay, 1, 2) { $0.rate = 0.5 }]), duration: 3)
        let rewind = 1 / ShotEditTimeline.rewindSpeed
        XCTAssertEqual(timeline.outputDuration, 3 + rewind + 2, accuracy: 0.00001)
        XCTAssertEqual(timeline.locate(2 + rewind / 2).segment.kind, .rewind)
        XCTAssertEqual(timeline.sourceTime(for: 2 + rewind / 2), 1.5, accuracy: 0.00001, "The rewind runs backwards")
        XCTAssertTrue(timeline.locate(2 + rewind + 1).segment.isReplay)
        XCTAssertEqual(timeline.sourceTime(for: 2 + rewind + 1), 1.5, accuracy: 0.00001, "The replay runs at half speed")
        XCTAssertEqual(timeline.outputTime(for: 1.5), 1.5, accuracy: 0.00001, "Seeking finds the first pass")
        XCTAssertEqual(timeline.outputTime(for: 2.5), 2 + rewind + 2 + 0.5, accuracy: 0.00001)
    }

    func testSeveralTimeMovesStackInOrderAndStayInsideTheSource() {
        let track = ShotCameraTrack(clips: [clip(.ramp, 0.5, 0.7), clip(.freeze, 1, 1.4) { $0.hold = 0.8 },
                                            clip(.replay, 1.5, 2) { $0.rate = 0.25 }])
        let timeline = ShotEditTimeline(track: track, duration: 2.4)
        for source in stride(from: 0.0, through: 2.4, by: 0.011) {
            XCTAssertEqual(timeline.sourceTime(for: timeline.outputTime(for: source)), source, accuracy: 0.00001)
        }
        for output in stride(from: 0.0, through: timeline.outputDuration, by: 0.013) {
            XCTAssertGreaterThanOrEqual(timeline.sourceTime(for: output), 0)
            XCTAssertLessThanOrEqual(timeline.sourceTime(for: output), 2.4)
        }
        let order = timeline.segments.compactMap { $0.clip }.reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(order, track.clips.map(\.id))
    }

    func testAdjacentFramesUseActualVariableTimestampsAndClampAtEdges() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let frames = try await ShotSourceFrames.load(source)
        XCTAssertGreaterThan(frames.times.count, 10)
        let gaps = zip(frames.times, frames.times.dropFirst()).map { Int((($1 - $0) * 100_000).rounded()) }
        XCTAssertGreaterThan(Set(gaps).count, 1, "This fixture has variable source cadence")
        for i in 1..<frames.times.count - 1 {
            XCTAssertEqual(frames.adjacent(to: frames.times[i], by: -1), frames.times[i - 1])
            XCTAssertEqual(frames.adjacent(to: frames.times[i], by: 1), frames.times[i + 1])
            XCTAssertEqual(frames.frameDuration(at: frames.times[i]), frames.times[i + 1] - frames.times[i], accuracy: 0.00001)
        }
        XCTAssertEqual(frames.adjacent(to: 0, by: -1), frames.times.first)
        XCTAssertEqual(frames.adjacent(to: frames.duration, by: 1), frames.times.last)
    }

    func testVFRFreezeDecodesTheChosenSourcePixels() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let frames = try await ShotSourceFrames.load(source)
        func still(_ asset: AVAsset, _ time: Double) async throws -> [UInt8] {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 120, height: 120)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: time + 0.000001, preferredTimescale: 1_800_000_000)).image
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let picked = frames.times[frames.times.count / 2]
        let timeline = ShotEditTimeline(track: ShotCameraTrack(clips: [clip(.freeze, picked, frames.duration) { $0.hold = 1.3 }]),
                                        duration: frames.duration)
        let retimed = try await timeline.asset(source: source)
        let length = try await retimed.load(.duration).seconds
        XCTAssertEqual(length, timeline.outputDuration, accuracy: 0.0001)
        let reference = try await still(AVURLAsset(url: source), picked)
        for time in [picked + 0.15, picked + 1.1] {
            let held = try await still(retimed, time)
            XCTAssertEqual(held.count, reference.count)
            let mean = Double(zip(reference, held).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(reference.count)
            XCTAssertLessThan(mean, 1, "Hold the selected VFR frame, not a neighbouring sample")
        }
    }

    // MARK: Plan

    func testFollowLooksAtTheBallOnlyInsideItsBlock() {
        let plan = plan([clip(.follow, 0.8, 1.4)])
        let size = CGSize(width: 180, height: 320)
        XCTAssertFalse(plan.frame(output: 0.3, size: size).isActive, "No block, original framing")
        let inside = plan.frame(output: 1.1, size: size).uniforms[1]
        XCTAssertGreaterThan(inside.z, 1.2)
        XCTAssertEqual(Double(inside.x), 0.7, accuracy: 0.08)
        XCTAssertLessThan(Double(inside.y), 0.6, "The camera rises with the ball")
    }

    func testTiltPunchKeepsItsOriginalCurve() {
        let plan = plan([clip(.tilt, 0.44, 0.74) { $0.angle = 2.5 }])
        let size = CGSize(width: 180, height: 320)
        let peak = plan.frame(output: 0.59, size: size).uniforms[1]
        XCTAssertEqual(Double(peak.w), -2.5 * .pi / 180, accuracy: 0.0002, "Left by default, full angle in the middle")
        let half = plan.frame(output: 0.665, size: size).uniforms[1]
        XCTAssertEqual(Double(half.w), -2.5 * .pi / 180 * 0.5, accuracy: 0.0004, "(1 + cos) / 2 on each side")
    }

    func testRotatedCropsNeverReadOutsideThePicture() {
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            for move in [ShotCameraMove.tilt, .recoil] {
                let plan = plan([clip(move, 0.4, 0.9) { $0.angle = 8 }], aspect: Double(size.width / size.height))
                for output in stride(from: 0.4, through: 0.9, by: 0.02) {
                    let crop = plan.frame(output: output, size: size).uniforms[1], c = cos(Double(crop.w)), s = sin(Double(crop.w))
                    for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
                        let x = (corner.x - size.width / 2) / Double(crop.z), y = (corner.y - size.height / 2) / Double(crop.z)
                        let sx = (c * x + s * y) / size.width + Double(crop.x), sy = (-s * x + c * y) / size.height + Double(crop.y)
                        XCTAssertGreaterThanOrEqual(sx, -0.0001); XCTAssertLessThanOrEqual(sx, 1.0001)
                        XCTAssertGreaterThanOrEqual(sy, -0.0001); XCTAssertLessThanOrEqual(sy, 1.0001)
                    }
                }
            }
        }
    }

    func testFlightEndsWhereTheBallTurnsBackNotAtTheLastSighting() {
        func ball(_ position: (Double) -> (x: Double, y: Double)) -> BallEffectTrack {
            BallEffectTrack(frames: (0...150).map { i in
                let t = Double(i) / 60, p = position(t)
                return RecordedFrame(time: t, x: p.x, y: p.y, width: 0.03, height: 0.017, score: 0.9, smoothedX: p.x, smoothedY: p.y,
                                     vy: 0, motion: .unknown, detected: true, person: nil)
            })
        }
        // Up and right into the net until 1.4 s, then a roll back to the left.
        let rollBack = ball { t in
            let f = min(1, max(0, (t - 0.5) / 0.9)), back = max(0, t - 1.4)
            return (0.6 + 0.12 * f - 0.3 * back, 0.75 - 0.35 * f + 0.05 * back)
        }
        let net = plan([], ball: rollBack, duration: 2.5).flightEnd
        XCTAssertEqual(net, 1.4, accuracy: 0.08)
        // A lob that climbs and falls is still flying when it comes down.
        let lob = ball { t in
            let f = min(1, max(0, (t - 0.5) / 1.1))
            return (0.5 + 0.1 * f, 0.75 - 1.2 * f + 1.0 * f * f)
        }
        XCTAssertEqual(plan([], ball: lob, duration: 2.5).flightEnd, 1.7, accuracy: 0.001)
        // A bounce ends the flight where the ball meets the ground.
        let bounce = ball { t in
            let f = max(0, t - 0.5)
            return (0.5 + 0.05 * f, f < 0.8 ? 0.75 - 0.6 * f + 0.75 * f * f : 0.75 - 0.6 * 0.8 + 0.75 * 0.64 - 0.3 * (f - 0.8))
        }
        XCTAssertEqual(plan([], ball: bounce, duration: 2.5).flightEnd, 1.3, accuracy: 0.08)
    }

    func testStampsWaitForTheirSpriteSheet() {
        let plan = plan([clip(.strobe, 0.5, 1.5)])
        XCTAssertFalse(plan.stamps.isEmpty)
        let frame = plan.frame(output: 1.2, size: CGSize(width: 180, height: 320))
        XCTAssertGreaterThan(frame.uniforms[17].x, 0)
        XCTAssertEqual(frame.uniforms(hasAtlas: false)[17].x, 0, "Without the sheet, stamps would sample another picture")
        XCTAssertEqual(frame.uniforms(hasAtlas: true), frame.uniforms)
    }

    func testFreezeDrawsItsPathDuringTheHold() {
        let plan = plan([clip(.freeze, 0.5, 1.3) { $0.hold = 1 }])
        let size = CGSize(width: 180, height: 320)
        let early = plan.frame(output: 0.6, size: size), late = plan.frame(output: 1.3, size: size)
        XCTAssertEqual(early.path.count, ShotCameraFrame.pathCount)
        XCTAssertLessThan(early.uniforms[14].x, late.uniforms[14].x, "The path draws itself on")
        XCTAssertGreaterThan(early.uniforms[4].z, 0, "The frozen frame dims")
        let flying = plan.frame(output: 1.8, size: size)
        XCTAssertEqual(flying.uniforms[14].x, 1)
        XCTAssertEqual(flying.uniforms[4].z, 0)
        XCTAssertGreaterThan(flying.uniforms[14].y, 0, "The path stays while the ball flies along it")
    }

    func testReplayShowsRewindAndReplayCaptions() {
        let plan = plan([clip(.replay, 0.5, 1.2) { $0.rate = 0.5 }])
        let size = CGSize(width: 180, height: 320)
        XCTAssertTrue(plan.frame(output: 0.8, size: size).captions.isEmpty, "First pass plays as recorded")
        let rewind = plan.frame(output: 1.25, size: size)
        XCTAssertTrue(rewind.captions.contains { $0.text.contains("REWIND") })
        XCTAssertEqual(rewind.uniforms[15].x, 1)
        let replay = plan.frame(output: 1.2 + 0.7 / ShotEditTimeline.rewindSpeed + 0.4, size: size)
        XCTAssertTrue(replay.captions.contains { $0.text.contains("REPLAY") })
        XCTAssertGreaterThan(replay.uniforms[1].z, 1, "The replay chases the ball")
    }

    func testMovesEaseBackToTheOriginalUnlessTheyCut() throws {
        let size = CGSize(width: 180, height: 320)
        /// Nothing left on screen: no crop, shake, grade, layout, overlay or caption.
        func isOriginal(_ f: ShotCameraFrame) -> Bool {
            let u = f.uniforms
            let layout = u[0].z == 6 || u[0].z == 7
            let crop = layout ? u[13].y > 0.99 : abs(u[1].x - 0.5) < 0.01 && abs(u[1].y - 0.5) < 0.01 && abs(u[1].z - 1) < 0.01 && abs(u[1].w) < 0.001
            return crop && abs(u[3].x) < 0.5 && abs(u[3].y) < 0.5 && u[3].z < 0.5
                && u[4].x < 0.01 && u[4].y < 0.01 && u[4].z < 0.01 && u[6].z < 0.002 && u[7].w < 0.01 && u[8].z < 0.002
                && u[9].w < 0.01 && u[10].w < 0.01 && (layout || u[12].x < 0.01) && u[14].y < 0.01 && u[15].w < 0.01
                && f.captions.allSatisfy { $0.alpha < 0.02 }
        }
        for move in ShotCameraMove.allCases where ![.tilt, .replay, .arc, .slowmo].contains(move) {
            let eased = plan([clip(move, 0.4, 1.4)])
            let middle = eased.frame(output: eased.timeline.outputTime(for: 0.9), size: size)
            XCTAssertFalse(isOriginal(middle), "\(move.title) shows inside its block")
            let last = eased.frame(output: eased.timeline.outputTime(for: 1.4 - 0.001), size: size)
            XCTAssertTrue(isOriginal(last), "\(move.title) lands on the original picture at its last frame")
            // Halfway through the ending it is still on its way back, not already gone. (Hits have
            // mostly played out by then on their own.)
            if !move.isMoment {
                let release = ShotMoveSettings.release(length: 1)
                let easing = eased.frame(output: eased.timeline.outputTime(for: 1.4 - release / 2), size: size)
                XCTAssertFalse(isOriginal(easing), "\(move.title) eases back instead of snapping")
            }
            let first = eased.frame(output: eased.timeline.outputTime(for: 0.4 + 0.001), size: size)
            if move == .duo || move == .split { XCTAssertTrue(isOriginal(first), "\(move.title) opens out of the original picture") }
        }
        // A replay eases out of its slow pass into the action.
        let replay = plan([clip(.replay, 0.4, 1.4)])
        let pass = try XCTUnwrap(replay.timeline.segments.first { $0.isReplay })
        XCTAssertFalse(isOriginal(replay.frame(output: pass.outputStart + pass.outputLength / 2, size: size)), "The replay pass is zoomed")
        XCTAssertTrue(isOriginal(replay.frame(output: pass.outputEnd - 0.001, size: size)), "Instant Replay eases out of its slow pass")
        let cut = plan([clip(.follow, 0.4, 1.4) { $0.ending = .cut }])
        XCTAssertGreaterThan(cut.frame(output: 1.4 - 0.001, size: size).uniforms[1].z, 1.05, "Cut keeps the move until the block's last frame")
        XCTAssertTrue(ShotMoveSettings.controls(for: .follow).contains(.ending))
        XCTAssertFalse(ShotMoveSettings.controls(for: .tilt).contains(.ending), "Tilt Punch keeps its own ending")
    }

    func testSlowMotionLandsWhereYouAreAndOnlySlowsTime() {
        // Added with the playhead at 1.6 s: half a second around it, nowhere near the strike.
        let range = ShotCameraMove.slowmo.defaultRange(strike: 0.5, flightEnd: 1.3, playhead: 1.6, duration: 2.5)
        XCTAssertEqual(range.lowerBound, 1.35, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 1.85, accuracy: 0.001)
        var track = ShotCameraTrack()
        let id = track.insert(.slowmo, range: range, duration: 2.5)
        // Stretched by its edge like any block.
        track.trim(id, edge: .end, to: 2.2, duration: 2.5, snaps: [], within: 0)
        let clip = try! XCTUnwrap(track.clip(id))
        XCTAssertEqual(clip.end, 2.2, accuracy: 0.001)
        let timeline = ShotEditTimeline(track: track, duration: 2.5)
        // Four times slower, less a little for easing in and out.
        let extra = clip.length / clip.settings.rate - clip.length
        XCTAssertGreaterThan(timeline.outputDuration, 2.5 + extra * 0.6, "The block plays slower")
        XCTAssertLessThanOrEqual(timeline.outputDuration, 2.5 + extra + 0.001)
        XCTAssertFalse(ShotSlowMotion.stretches(in: timeline, track: track).isEmpty, "with smooth frames where the device can")
        // Time only: the picture stays the recording's own.
        let plan = ShotCameraPlan(track: track, ball: flight(), flight: nil, duration: 2.5, aspect: 9.0 / 16)
        XCTAssertFalse(plan.frame(output: timeline.outputTime(for: 1.8), size: CGSize(width: 180, height: 320)).isActive)
        XCTAssertFalse(ShotMoveSettings.controls(for: .slowmo).contains(.ending))
    }

    func testFrozenArcSwingsAroundTheKickerAndReturnsToTheRealView() throws {
        let plan = plan([clip(.arc, 0.5, 0.8)])
        let hold = try XCTUnwrap(plan.timeline.segments.first { $0.kind == .hold })
        XCTAssertEqual(hold.outputLength, 2.4, accuracy: 0.001)
        let size = CGSize(width: 180, height: 320)
        func frame(_ progress: Double) -> ShotCameraFrame { plan.frame(output: hold.outputStart + hold.outputLength * progress, size: size) }
        XCTAssertEqual(frame(0.001).uniforms[0].z, 8)
        XCTAssertEqual(frame(0.001).uniforms[20].y, 0, accuracy: 0.001, "It starts on the real view")
        XCTAssertEqual(frame(0.999).uniforms[20].y, 0, accuracy: 0.001, "It ends on the real view")
        XCTAssertGreaterThan(abs(frame(0.3).uniforms[20].y), 0.1, "It swings round the kicker")
        XCTAssertLessThan(frame(0.3).uniforms[20].y * frame(0.7).uniforms[20].y, 0, "and through to the other side")
        XCTAssertEqual(frame(0.5).uniforms(hasAtlas: false)[0].z, 1, "Without its layers it stays a plain freeze")
        XCTAssertEqual(plan.frame(output: hold.outputEnd + 0.1, size: size).uniforms[0].z, 0, "It plays as recorded after the hold")
        XCTAssertEqual(plan.arcMoment, 0.5)
        XCTAssertGreaterThan(plan.arcScene.backdropDepth, plan.arcScene.kickerDepth, "The backdrop stands behind the kicker")
        XCTAssertGreaterThan(plan.arcScene.cameraHeight, 0)
    }

    func testFrozenArcOnlyShowsWhatThePhoneFilmed() {
        // Your Power Shot's scene: the phone low on the grass, the kicker 2.5 m away, the goal 12 m.
        let scene = ShotArcScene(focal: 1.337, horizon: 0.76, pivotX: 0.45, cameraHeight: 0.44,
                                 kickerDepth: 2.5, backdropDepth: 12.3, fitted: true)
        let width = 720.0, height = 1280.0
        let limit = scene.coveredSwing(upTo: 12 * .pi / 180, width: width, height: height)
        XCTAssertGreaterThan(limit, 4 * .pi / 180, "Still a real swing")
        for k in 0...40 {
            let p = Double(k) / 40, swing = limit * sin(2 * .pi * p)
            let view = scene.view(swing: swing, push: 1 + 0.1 * sin(.pi * p), width: width, height: height)
            let out = scene.overflow(of: view, width: width, height: height)
            XCTAssertLessThan(out.left + out.right + out.top + out.bottom, 1, "At \(p) the view needs no invented edge")
            XCTAssertLessThanOrEqual(view.focal, scene.focal * width * 1.3 * 1.11, "and zooms in only a little")
        }
        let still = scene.view(swing: 0, push: 1, width: width, height: height)
        XCTAssertEqual(still.focal, scene.focal * width, accuracy: 0.001, "Unswung, it is the frozen frame itself")
        XCTAssertEqual(still.centerX, width / 2, accuracy: 0.001)
    }

    func testSmoothSlowMotionReplacesStretchedFramesWithItsOwn() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "power-shot-2.5s", withExtension: "mp4"))
        var track = ShotCameraTrack(clips: [clip(.ramp, 0.43, 0.91) { $0.rate = 0.25 }], strike: 0.57)
        let timeline = ShotEditTimeline(track: track, duration: 2.5)
        let slowed = ShotSlowMotion.stretches(in: timeline, track: track)
        XCTAssertFalse(slowed.isEmpty, "A Speed Ramp's slowed steps ask for smooth frames")
        XCTAssertTrue(slowed.allSatisfy { $0.length > $0.to - $0.from })
        // The Simulator cannot make in-between frames, so this render repeats them; everything around it is the same.
        let rendered = try await ShotSlowMotion.render(source: source, stretches: slowed, interpolate: false)
        let smooth = try XCTUnwrap(rendered)
        defer { try? FileManager.default.removeItem(at: smooth.movie) }
        XCTAssertTrue(smooth.covers(slowed, of: source))
        let asset = try await timeline.asset(source: source, smooth: smooth)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, timeline.outputDuration, accuracy: 0.02)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let picture = try XCTUnwrap(tracks.first as? AVCompositionTrack)
        XCTAssertEqual(picture.segments.filter { $0.sourceURL == smooth.movie }.count, slowed.count,
                       "Every slowed stretch shows the rendered frames")
        // Switched off, the block slows down by repeating frames, as before.
        track.update(track.clips[0].id) { $0.smoothMotion = false }
        XCTAssertTrue(ShotSlowMotion.stretches(in: ShotEditTimeline(track: track, duration: 2.5), track: track).isEmpty)
        XCTAssertTrue(ShotMoveSettings.controls(for: .ramp).contains(.smoothMotion))
        XCTAssertTrue(ShotMoveSettings.controls(for: .replay).contains(.smoothMotion))
        XCTAssertFalse(ShotMoveSettings.controls(for: .follow).contains(.smoothMotion))
    }

    func testSplitAndDuoUseTheirPanels() {
        let size = CGSize(width: 180, height: 320)
        let split = plan([clip(.split, 0.6, 1.4) { $0.alternate = true }]).frame(output: 1, size: size)
        XCTAssertEqual(split.uniforms[0].z, 6); XCTAssertEqual(split.uniforms[13].z, 1)
        XCTAssertEqual(split.captions.map(\.text), ["WIDE", "BALL CAM"])
        let duo = plan([clip(.duo, 0.4, 1.4)]).frame(output: 1, size: size)
        XCTAssertEqual(duo.uniforms[0].z, 7)
        XCTAssertEqual(duo.uniforms[13].y, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(duo.uniforms[16].z, 1, "The kicker panel frames the person box")
    }

    func testTouchingBlocksHandOverWithoutAJump() {
        let plan = plan([clip(.impact, 0.38, 1.0), clip(.chase, 1.0, 1.5)])
        let size = CGSize(width: 180, height: 320)
        var last = plan.frame(output: 0.95, size: size).uniforms[1]
        for output in stride(from: 0.95 + 1.0 / 60, through: 1.2, by: 1.0 / 60) {
            let crop = plan.frame(output: output, size: size).uniforms[1]
            XCTAssertLessThan(abs(crop.z - last.z), 0.25, "Zoom changes smoothly at \(output)")
            XCTAssertLessThan(abs(crop.x - last.x) + abs(crop.y - last.y), 0.08, "Framing changes smoothly at \(output)")
            last = crop
        }
    }

    // MARK: Rendering

    func testGPUFollowMovesTheBallsPixelsAndLensMagnifiesThem() throws {
        let engine = try MetalEffectEngine()
        let size = CGSize(width: 160, height: 90)
        let source = try engine.texture(width: 160, height: 90, storage: .shared)
        var bytes = [UInt8](repeating: 0, count: 160 * 90 * 4)
        for y in 0..<90 { for x in 0..<160 {
            let i = (y * 160 + x) * 4
            let white = abs(x - 120) < 4 && abs(y - 54) < 4
            bytes[i] = white ? 255 : 100; bytes[i + 1] = white ? 255 : 40; bytes[i + 2] = white ? 255 : 20; bytes[i + 3] = 255
        }}
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 640) }
        let target = try engine.texture(width: 160, height: 90, storage: .shared)
        let original = EffectFrame.shot(size: size, sourceSize: size, style: .none, intensity: 0, track: still(), time: 0.04)
        for move in [ShotCameraMove.follow, .lens] {
            let plan = ShotCameraPlan(track: ShotCameraTrack(clips: [clip(move, 0, 1)], strike: 0.01), ball: still(),
                                      flight: nil, duration: 1.2, aspect: 16.0 / 9)
            try engine.render(original, into: target, source: source, camera: plan.frame(output: 0.5, size: size))
            var output = bytes
            output.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 640, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0) }
            let white = (0..<(160 * 90)).filter { i in output[i * 4] > 230 && output[i * 4 + 1] > 230 && output[i * 4 + 2] > 230 }
            XCTAssertGreaterThan(white.count, 40)
            if move == .follow {
                let center = Double(white.map { $0 % 160 }.reduce(0, +)) / Double(white.count)
                XCTAssertLessThan(center, 105, "The ball's pixels move toward the centre")
            } else {
                XCTAssertTrue(white.contains { $0 % 160 < 70 && $0 / 160 < 45 }, "The ball is magnified in the lens at top left")
            }
        }
    }

    func testCPUAndMetalAgreeOnEveryMove() throws {
        let engine = try MetalEffectEngine()
        for size in [CGSize(width: 180, height: 320), CGSize(width: 320, height: 180)] {
            let w = Int(size.width), h = Int(size.height)
            func buffer() throws -> CVPixelBuffer {
                var buffer: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
                let pixels = try XCTUnwrap(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let i = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                    bytes[i] = UInt8(x * 240 / w); bytes[i + 1] = UInt8(y * 240 / h); bytes[i + 2] = 50; bytes[i + 3] = 255
                }}
                CVPixelBufferUnlockBaseAddress(pixels, [])
                return pixels
            }
            for move in ShotCameraMove.allCases where move != .focus {
                let plan = plan([clip(move, 0.3, 1.4)], aspect: Double(size.width / size.height))
                let output = move == .replay ? 1.4 + 1.1 / ShotEditTimeline.rewindSpeed + 0.5 : 0.75
                let camera = plan.frame(output: output, size: size)
                let frame = EffectFrame.shot(size: size, sourceSize: size, style: .none, intensity: 0, track: flight(), time: 0.75)
                let cpu = try buffer(), gpu = try buffer()
                // Frozen Arc's layers: a flat painted-out background and the kicker as an upright oval.
                let arc: ShotArcLayers? = move == .arc ? {
                    var bytes = [UInt8](repeating: 0, count: w * h * 4)
                    for y in 0..<h { for x in 0..<w {
                        let i = (y * w + x) * 4, dx = (Double(x) / Double(w) - 0.42) / 0.12, dy = (Double(y) / Double(h) - 0.55) / 0.25
                        bytes[i] = 40; bytes[i + 1] = 160; bytes[i + 2] = 90
                        bytes[i + 3] = dx * dx + dy * dy < 1 ? 255 : 0
                    }}
                    return ShotArcLayers(bytes: bytes, width: w, height: h, time: 0.3)
                }() : nil
                if move == .arc { XCTAssertEqual(camera.uniforms[0].z, 8, "\(size): the arc is rendered, not skipped") }
                try ShotCPURenderer.composite(frame, pixelBuffer: cpu, camera: camera, arc: arc)
                try engine.composite(frame, pixelBuffer: gpu, camera: camera, arc: arc)
                CVPixelBufferLockBaseAddress(cpu, .readOnly); CVPixelBufferLockBaseAddress(gpu, .readOnly)
                let a = CVPixelBufferGetBaseAddress(cpu)!.assumingMemoryBound(to: UInt8.self), b = CVPixelBufferGetBaseAddress(gpu)!.assumingMemoryBound(to: UInt8.self)
                var differences: [Int] = []
                for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                    differences.append(abs(Int(a[y * CVPixelBufferGetBytesPerRow(cpu) + x * 4 + c]) - Int(b[y * CVPixelBufferGetBytesPerRow(gpu) + x * 4 + c])))
                }}}
                CVPixelBufferUnlockBaseAddress(cpu, .readOnly); CVPixelBufferUnlockBaseAddress(gpu, .readOnly)
                differences.sort()
                XCTAssertLessThan(Double(differences.reduce(0, +)) / Double(differences.count), 1.5, "\(move) \(size): mean difference")
                XCTAssertLessThan(differences[differences.count * 99 / 100], 16, "\(move) \(size): 99th percentile")
            }
        }
    }
}
