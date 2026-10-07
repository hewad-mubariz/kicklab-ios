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

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Group {
                if !state.isBusy {
                    sideControl("Gallery", symbol: "photo.on.rectangle", action: onGallery)
                        .accessibilityLabel("Choose video from gallery")
                        .accessibilityIdentifier("record-gallery-picker")
                } else { Color.clear.frame(width: 76, height: 80).accessibilityHidden(true) }
            }
            Spacer(minLength: 12)
            Button(action: onRecord) {
                VStack(spacing: 9) {
                    ZStack {
                        Circle().fill(.black.opacity(0.24))
                        Circle().strokeBorder(
                            LinearGradient(colors: [.white, .white.opacity(0.65), .white.opacity(0.92)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
                        if state == .preparing || state == .finishing {
                            ProgressView().tint(.white)
                        } else {
                            RoundedRectangle(cornerRadius: state == .recording ? 7 : 27)
                                .fill(LinearGradient(stops: [
                                    .init(color: Color(red: 1, green: 0.43, blue: 0.39), location: 0),
                                    .init(color: Color(red: 1, green: 0.20, blue: 0.25), location: 0.48),
                                    .init(color: Color(red: 0.78, green: 0.04, blue: 0.14), location: 1)
                                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay {
                                    RoundedRectangle(cornerRadius: state == .recording ? 7 : 27)
                                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                                }
                                .frame(width: state == .recording ? 29 : 54,
                                       height: state == .recording ? 29 : 54)
                                .shadow(color: .red.opacity(state == .recording ? 0.12 : 0.28), radius: 9, y: 3)
                        }
                    }.frame(width: 78, height: 78)
                    Text(state.title).font(.system(size: 12, weight: .medium))
                }.foregroundStyle(.white).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .preparing || state == .finishing || (state == .ready && !cameraReady))
            .accessibilityLabel(state == .recording ? "Stop Recording" : "Start Recording")
            .accessibilityIdentifier("record-capture-button")
            .accessibilityValue(state.title)
            Spacer(minLength: 12)
            Group {
                if !state.isBusy {
                    sideControl("Flip", symbol: "arrow.triangle.2.circlepath.camera", action: onFlip)
                        .disabled(!cameraReady)
                        .accessibilityLabel("Flip camera")
                        .accessibilityIdentifier("record-flip-camera")
                } else { Color.clear.frame(width: 76, height: 80).accessibilityHidden(true) }
            }
        }
        .frame(maxWidth: 380)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        .sensoryFeedback(.selection, trigger: state)
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
