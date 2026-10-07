import Foundation

/// Exercise the same bounded preparer as the iOS sheet, including cancellation.
@main struct CheckStadiumPreview {
    static func main() async throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath:args[1]), track = URL(fileURLWithPath:args[2])
        let report = try JSONSerialization.jsonObject(with:Data(contentsOf:track)) as! [String:Any]
        let observations = (report["track"] as! [[String:Double]]).map {
            StadiumBallObservation(time:$0["time"]!,bounds:CGRect(x:$0["x"]!-$0["width"]!/2,
                y:$0["y"]!-$0["height"]!/2,width:$0["width"]!,height:$0["height"]!),confidence:$0["score"]!)
        }
        let shouldCancel = args.contains("--cancel")
        let temp = FileManager.default.temporaryDirectory
        func pendingFolders() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath:temp.path).filter { $0.hasPrefix("kicklab-stadium-preview-") })
        }
        let before = try pendingFolders()
        let start = Date()
        do {
            let result = try await Task.detached {
                try await StadiumPreviewPreparer.prepare(source:source,observations:observations,library:args[3],temporalRefinement: !args.contains("--no-temporal")) { value in
                    if shouldCancel, value > 0.14 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value
            defer { result.removeFiles() }
            guard !shouldCancel else { fatalError("Cancellation was ignored") }
            let destination = URL(fileURLWithPath:args[4])
            try FileManager.default.copyItem(at:result.folder,to:destination)
            print("READY \(result.frames) frames, \(result.duration) seconds, \(result.size), elapsed \(Date().timeIntervalSince(start))")
        } catch is CancellationError {
            guard shouldCancel else { throw CancellationError() }
            // Another independent review can finish and remove its own folder
            // during this check; only newly retained folders indicate a leak.
            guard try pendingFolders().subtracting(before).isEmpty else { fatalError("Cancellation left partial preview files") }
            print("CANCELLED: partial files removed; no successful preview returned.")
        }
    }
}
