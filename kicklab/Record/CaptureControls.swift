import SwiftUI

/// Shared by the live camera and the isolated simulator design review.
enum CaptureControlState: Equatable {
    case ready, preparing, recording, finishing

    var isBusy: Bool { self != .ready }
    var title: String {
        switch self {
        case .ready: "Record"
        case .preparing: "Starting…"
        case .recording: "Stop"
        case .finishing: "Finishing…"
        }
    }
}

struct CaptureControls: View {
    let state: CaptureControlState
    var cameraReady: Bool
    var onGallery: () -> Void
    var onRecord: () -> Void
    var onFlip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bursts = 0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            gallerySlot
            Spacer(minLength: 12)
            recordButton
            Spacer(minLength: 12)
            flipSlot
        }
        .frame(maxWidth: 380)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: state)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.85), trigger: state, condition: Self.isShutterPress)
        .sensoryFeedback(.selection, trigger: state, condition: Self.isBackToReady)
        .onChange(of: state) { old, new in
            if new == .recording && old != .recording { bursts += 1 }
        }
    }

    private static func isShutterPress(_ old: CaptureControlState, _ new: CaptureControlState) -> Bool {
        (old == .ready && new.isBusy) || (old == .recording && new == .finishing)
    }

    private static func isBackToReady(_ old: CaptureControlState, _ new: CaptureControlState) -> Bool {
        old.isBusy && new == .ready
    }

    // Fixed slots keep Record centered while the side controls tuck toward it.
    private var gallerySlot: some View {
        ZStack {
            if !state.isBusy {
                sideControl("Gallery", symbol: "photo.on.rectangle", action: onGallery)
                    .accessibilityLabel("Choose video from gallery")
                    .accessibilityIdentifier("record-gallery-picker")
                    .transition(.sessionTuck(.trailing))
            }
        }.frame(width: 76, height: 80)
    }

    private var flipSlot: some View {
        ZStack {
            if !state.isBusy {
                sideControl("Flip", symbol: "arrow.triangle.2.circlepath.camera", action: onFlip)
                    .disabled(!cameraReady)
                    .accessibilityLabel("Flip camera")
                    .accessibilityIdentifier("record-flip-camera")
                    .transition(.sessionTuck(.leading))
            }
        }.frame(width: 76, height: 80)
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            VStack(spacing: 9) {
                shutter.frame(width: 78, height: 78)
                Text(state.title).font(.system(size: 12, weight: .medium))
                    .contentTransition(.interpolate)
            }.foregroundStyle(.white).contentShape(Rectangle())
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .disabled(state == .preparing || state == .finishing || (state == .ready && !cameraReady))
        .accessibilityLabel(state == .recording ? "Stop Recording" : "Start Recording")
        .accessibilityIdentifier("record-capture-button")
        .accessibilityValue(state.title)
    }

    /// The red mark squeezes and twists from a circle into the stop square.
    private var shutter: some View {
        ZStack {
            Circle().fill(.black.opacity(0.24))
            Circle().strokeBorder(
                LinearGradient(colors: [.white, .white.opacity(0.65), .white.opacity(0.92)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
            burstRing
            mark
            if state == .preparing || state == .finishing {
                ShutterSpinner().transition(.sessionPop(scale: 0.8))
            }
        }
    }

    /// One outward ring the moment recording starts.
    private var burstRing: some View {
        Circle().strokeBorder(Color(red: 1, green: 0.28, blue: 0.3), lineWidth: 3)
            .keyframeAnimator(initialValue: RingBurst(), trigger: reduceMotion ? 0 : bursts) { ring, value in
                ring.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: 0.01)
                    CubicKeyframe(1.55, duration: 0.5)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: 0.01)
                    CubicKeyframe(0, duration: 0.5)
                }
            }
            .allowsHitTesting(false)
    }

    private var mark: some View {
        let square = state != .ready
        let radius: CGFloat = square ? 7 : 27
        let side: CGFloat = square ? 29 : 54
        let fill = LinearGradient(stops: [
            .init(color: Color(red: 1, green: 0.43, blue: 0.39), location: 0),
            .init(color: Color(red: 1, green: 0.20, blue: 0.25), location: 0.48),
            .init(color: Color(red: 0.78, green: 0.04, blue: 0.14), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        let rim = LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        return RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(rim, lineWidth: 0.75) }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(square || reduceMotion ? 0 : -90))
            .opacity(state == .preparing || state == .finishing ? 0.4 : 1)
            .shadow(color: .red.opacity(state == .recording ? 0.12 : 0.28), radius: 9, y: 3)
    }

    private func sideControl(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 9) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white).frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .accessibilityHidden(true)
        }.frame(width: 76)
    }
}

private struct RingBurst {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

/// A short arc running around the shutter ring while the camera starts or finishes.
private struct ShutterSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ProgressView().tint(.white)
        } else {
            TimelineView(.animation) { clock in
                Circle().trim(from: 0, to: 0.22)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees((clock.date.timeIntervalSinceReferenceDate * 400).truncatingRemainder(dividingBy: 360)))
                    .padding(1.5)
            }
        }
    }
}
