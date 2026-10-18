#if DEBUG
import AVFoundation
import Foundation

nonisolated enum SelectiveEffectsValidation {
    @MainActor static func run(folder: URL, full: Bool) async throws -> [String: Any] {
        let source = folder.appendingPathComponent("source.mov")
        let frames = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf:folder.appendingPathComponent("track.plist"))).map(\.frame)
        let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("touches.json"))) as! [[Double]]
        let touches = rows.map { RecordedTouch(index:Int($0[0]),time:$0[1],x:$0[2],y:$0[3]) }
        let duration = try await AVURLAsset(url:source).load(.duration).seconds
        var summary = SessionSummary.make(touches:touches.count,duration:duration,bestCombo:touches.count,
            personalBest:touches.count,videoURL:source,touchesMarked:touches,track:frames)
        summary.needsVisualPreparation = true
        let preparation = SessionEffectsPreparation(), start = ProcessInfo.processInfo.systemUptime
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        let ready: SessionSummary
        if full { ready = try await preparation.prepare(summary) }
        else { ready = try await preparation.prepare(summary,for:SessionEditState(style:.fire)) }
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        guard ready.touches == summary.touches && ready.touchesMarked == summary.touchesMarked else { throw NSError(domain:"ChangedCounter",code:1) }
        let data = try SessionAnalysisStore.frameData(ready.renderTrack)
        try data.write(to:folder.appendingPathComponent("visual-track.plist"))
        let plan = SelectiveEffectTrack.plan(frames:frames,duration:duration)
        var report: [String:Any] = ["full":full,"elapsed_seconds":elapsed,"duration":duration,
            "positions_only":ready.visualTrackIsPositionsOnly,"count":ready.touches,"touches_unchanged":true,
            "source_sha256":try SessionAnalysisStore.sourceDigest(source),"track_sha256":SessionAnalysisStore.digest(data),
            "input_frames":frames.count,"output_frames":ready.renderTrack.count,
            "repair_span_seconds":plan.seconds,"planned_rf_queries":plan.queries.count,"rejected_live_positions":plan.rejectedTimes.count,"repair_spans":plan.spans.map { [$0.start,$0.end] },
            "thermal_before":thermalBefore,"thermal_after":ProcessInfo.processInfo.thermalState.rawValue]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("preparation.json"))
        // The marker is supplied only for explicitly requested rendered comparisons.
        if FileManager.default.fileExists(atPath:folder.appendingPathComponent("render-fire").path) {
            var overlays = ExportOverlaySettings();overlays.counter.enabled=true;overlays.counter.style = .normal;overlays.showTimer=true;overlays.graph.enabled=false
            let begin = ProcessInfo.processInfo.systemUptime
            let output = try await BallStyleBurnIn.render(source:source,track:ready.renderTrack,style:.fire,skin:.original,
                intensity:0.85,shortEdge:1080,counter:ExportCounterTimeline(touches:touches,total:touches.count),overlays:overlays)
            try FileManager.default.copyItem(at:output,to:folder.appendingPathComponent("fire.mp4"))
            report["export_seconds"] = ProcessInfo.processInfo.systemUptime-begin
        }
        return report
    }
}
#endif
