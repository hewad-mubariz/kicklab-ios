//
//  kicklabApp.swift
//  kicklab
//

import SwiftUI

@main
struct kicklabApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--shot-geometry-capture") {
                ShotGeometryCaptureView()
            } else if DetectorPhoneBenchmark.requested ||
                ProcessInfo.processInfo.arguments.contains("--detector-review") {
                RecordView()
            } else {
            #if DEBUG
            if let path = SessionDesignReview.argument("--effects-video") {
                EffectsVideoReview(url: SessionDesignReview.fileURL(path))
            } else if let screen = SessionDesignReview.requestedScreen {
                SessionDesignReview(screen: screen)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
            }
        }
    }
}
