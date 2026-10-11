import AVFoundation

/// Both exporters preserve the timeline chosen by the editor. MOV retains the
/// Photos full-frame-rate playback intent that MP4 drops for 120/240 fps media.
nonisolated enum VideoExportFormat {
    static func fileType(fps: Float) -> AVFileType { fps > 60 ? .mov : .mp4 }
    static func fileExtension(fps: Float) -> String { fps > 60 ? "mov" : "mp4" }
    static func playbackIntent() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        item.dataType = kCMMetadataBaseDataType_UInt8 as String
        item.value = NSNumber(value: 1)
        return item
    }
}
