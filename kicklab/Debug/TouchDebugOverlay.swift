#if DEBUG
import SwiftUI

/// The circle marks the candidate's original contact position, not the ball's
/// later position when the trajectory finally confirms the decision.
struct TouchDebugOverlay: View {
    let event: TouchDebugEvent
    var sourceSize = CGSize(width: 9, height: 16)
    var fillsFrame = false
    var showsPlayer = true

    private var isHandling: Bool { event.handConfirmed || event.rejection == .heldBall }
    private var tint: Color { isHandling ? .red : event.rejection == nil ? .green : .orange }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let sx = size.width / sourceSize.width, sy = size.height / sourceSize.height
            let scale = fillsFrame ? max(sx, sy) : min(sx, sy)
            let video = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(x: (size.width - video.width) / 2, y: (size.height - video.height) / 2)
            let center = CGPoint(x: origin.x + (event.ball?.x ?? 0.5) * video.width,
                                 y: origin.y + (event.ball?.y ?? 0.5) * video.height)
            let diameter = max(52, max((event.ball?.width ?? 0) * video.width,
                                      (event.ball?.height ?? 0) * video.height) + 18)
            ZStack(alignment: .topLeading) {
                if showsPlayer, let player = event.player, let id = player.id, let box = player.box {
                    ActivePlayerDebugOverlay(players: [.init(id: id, box: box)], selection: player,
                                             sourceSize: sourceSize, fillsFrame: fillsFrame)
                }
                if event.ball != nil {
                    Circle().stroke(tint, lineWidth: 4)
                        .background(Circle().fill(tint.opacity(0.08)))
                        .shadow(color: .black.opacity(0.65), radius: 3)
                        .frame(width: diameter, height: diameter)
                        .position(center)
                }
                VStack(spacing: 3) {
                    Label(event.title, systemImage: isHandling ? "hand.raised.fill" :
                            event.rejection == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text(event.detail).font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(width: min(280, size.width - 24))
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.8)))
                .position(x: min(max(center.x, min(140, size.width / 2)), max(size.width / 2, size.width - 140)),
                          y: min(max(center.y - diameter / 2 - 42, 110), size.height - 110))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

struct LiveTouchDebugOverlay: View {
    let event: TouchDebugEvent?
    var sourceSize = CGSize(width: 9, height: 16)
    @State private var visible = false

    var body: some View {
        Group {
            if visible, let event { TouchDebugOverlay(event: event, sourceSize: sourceSize, fillsFrame: true, showsPlayer: false) }
        }
        .task(id: event?.frameIndex) {
            visible = event != nil
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            visible = false
        }
    }
}
/// Display only: rendered after the camera preview, never in analyzed pixels or exports.
struct ActivePlayerDebugOverlay: View {
    let players: [ActiveJugglerTracker.Player]
    let selection: ActivePlayerSelection?
    var sourceSize = CGSize(width: 9, height: 16)
    var fillsFrame = false

    var body: some View {
        GeometryReader { geometry in
            let scale = fillsFrame ? max(geometry.size.width/sourceSize.width, geometry.size.height/sourceSize.height)
                                  : min(geometry.size.width/sourceSize.width, geometry.size.height/sourceSize.height)
            let width = sourceSize.width*scale, height = sourceSize.height*scale
            let dx = (geometry.size.width-width)/2, dy = (geometry.size.height-height)/2
            ZStack {
                ForEach(players, id: \.id) { player in
                    let selected = player.id == selection?.id && selection?.state == .locked
                    let box = player.box
                    Rectangle().stroke(selected ? Color.green : Color.gray, lineWidth: selected ? 3 : 1)
                        .overlay(alignment: .topLeading) {
                            Text(selected ? "Juggler #\(player.id)" : "Player #\(player.id)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selected ? .green : .white)
                                .padding(3).background(.black.opacity(0.7))
                        }
                        .frame(width: box.width*width, height: box.height*height)
                        .position(x: dx+box.x*width, y: dy+box.y*height)
                }
            }
        }.allowsHitTesting(false)
    }
}
#endif
