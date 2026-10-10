//
//  ContentView.swift
//  kicklab
//
//  Two modes on purpose. Live is the product; File is the control that tells us
//  whether a wrong count comes from the camera plumbing or from the model and
//  counter, by running a known clip through the identical code path.
//

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video copied out of the photo library.
///
/// PhotosPicker hands back an opaque item, not a URL - the file lives outside the
/// app sandbox. This copies it somewhere readable; without that, AVAssetReader
/// gets a path it cannot open.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("juggledude-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copy.path)
            return PickedMovie(url: copy)
        }
    }
}

struct ContentView: View {
    var body: some View {
        // Home shell first. Live capture opens full-screen from Juggling / Train.
        // File import and model self-test stay below as lab scaffolding.
        RootShellView()
    }
}

// MARK: - File

struct FileView: View {
    @StateObject private var analyzer = VideoAnalyzer()
    @State private var picking = false
    @State private var photoItem: PhotosPickerItem?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("\(analyzer.touchCount)")
                .font(.system(size: 84, weight: .bold, design: .rounded))
                .monospacedDigit()

            // The diagnostics matter more than the count here. On a clip with no
            // ball, the lab reports 0 detections; if this path reports thousands,
            // the fault is in the Swift, not the model.
            VStack(alignment: .leading, spacing: 4) {
                row("frames read", "\(analyzer.framesRead)")
                row("ball detections", "\(analyzer.detections)")
                row("peak ball score", String(format: "%.3f", analyzer.peakScore))
                row("dropped as implausible", "\(analyzer.dropped)")
                row("status", analyzer.status.isEmpty ? "idle" : analyzer.status)
                if !name.isEmpty { row("file", name) }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            if analyzer.isRunning {
                ProgressView(value: analyzer.progress).padding(.horizontal)
            }

            VStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) { [isRunning = analyzer.isRunning] in
                    Text(isRunning ? "Analysing…" : "Choose from Photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(analyzer.isRunning)

                Button("Choose from Files") { picking = true }
                    .disabled(analyzer.isRunning)
            }
            .padding(.horizontal)

            Spacer()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            name = "loading…"
            Task {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self)
                    else {
                        name = "could not load that item"
                        return
                    }
                    name = movie.url.lastPathComponent
                    analyzer.analyse(url: movie.url)
                } catch {
                    name = "load failed: \(error.localizedDescription)"
                }
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result {
                name = url.lastPathComponent
                analyzer.analyse(url: url)
            }
        }
        .onDisappear { analyzer.cancel() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Preview layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

#Preview { ContentView() }


// MARK: - Self test

/// The model, on an image made in code. No camera, no video, no rotation.
///
/// Live and File share almost nothing except model I/O, and both report a ball in
/// nearly every frame at exactly 0.500 while the lab reports none on the same
/// footage. This isolates the one thing they do share.
struct SelfTestView: View {
    @State private var result: SelfTestResult?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Model self-test")
                .font(.headline)
            Text("Runs the selected detector on a flat grey image without using the camera.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let r = result {
                VStack(alignment: .leading, spacing: 4) {
                    row("ball score", String(format: "%.4f", r.ballScore))
                    row("expected", String(format: "%.4f", SelfTest.expectedGreyBallScore))
                    row("person score", String(format: "%.4f", r.personScore))
                    Divider()
                    row("ball box", r.ballBox)
                    row("output values", "\(r.outputCount)")
                    row("shape", r.shape)
                    row("strides", r.strides)
                    row("dataType", r.dataType)
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                Text(r.notes)
                    .font(.footnote)
                    .foregroundStyle(r.notes.hasPrefix("matches") ? .green : .red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }

            Button("Run self-test") {
                do {
                    result = try SelfTest.runGrey()
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
