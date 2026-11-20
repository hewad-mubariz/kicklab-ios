#if WALL_GAMES_PREVIEW
import SwiftUI

/// Only shown when UIKit has actually supplied a separate external scene.
/// Pure mirroring must keep the game board on the phone to project it.
struct WallArcadePhoneController:View {
    @ObservedObject var model:WallTargetsModel
    @ObservedObject var camera:WallTargetsCamera
    let ending:Bool
    let onRetry:()->Void
    let onStop:()->Void
    @State private var inspectCamera=false
    private var failed:Bool { model.calibration == .failed || model.referenceFailed || model.mappingFailed || model.focusFailed }
    private var settingUp:Bool { !model.isPlaying && !ending && model.gameScreen == .board }
    private var title:String {
        if ending { return "SAVING YOUR ROUND" }
        if failed { return "LET'S CHECK THE WALL" }
        if let count=model.countdown { return "READY IN \(count)" }
        if model.referenceBox != nil && model.wallReference == nil { return "HOLD AT THE CENTRE" }
        if settingUp { return "CHECKING YOUR WALL" }
        return "PLAY ON THE WALL"
    }
    private var message:String {
        if ending { return "Finishing the video and shot data…" }
        if model.countdown != nil { return "Step back from the wall. Keep the phone in place." }
        if let notice=model.notice { return notice }
        if settingUp { return "Stand aside. Keep the phone fixed and all four dots clear." }
        return "Leave the phone in place. Your game and hit feedback are on the projector."
    }
    var body:some View {
        GeometryReader { geo in
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    Label("WALL CONNECTED",systemImage:"rectangle.connected.to.line.below")
                        .font(.caption.bold()).foregroundStyle(WallArcadeStyle.lime)
                    Spacer()
                    Text(model.game.title.uppercased()).font(.caption.bold()).foregroundStyle(.white.opacity(0.65))
                }
                HStack(spacing:24) {
                    if (settingUp || inspectCamera) && !ending {
                        WallArcadeCameraView(camera:camera).aspectRatio(16/9,contentMode:.fit)
                            .frame(maxWidth:geo.size.width*0.48)
                    }
                    VStack(alignment:.leading,spacing:12) {
                        Text(title).font(WallArcadeStyle.display(34)).minimumScaleFactor(0.7).lineLimit(2)
                        Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                        if settingUp && model.referenceBox != nil && !failed {
                            ProgressView(value:model.referenceProgress).tint(WallArcadeStyle.lime)
                        }
                        if failed {
                            Button("Retry alignment",systemImage:"arrow.clockwise",action:onRetry)
                                .buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                                .accessibilityIdentifier("arcade-retry-setup")
                        } else if !settingUp && !ending {
                            Text("\(model.hits.count) CONFIRMED SHOTS").font(.caption.bold()).foregroundStyle(WallArcadeStyle.lime)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:.infinity)
                HStack {
                    if !settingUp && !ending {
                        Button(inspectCamera ? "Hide camera":"View camera",systemImage:"camera.viewfinder") { inspectCamera.toggle() }
                            .buttonStyle(.glass).tint(.white).accessibilityIdentifier("arcade-live-camera")
                    }
                    Spacer()
                    if !ending {
                        Button(action:onStop) { Image(systemName:"stop.fill").frame(width:32,height:32) }
                            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
                            .accessibilityLabel("Stop and save round").accessibilityIdentifier("arcade-stop-round")
                    } else { ProgressView().tint(.white) }
                }
            }.padding(24)
        }.background(WallArcadeStyle.background).foregroundStyle(.white)
            .accessibilityIdentifier("arcade-phone-controller")
    }
}
#endif
