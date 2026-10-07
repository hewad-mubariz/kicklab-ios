import AVFoundation
import Foundation
import Testing
@testable import kicklab

private final class SceneTestBundle {}

struct SceneExportTests {
    private var recording: StadiumSceneRecording {
        var camera = SceneCameraRig(aspect: 0.5, subjectHeight: 0.4, ground: SIMD2(0.5, 0.85))
        camera.movement = 0
        return StadiumSceneRecording(camera: camera, frames: [])
    }
    private var frame: RecordedFrame {
        .init(time: 2, x: 0.4, y: 0.6, width: 0.1, height: 0.05, score: 0.9,
            smoothedX: 0.4, smoothedY: 0.6, vy: 1, motion: .unknown, detected: true, person: nil)
    }

    @Test(arguments: PreviewEnvironment.allCases)
    func sceneIsAnEditAndItsCompleteFramingSurvivesPersistence(environment: PreviewEnvironment) throws {
        let selection = SceneSelection(environment: environment, look: SIMD2(0.2, -0.1), zoom: 1.2, followRecordedCamera: false)
        let decoded = try JSONDecoder().decode(SceneSelection.self, from: JSONEncoder().encode(selection))
        #expect(decoded == selection)
        let edit = SessionEditState(style: .none, intensity: 0, scene: selection)
        #expect(edit.isEdited)
        #expect(edit.label == environment.title)
        #expect(Set([selection, SceneSelection(environment: .indoorArena), SceneSelection(environment: .classicStadium)]).count == 3)
    }

    @Test func effectsFollowTheProjectedBallAndDisappearBehindCamera() {
        var selection = SceneSelection(environment: .indoorArena)
        let unchanged = selection.project([frame], in: recording)[0]
        #expect(abs(unchanged.x - frame.x) < 0.0001)
        #expect(abs(unchanged.y - frame.y) < 0.0001)
        #expect(abs(unchanged.width - frame.width) < 0.0001)
        selection.look.x = 0.1; selection.zoom = 1.2
        let projected = selection.project([frame], in: recording)[0]
        let rig = selection.camera(in: recording, at: frame.time)
        let expected = rig.project(rig.worldPoint(sourceUV: SIMD2(Float(frame.x), Float(frame.y))), at: frame.time)
        #expect(abs(projected.x - Double(expected.x)) < 0.0001)
        #expect(abs(projected.y - Double(expected.y)) < 0.0001)
        #expect(projected.width > frame.width)
        #expect(projected.time == frame.time)
        selection.look.x = .pi
        let hidden = selection.project([frame], in: recording)[0]
        #expect(!hidden.detected)
        #expect(BallEffectTrack(frames: [hidden]).sample(at: frame.time) == nil)
    }

    @Test func incompleteLegacyPreviewsCannotSilentlyExportATruncatedClip() {
        let url = URL(fileURLWithPath: "/unused.mp4")
        let preview = PreparedStadiumPreview(folder: url, original: url, locked: url, moving: url,
            duration: 12, sourceDuration: 19, frames: 360, size: CGSize(width: 64, height: 128), foreground: url, recording: recording)
        #expect(throws: (any Error).self) { try SceneMovieRenderer.validate(preview) }
    }

    @Test(arguments: [PreviewEnvironment.indoorArena, .urbanCourt, .forestCourt, .snowField, .beachField])
    func fullSceneAndRotatedCounterExportKeepFramesPastTwelveSeconds(environment: PreviewEnvironment) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scene-export-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let foreground = folder.appendingPathComponent("foreground.mp4")
        let movie = try PreviewMovie(url: foreground, size: CGSize(width: 128, height: 128))
        let buffer = try movie.buffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 0, CVPixelBufferGetBytesPerRow(buffer) * 128)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<14 { try await movie.append(buffer, time: CMTime(seconds: Double(index), preferredTimescale: 600)) }
        try await movie.finish(duration: CMTime(seconds: 14, preferredTimescale: 600))
        let audio = try #require(Bundle(for: SceneTestBundle.self).url(forResource: "scene-audio", withExtension: "m4a"))
        // New preparations retain only original + foreground; no baked stadium movies.
        let prepared = PreparedStadiumPreview(folder: folder, original: audio, locked: nil, moving: nil,
            duration: 14.000366, sourceDuration: 14.000366, frames: 14, size: CGSize(width: 64, height: 128), foreground: foreground, recording: recording)
        let scene = try await SceneMovieRenderer.render(prepared: prepared, selection: .init(environment: environment))
        var overlays = ExportOverlaySettings()
        overlays.counter.placement.rotation = 29
        let timeline = ExportCounterTimeline(touches: [RecordedTouch(index: 0, time: 13, x: 0.5, y: 0.5)], total: 1)
        let exported = try await BallStyleBurnIn.render(source: scene, track: [], style: .none, intensity: 0,
            shortEdge: 64, counter: timeline, overlays: overlays,preserveFrameTimes:true)
        defer { try? FileManager.default.removeItem(at: exported) }
        for url in [scene, exported] {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            #expect(abs(duration.seconds - 14) < 0.01)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let late = try await generator.image(at: CMTime(seconds: 13, preferredTimescale: 600))
            #expect(late.actualTime.seconds >= 13)
            #expect(late.image.width == 64 && late.image.height == 128)
        }
        let before = try await AVAssetImageGenerator(asset: AVURLAsset(url: scene)).image(at: CMTime(seconds: 13, preferredTimescale: 600)).image
        let after = try await AVAssetImageGenerator(asset: AVURLAsset(url: exported)).image(at: CMTime(seconds: 13, preferredTimescale: 600)).image
        #expect((before.dataProvider!.data! as Data) != (after.dataProvider!.data! as Data))
    }

    @Test func preparedSceneEffectsKeepExactFrameTimesWhenChangingResolution() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("scene-cadence-\(UUID())")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let source=folder.appendingPathComponent("source.mp4"),stamps:[Int64]=[0,1001,2002,3500,4501,9000]
        let movie=try PreviewMovie(url:source,size:CGSize(width:64,height:128),frameRate:59.94)
        for (i,stamp) in stamps.enumerated() {
            let pixels=try movie.buffer();CVPixelBufferLockBaseAddress(pixels,[])
            memset(CVPixelBufferGetBaseAddress(pixels)!,Int32(30+i*30),CVPixelBufferGetBytesPerRow(pixels)*128)
            CVPixelBufferUnlockBaseAddress(pixels,[])
            try await movie.append(pixels,time:CMTime(value:stamp,timescale:60_000))
        }
        try await movie.finish(duration:CMTime(value:10001,timescale:60_000))
        let exported=try await BallStyleBurnIn.render(source:source,track:[],style:.none,intensity:0,shortEdge:32,preserveFrameTimes:true)
        defer {try? FileManager.default.removeItem(at:exported)}
        let asset=AVURLAsset(url:exported),track=try await asset.loadTracks(withMediaType:.video)[0]
        #expect(try await track.load(.naturalSize)==CGSize(width:32,height:64))
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);#expect(reader.startReading())
        var actual:[Int64]=[]
        while let sample=output.copyNextSampleBuffer() {actual.append(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),timescale:60_000,method:.roundHalfAwayFromZero).value)}
        #expect(actual==stamps)
        #expect(reader.status == .completed)
    }
}
