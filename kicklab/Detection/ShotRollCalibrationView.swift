import SwiftUI
import UIKit
import simd

struct ShotRollCalibrationSnapshot: Identifiable {
    let id = UUID()
    let image: UIImage
    let png: Data
    let imageSize: CGSize
    let rotation: ShotRollRotation
    let intrinsics: simd_float3x3
    let camera: simd_float4x4
    let floor: ShotRollFloor
    let timestamp: Double
}

struct ShotRollCalibrationView: View {
    let snapshot: ShotRollCalibrationSnapshot
    let apply: (ShotRollCalibration) throws -> Void
    let cancel: () -> Void
    @State private var points: [CGPoint] = []
    @State private var spacing = "3.00"
    @State private var error: String?
    @State private var selectedPoint = 0
    @State private var retapPoint: Int?
    @FocusState private var spacingFocused: Bool

    private var fit: Result<ShotRollCalibration, Error> {
        Result {
            try ShotRollCalibration.fit(sensorPoints: points,
                referenceDistanceM: Float(spacing.replacingOccurrences(of: ",", with: ".")) ?? .nan,
                imageSize: snapshot.imageSize, intrinsics: snapshot.intrinsics,
                camera: snapshot.camera, floor: snapshot.floor, timestamp: snapshot.timestamp)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 16) {
                        photoControls
                        VStack(spacing: 12) {
                            ScrollView { VStack(spacing: 16) { precisionControls; valueControls } }
                            applyControl
                        }
                            .frame(width: min(340, geometry.size.width * 0.43))
                    }
                } else {
                    VStack(spacing: 12) { photoControls; precisionControls; valueControls; applyControl }
                }
            }.padding(16)
                .navigationTitle("Calibrate distance").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer(); Button("Done") { spacingFocused = false }
                    }
                }
        }.interactiveDismissDisabled()
    }

    private var photoControls: some View {
        VStack(spacing: 10) {
            Text(retapPoint.map { "Tap the centre of paper \($0 == 0 ? "A" : "B") again." } ?? (points.isEmpty ? "Tap the centre of the near paper (A)." :
                points.count == 1 ? "Now tap the centre of the far paper (B)." : "Check A and B, then enter their tape-measured spacing.")
            )
                .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                .frame(minHeight: 40)
                .accessibilityIdentifier("calibration-instruction")
            Text("Frozen photo • pinch to zoom • keep the phone fixed")
                .font(.caption).foregroundStyle(.secondary)
            CalibrationPhoto(snapshot: snapshot, sensorPoints: points) { upright in
                spacingFocused = false
                if let index = retapPoint {
                    points[index] = snapshot.rotation.sensorPoint(upright)
                    selectedPoint = index; retapPoint = nil
                } else if points.count < 2 {
                    points.append(snapshot.rotation.sensorPoint(upright))
                    selectedPoint = points.count - 1
                }
                error = nil
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Label("\(points.count) of 2 centres selected", systemImage: "scope")
                    .font(.caption).accessibilityIdentifier("calibration-point-count")
                Spacer()
                Button("Undo tap") {
                    if !points.isEmpty { points.removeLast() }
                    selectedPoint = max(0, points.count - 1); retapPoint = nil; error = nil
                }
                    .disabled(points.isEmpty).accessibilityIdentifier("calibration-undo")
            }
        }
    }

    private var precisionControls: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Inspect centre").font(.caption.weight(.semibold))
                ForEach(0..<2) { index in
                    Button(index == 0 ? "A" : "B") {
                        selectedPoint = index; retapPoint = nil
                    }.buttonStyle(.bordered)
                        .tint(selectedPoint == index && index < points.count ? .orange : .secondary)
                        .disabled(index >= points.count)
                        .accessibilityIdentifier("calibration-adjust-\(index == 0 ? "A" : "B")")
                }
                Spacer(minLength: 0)
                Button(retapPoint == nil ? "Retap" : "Cancel retap") {
                    retapPoint = retapPoint == nil ? selectedPoint : nil
                }.font(.caption).disabled(points.isEmpty)
                    .accessibilityIdentifier("calibration-retap")
            }
            HStack(spacing: 12) {
                CalibrationPointLoupe(snapshot: snapshot,
                    point: selectedPoint < points.count ? points[selectedPoint] : nil,
                    pointName: selectedPoint == 0 ? "A" : "B")
                    .frame(maxWidth: .infinity).frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(spacing: 0) {
                    nudgeButton(.up, icon: "arrow.up", name: "up")
                    HStack(spacing: 0) {
                        nudgeButton(.left, icon: "arrow.left", name: "left")
                        Image(systemName: "scope").foregroundStyle(.secondary).frame(width: 24)
                        nudgeButton(.right, icon: "arrow.right", name: "right")
                    }
                    nudgeButton(.down, icon: "arrow.down", name: "down")
                }
            }
            Text("Use the arrows to align the crosshair with the paper centre.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func nudgeButton(_ direction: ShotRollCalibrationPointEditing.Direction,
                             icon: String, name: String) -> some View {
        Button {
            guard selectedPoint < points.count,
                  let adjusted = ShotRollCalibrationPointEditing.nudged(points[selectedPoint],
                    direction: direction, imageSize: snapshot.imageSize, rotation: snapshot.rotation) else { return }
            points[selectedPoint] = adjusted; error = nil; spacingFocused = false
        } label: {
            Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle())
        }.disabled(points.isEmpty || retapPoint != nil)
            .accessibilityLabel("Move selected centre \(name)")
            .accessibilityIdentifier("calibration-nudge-\(name)")
    }

    private var valueControls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Paper spacing")
                Spacer()
                TextField("Metres", text: $spacing)
                    .keyboardType(.decimalPad).focused($spacingFocused)
                    .multilineTextAlignment(.trailing).frame(width: 90)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("calibration-spacing")
                Text("m")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("calibration-error")
            } else if points.count == 2 {
                switch fit {
                case .success(let result):
                    Text(String(format: "Scanned spacing %.2f m → use %.2f m", result.originalSpanM, result.referenceDistanceM))
                        .font(.caption).accessibilityIdentifier("calibration-fit-summary")
                case .failure(let failure):
                    Text(failure.localizedDescription).font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Both papers must lie on the same level floor. After calibration, check separate 1 m and 2 m marks. Matching these two papers alone does not verify accuracy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applyControl: some View {
        Button("Use calibration") {
            do { try apply(fit.get()) }
            catch let failure { error = failure.localizedDescription }
        }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            .disabled(points.count != 2 || retapPoint != nil || (try? fit.get()) == nil)
            .accessibilityIdentifier("calibration-apply")
    }

}

private struct CalibrationPointLoupe: UIViewRepresentable {
    let snapshot: ShotRollCalibrationSnapshot
    let point: CGPoint?
    let pointName: String

    func makeUIView(context: Context) -> CalibrationPointLoupeView { CalibrationPointLoupeView() }
    func updateUIView(_ view: CalibrationPointLoupeView, context: Context) {
        view.image = snapshot.image
        view.photoSize = ShotRollCalibrationPointEditing.uprightSize(snapshot.imageSize, rotation: snapshot.rotation)
        view.point = point.map { ShotRollCalibrationPointEditing.uprightPoint($0, rotation: snapshot.rotation) }
        view.accessibilityLabel = point == nil ? "Select a paper centre to magnify" : "Magnified paper centre \(pointName)"
        view.setNeedsDisplay()
    }
}

/// A small viewport into the existing captured image; no second image/model load.
final class CalibrationPointLoupeView: UIView {
    var image: UIImage?
    var photoSize = CGSize(width: 1, height: 1)
    var point: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; isOpaque = true; isAccessibilityElement = true
        accessibilityIdentifier = "calibration-loupe"; accessibilityTraits = .image
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        UIColor.black.setFill(); UIRectFill(bounds)
        guard let point, let image else {
            let text = "Tap a paper to inspect it here."
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: max(4, bounds.midX - size.width / 2), y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        let zoom: CGFloat = 5
        let size = CGSize(width: photoSize.width * zoom, height: photoSize.height * zoom)
        UIGraphicsGetCurrentContext()?.interpolationQuality = .none
        image.draw(in: CGRect(x: bounds.midX - point.x * size.width,
                              y: bounds.midY - point.y * size.height, width: size.width, height: size.height))
        let path = UIBezierPath()
        let x = bounds.midX, y = bounds.midY
        path.move(to: CGPoint(x: x - 22, y: y)); path.addLine(to: CGPoint(x: x - 4, y: y))
        path.move(to: CGPoint(x: x + 4, y: y)); path.addLine(to: CGPoint(x: x + 22, y: y))
        path.move(to: CGPoint(x: x, y: y - 22)); path.addLine(to: CGPoint(x: x, y: y - 4))
        path.move(to: CGPoint(x: x, y: y + 4)); path.addLine(to: CGPoint(x: x, y: y + 22))
        UIColor.black.setStroke(); path.lineWidth = 3; path.stroke()
        UIColor.systemYellow.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Zoom the actual captured pixels, without requesting another camera or model.
private struct CalibrationPhoto: UIViewRepresentable {
    let snapshot: ShotRollCalibrationSnapshot
    let sensorPoints: [CGPoint]
    let tap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(tap: tap) }
    func makeUIView(context: Context) -> CalibrationScrollView {
        let view = CalibrationScrollView()
        view.canvas.imageView.image = snapshot.image
        view.photoSize = ShotRollCalibrationPointEditing.uprightSize(snapshot.imageSize, rotation: snapshot.rotation)
        view.delegate = context.coordinator
        view.canvas.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return view
    }
    func updateUIView(_ view: CalibrationScrollView, context: Context) {
        context.coordinator.tap = tap
        // sensorPoint is the inverse rotation; use the opposite rotation here.
        view.canvas.points = sensorPoints.map { ShotRollCalibrationPointEditing.uprightPoint($0, rotation: snapshot.rotation) }
        view.canvas.setNeedsDisplay()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var tap: (CGPoint) -> Void
        init(tap: @escaping (CGPoint) -> Void) { self.tap = tap }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? CalibrationScrollView)?.canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? CalibrationScrollView)?.centrePhoto() }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let canvas = recognizer.view, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
            let p = recognizer.location(in: canvas)
            guard canvas.bounds.contains(p) else { return }
            tap(CGPoint(x: p.x / canvas.bounds.width, y: p.y / canvas.bounds.height))
        }
    }
}

private final class CalibrationScrollView: UIScrollView {
    let canvas = CalibrationCanvas()
    var photoSize = CGSize(width: 4, height: 3)
    private var fittedSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; minimumZoomScale = 1; maximumZoomScale = 12
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if fittedSize != bounds.size, bounds.width > 0, bounds.height > 0 {
            fittedSize = bounds.size; zoomScale = 1
            let scale = min(bounds.width / photoSize.width, bounds.height / photoSize.height)
            canvas.frame = CGRect(origin: .zero, size: CGSize(width: photoSize.width * scale, height: photoSize.height * scale))
            contentSize = canvas.frame.size
        }
        centrePhoto()
    }
    func centrePhoto() {
        canvas.center = CGPoint(x: max(bounds.width, contentSize.width) / 2,
                                y: max(bounds.height, contentSize.height) / 2)
    }
}

private final class CalibrationCanvas: UIView {
    let imageView = UIImageView()
    var points: [CGPoint] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleToFill; addSubview(imageView)
        isAccessibilityElement = true; accessibilityLabel = "Frozen floor photo. Tap the paper centres."
        accessibilityIdentifier = "calibration-canvas"; accessibilityTraits = .image
        backgroundColor = .clear; isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); imageView.frame = bounds; setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        // The overlay is drawn above the UIImageView using a shape layer below.
        let overlay = layer.sublayers?.first(where: { $0.name == "paper-centres" }) as? CAShapeLayer ?? CAShapeLayer()
        overlay.name = "paper-centres"; overlay.frame = bounds
        let path = UIBezierPath()
        let positions = points.map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
        if positions.count == 2 { path.move(to: positions[0]); path.addLine(to: positions[1]) }
        for point in positions {
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)))
            path.move(to: CGPoint(x: point.x - 12, y: point.y)); path.addLine(to: CGPoint(x: point.x + 12, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - 12)); path.addLine(to: CGPoint(x: point.x, y: point.y + 12))
        }
        overlay.path = path.cgPath; overlay.strokeColor = UIColor.systemYellow.cgColor
        overlay.fillColor = UIColor.clear.cgColor; overlay.lineWidth = 1.5
        if overlay.superlayer == nil { layer.addSublayer(overlay) }
        layer.sublayers?.filter { $0.name == "paper-label" }.forEach { $0.removeFromSuperlayer() }
        for (index, point) in positions.enumerated() {
            let label = CATextLayer(); label.name = "paper-label"; label.string = index == 0 ? "A" : "B"
            label.fontSize = 14; label.alignmentMode = .center; label.contentsScale = window?.screen.scale ?? 2
            label.foregroundColor = UIColor.black.cgColor; label.backgroundColor = UIColor.systemYellow.cgColor
            label.cornerRadius = 4; label.frame = CGRect(x: point.x + 10, y: point.y - 24, width: 22, height: 22)
            layer.addSublayer(label)
        }
    }
}
