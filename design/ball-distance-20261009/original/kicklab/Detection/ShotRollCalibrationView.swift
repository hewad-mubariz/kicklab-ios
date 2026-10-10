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
    @State private var showingSpanCheck = false
    @State private var checkedPoints: [CGPoint] = []
    @State private var checkedSpacing: Float = 1
    @State private var checkSavedOnPhone = false
    @FocusState private var spacingFocused: Bool

    private var fit: Result<ShotRollCalibration, Error> {
        Result {
            try ShotRollCalibration.fit(sensorPoints: points,
                referenceDistanceM: Float(spacing.replacingOccurrences(of: ",", with: ".")) ?? .nan,
                imageSize: snapshot.imageSize, intrinsics: snapshot.intrinsics,
                camera: snapshot.camera, floor: snapshot.floor, timestamp: snapshot.timestamp)
        }
    }

    private var spanCheck: ShotRollCalibration.SpanCheck? {
        guard let calibration = try? fit.get(), checkedPoints.count == 2 else { return nil }
        return try? calibration.checkSpan(sensorPoints: checkedPoints, referenceDistanceM: checkedSpacing)
    }

    private var validCheck: Bool {
        checkedPoints.isEmpty || spanCheck?.withinTolerance == true
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
            .onChange(of: points) { _, _ in checkSavedOnPhone = false }
            .onChange(of: spacing) { _, _ in checkSavedOnPhone = false }
            .sheet(isPresented: $showingSpanCheck) {
                if let calibration = try? fit.get() {
                    CalibrationSpanCheckView(snapshot: snapshot, calibration: calibration,
                        initialPoints: checkedPoints, initialSpacing: checkedSpacing) { points, spacing in
                        checkedPoints = points; checkedSpacing = spacing; checkSavedOnPhone = true
                        showingSpanCheck = false
                    } cancel: { showingSpanCheck = false }
                }
            }
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
                    VStack(spacing: 4) {
                        Text(String(format: "Your measured spacing: %.2f m", result.referenceDistanceM))
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("calibration-reference-summary")
                        Text(String(format: "Before correction: %.2f m (floor scan estimate)", result.originalSpanM))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("calibration-fit-summary")
                        Text("Tap Use calibration to apply your measured spacing to the rolling counter.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .failure(let failure):
                    Text(failure.localizedDescription).font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Both papers must lie on the same level floor. After calibration, check separate 1 m and 2 m marks. Matching these two papers alone does not verify accuracy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(checkedPoints.isEmpty ? "Check another measured gap" : "Edit gap check") { showingSpanCheck = true }
                .font(.caption).disabled(points.count != 2 || retapPoint != nil || (try? fit.get()) == nil)
                .accessibilityIdentifier("calibration-check-gap")
            if !checkedPoints.isEmpty {
                if checkSavedOnPhone {
                    Text("Gap check saved on this phone. No video needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("calibration-check-saved")
                }
                if let check = spanCheck {
                    Text(String(format: "Gap check: %.2f m estimated / %.2f m measured • %+.0f cm", check.estimatedDistanceM,
                                check.referenceDistanceM, check.errorM * 100))
                        .font(.caption.weight(.semibold)).foregroundStyle(check.withinTolerance ? Color.primary : .orange)
                        .accessibilityIdentifier("calibration-check-result")
                    if !check.withinTolerance {
                        Text("Scale mismatch. Retap the centres or scan the floor again before applying.")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("calibration-check-mismatch")
                    }
                } else {
                    Text("Recheck the separate gap after changing A or B.").font(.caption).foregroundStyle(.orange)
                }
                Button("Remove gap check") { checkedPoints = []; checkSavedOnPhone = false }.font(.caption)
                    .accessibilityIdentifier("calibration-check-remove")
            }
        }
    }

    private var applyControl: some View {
        Button("Use calibration") {
            do {
                var calibration = try fit.get()
                calibration.independentSpanCheck = spanCheck
                try apply(calibration)
            }
            catch let failure { error = failure.localizedDescription }
        }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            .disabled(points.count != 2 || retapPoint != nil || (try? fit.get()) == nil || !validCheck)
            .accessibilityIdentifier("calibration-apply")
    }

}

/// Reuses the existing frozen pixels; the check never refits the calibration.
private struct CalibrationSpanCheckView: View {
    let snapshot: ShotRollCalibrationSnapshot
    let calibration: ShotRollCalibration
    let save: ([CGPoint], Float) -> Void
    let cancel: () -> Void
    @State private var points: [CGPoint]
    @State private var spacing: String
    @State private var saveError: String?
    @FocusState private var spacingFocused: Bool

    init(snapshot: ShotRollCalibrationSnapshot, calibration: ShotRollCalibration,
         initialPoints: [CGPoint], initialSpacing: Float,
         save: @escaping ([CGPoint], Float) -> Void, cancel: @escaping () -> Void) {
        self.snapshot = snapshot; self.calibration = calibration; self.save = save; self.cancel = cancel
        _points = State(initialValue: initialPoints)
        _spacing = State(initialValue: String(format: "%.2f", initialSpacing))
    }
    private var distance: Float { Float(spacing.replacingOccurrences(of: ",", with: ".")) ?? .nan }
    private var result: Result<ShotRollCalibration.SpanCheck, Error> {
        Result { try calibration.checkSpan(sensorPoints: points, referenceDistanceM: distance) }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 16) {
                        photoControls
                        ScrollView { valueControls }.frame(width: min(340, geometry.size.width * 0.43))
                    }
                } else {
                    VStack(spacing: 12) { photoControls; valueControls }
                }
            }.padding(16)
                .navigationTitle("Check a measured gap").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { spacingFocused = false } }
                }
        }.interactiveDismissDisabled()
    }
    private var photoControls: some View {
        VStack(spacing: 12) {
                Text(points.isEmpty ? "Tap the first paper centre for your check." : points.count == 1 ?
                     "Now tap the second paper centre for your check." : "Enter the measured gap between these two centres.")
                    .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                Text("Same frozen photo • pinch to zoom • keep the phone fixed")
                    .font(.caption).foregroundStyle(.secondary)
                CalibrationPhoto(snapshot: snapshot, sensorPoints: points, accessibilityID: "span-check-canvas") { upright in
                    guard points.count < 2 else { return }
                    points.append(snapshot.rotation.sensorPoint(upright)); spacingFocused = false; saveError = nil
                }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("\(points.count) of 2 check centres selected").font(.caption)
                    Spacer()
                    Button("Undo tap") { if !points.isEmpty { points.removeLast() }; saveError = nil }
                        .disabled(points.isEmpty).accessibilityIdentifier("span-check-undo")
                }
        }
    }
    private var valueControls: some View {
        VStack(spacing: 12) {
                HStack {
                    Text("Measured gap")
                    Spacer()
                    TextField("Metres", text: $spacing).keyboardType(.decimalPad).focused($spacingFocused)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
                        .accessibilityIdentifier("span-check-spacing")
                    Text("m")
                }
                if points.count == 2 {
                    switch result {
                    case .success(let check):
                        Text(String(format: "Estimated %.2f m • measured %.2f m\nDifference %+.0f cm", check.estimatedDistanceM,
                                    check.referenceDistanceM, check.errorM * 100))
                            .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                            .foregroundStyle(check.withinTolerance ? Color.primary : .orange)
                            .accessibilityIdentifier("span-check-result")
                        Text(check.withinTolerance ? "Within the experimental tolerance for this gap. Speed accuracy still needs checking." :
                             "This calibration misses the measured gap. Retap the centres or scan the floor again.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
                    }
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("span-check-save-error")
                }
                Button("Save gap check") {
                    do {
                        let check = try result.get()
                        _ = try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
                            imagePNG: snapshot.png, rotation: snapshot.rotation)
                        save(points, distance)
                    } catch {
                        saveError = "The check could not be saved. Keep it open and try again. " + error.localizedDescription
                    }
                }
                    .buttonStyle(.borderedProminent).disabled((try? result.get()) == nil)
                    .accessibilityIdentifier("span-check-save")
        }
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
    var accessibilityID = "calibration-canvas"
    let tap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(tap: tap) }
    func makeUIView(context: Context) -> CalibrationScrollView {
        let view = CalibrationScrollView()
        view.canvas.imageView.image = snapshot.image
        view.canvas.accessibilityIdentifier = accessibilityID
        view.photoSize = ShotRollCalibrationPointEditing.uprightSize(snapshot.imageSize, rotation: snapshot.rotation)
        view.delegate = context.coordinator
        view.canvas.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return view
    }
    func updateUIView(_ view: CalibrationScrollView, context: Context) {
        context.coordinator.tap = tap
        view.canvas.accessibilityIdentifier = accessibilityID
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
