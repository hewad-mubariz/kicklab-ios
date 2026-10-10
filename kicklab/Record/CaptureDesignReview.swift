#if DEBUG
import SwiftUI

/// Exercises the real controls without pretending the simulator has a camera.
struct CaptureDesignReview: View {
    @State private var state: CaptureControlState = .ready
    @State private var lastAction = "Ready"

    init(initialState: CaptureControlState = .ready) {
        _state = State(initialValue: initialState)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image("home-juggling").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped().ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.4), .clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "chevron.left").frame(width: 48, height: 48)
                        Spacer()
                        CaptureSessionBadge(number: 1, recording: state == .recording,
                                            preparing: state == .preparing)
                    }.padding(.bottom, 18)
                    CaptureTouchCounter(count: state == .recording ? 18 : 0)
                    Text(lastAction).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("capture-review-action")
                    Spacer()
                    CaptureMetrics(points: state == .recording ? (0...120).map {
                        CaptureMotionPoint(time: 6 + Double($0) / 20,
                                           y: 0.8 - abs(sin(Double($0) / 20 / 0.65 * .pi)) * 0.6)
                    } : [], touchTimes: state == .recording ? (0..<18).map { Double($0) * 0.65 } : [],
                        time: state == .recording ? 12 : 0)
                        .padding(.bottom, 28)
                    CaptureControls(state: state, cameraReady: true,
                        onGallery: { lastAction = "Gallery selected" },
                        onRecord: {
                            if state == .recording { state = .ready; lastAction = "Stopped" }
                            else { state = .recording; lastAction = "Recording" }
                        },
                        onFlip: { lastAction = "Camera flipped" })
                        .padding(.bottom, 16)
                }.padding(.horizontal, 24).padding(.top, 8)
            }
        }.preferredColorScheme(.dark)
    }
}
#endif
