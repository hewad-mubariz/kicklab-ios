import AVKit
import CoreMotion
import simd
import SwiftUI

struct StadiumPreviewView: View {
    let summary: SessionSummary
    @ObservedObject var model: StadiumPreviewModel
    let edit: SessionEditState
    @Binding var overlays: ExportOverlaySettings
    var onApply: (SceneSelection?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = AVPlayer()
    @State private var videoOutput:AVPlayerItemVideoOutput?
    @State private var comparison = Comparison.stadium
    @State private var cameraMovement = true
    @State private var look=SIMD2<Float>.zero
    @State private var zoom:Float=1
    @State private var phoneMotion=false
    @State private var displayedLook=SIMD2<Float>.zero
    @State private var showCounter=false
    @State private var resetID=0
    @State private var playbackTime=0.0
    @State private var playing=false
    @State private var scrubbing=false
    @State private var resumeAfterSeek=false
    @State private var timeObserver:Any?
    @State private var renderError:String?
    private let motionAvailable=CMMotionManager().isDeviceMotionAvailable
    private var interactive:Bool {model.result?.foreground != nil && model.result?.recording != nil}

    private enum Comparison: String, CaseIterable { case original = "Original", stadium = "Stadium", indoor = "Indoor", urban = "Urban", forest = "Forest", snow = "Snow", beach = "Beach" }
    private var environment: PreviewEnvironment {
        switch comparison {
        case .original, .stadium: .classicStadium
        case .indoor: .indoorArena
        case .urban: .urbanCourt
        case .forest: .forestCourt
        case .snow: .snowField
        case .beach: .beachField
        }
    }
    private var comparisons: [Comparison] { interactive ? Comparison.allCases : [.original,.stadium] }

    init(summary:SessionSummary,model:StadiumPreviewModel,edit:SessionEditState,overlays:Binding<ExportOverlaySettings>,
         initialEnvironment:PreviewEnvironment = .classicStadium,onApply:@escaping (SceneSelection?) -> Void) {
        self.summary=summary;self.model=model;self.edit=edit;self._overlays=overlays;self.onApply=onApply
        if let scene=edit.scene {
            _look=State(initialValue:scene.look);_zoom=State(initialValue:scene.zoom)
            _cameraMovement=State(initialValue:scene.followRecordedCamera)
        }
        let initialComparison: Comparison = switch initialEnvironment {
        case .classicStadium: .stadium
        case .indoorArena: .indoor
        case .urbanCourt: .urban
        case .forestCourt: .forest
        case .snowField: .snow
        case .beachField: .beach
        }
        _comparison=State(initialValue:initialComparison)
    }
    private var displayedURL: URL? {
        guard let result = model.result else { return nil }
        return comparison == .original ? result.original : (result.foreground ?? (cameraMovement ? result.moving : result.locked))
    }

    var body: some View {
        ZStack {
            SessionBackdrop()
            VStack(spacing:16) {
                SessionHeader(title:comparison == .original ? "Environments":environment.title,onBack:{ dismiss() })
                if let result = model.result {
                    VStack(spacing:0) {
                        if comparison != .original,let recording=result.recording,result.foreground != nil {
                            StadiumInteractiveSurface(player:player,videoOutput:videoOutput,recording:recording,alphaFolder:recording.losslessAlpha == true ? result.folder:nil,environment:environment,look:look,zoom:zoom,
                                follow:cameraMovement,phoneMotion:phoneMotion,resetID:resetID,
                                onLookChange:{look=$0},onDisplayedLookChange:{displayedLook=$0},onFailure:{renderError=$0})
                                .aspectRatio(result.size.width/result.size.height,contentMode:.fit)
                                .overlay {
                                    GeometryReader { geometry in
                                        ExportOverlayLayer(settings: overlays,
                                            timeline: .init(touches: summary.touchesMarked, total: summary.touches),
                                            time: playbackTime, size: geometry.size)
                                    }.allowsHitTesting(false)
                                }
                                .contentShape(Rectangle())
                                .accessibilityLabel("360 degree \(environment.title) preview")
                                .accessibilityIdentifier("stadium-interactive-video")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment:look.x -= .pi/4
                                    case .decrement:look.x += .pi/4
                                    @unknown default:break
                                    }
                                    look.x=look.x.truncatingRemainder(dividingBy:2*Float.pi)
                                }
                            HStack(spacing:12) {
                                Button {togglePlayback()} label: {Image(systemName:playing ? "pause.fill":"play.fill")}
                                    .accessibilityLabel(playing ? "Pause":"Play")
                                Slider(value:$playbackTime,in:0...max(0.1,result.duration)) { editing in
                                    scrubbing=editing
                                    if editing {resumeAfterSeek=playing;player.pause()}
                                    else {seek(to:playbackTime);if resumeAfterSeek {player.play()}}
                                }.tint(SessionStyle.mint).accessibilityLabel("Scene video position")
                                Text("\(Int(playbackTime))s / \(Int(result.duration.rounded()))s")
                                    .font(.system(size:11,weight:.medium)).monospacedDigit()
                            }.padding(12).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:12)).padding(12)
                        } else {
                            VideoPlayer(player:player)
                        }
                        if let renderError {
                            Text("Couldn’t draw the scene. \(renderError)")
                                .font(.system(size:13)).padding().background(.black.opacity(0.9))
                        }
                    }
                    .background(.black).clipShape(RoundedRectangle(cornerRadius:16))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .padding(.horizontal,SessionStyle.inset)
                    .accessibilityIdentifier("stadium-preview-video")
                    VStack(spacing:14) {
                        comparisonPicker
                        Toggle(interactive ? "Follow recorded camera":"Camera movement",isOn:$cameraMovement)
                            .font(.system(size:14,weight:.medium))
                            .tint(SessionStyle.mint)
                            .disabled(comparison == .original)
                            .accessibilityIdentifier("stadium-camera-movement")
                        if interactive && comparison != .original {
                            HStack {
                                Text("Drag to look around").font(.system(size:12)).foregroundStyle(SessionStyle.secondary)
                                Spacer()
                                Button {look.x += .pi/6} label: {Image(systemName:"arrow.left")}
                                    .frame(width:32,height:32).accessibilityLabel("Look left")
                                Button {look.x -= .pi/6} label: {Image(systemName:"arrow.right")}
                                    .frame(width:32,height:32).accessibilityLabel("Look right")
                                Button("Reset view") {look = .zero;zoom=1;resetID+=1}
                                    .font(.system(size:12,weight:.semibold)).tint(SessionStyle.mint)
                                    .accessibilityIdentifier("stadium-reset-view")
                            }.tint(SessionStyle.mint)
                            HStack(spacing:10) {
                                Image(systemName:"minus.magnifyingglass")
                                Slider(value:$zoom,in:0.85...1.3).tint(SessionStyle.mint).accessibilityLabel("Scene zoom")
                                Image(systemName:"plus.magnifyingglass")
                            }.font(.system(size:12)).foregroundStyle(SessionStyle.secondary)
                            if motionAvailable {
                                Toggle("Look around with phone",isOn:$phoneMotion)
                                    .font(.system(size:14,weight:.medium)).tint(SessionStyle.mint)
                            }
                        }
                        Text(model.sampleLabel ?? (result.sourceDuration > result.duration+0.05
                            ? "Preview · First \(Int(result.duration)) seconds"
                            : "Preview · \(Int(result.duration.rounded())) seconds"))
                            .font(.system(size:12,weight:.semibold)).foregroundStyle(SessionStyle.mint)
                        HStack(spacing:12) {
                            Button {
                                player.pause();playing=false
                                if phoneMotion {look=displayedLook;phoneMotion=false}
                                showCounter=true
                            } label: {
                                Label("Counter",systemImage:"number.circle")
                                    .font(.system(size:13,weight:.semibold)).padding(.vertical,14).padding(.horizontal,12)
                            }.tint(SessionStyle.mint).modifier(SessionPanel())
                            SessionAction(title:comparison == .original ? "Use Original":"Use \(environment.title)",symbol:"checkmark") {
                                onApply(selection);dismiss()
                            }.disabled(renderError != nil || (comparison != .original && !interactive))
                        }
                        Text("Your chosen view and counter will be included in export.")
                            .font(.system(size:11)).foregroundStyle(SessionStyle.secondary)
                    }.padding(.horizontal,SessionStyle.inset)
                } else {
                    Spacer()
                    VStack(spacing:16) {
                        Image(systemName:model.error == nil ? "sportscourt" : "exclamationmark.circle")
                            .font(.system(size:40)).foregroundStyle(SessionStyle.mint)
                        Text(model.error == nil ? "Preparing your preview" : "Couldn’t prepare the preview")
                            .font(.system(size:20,weight:.semibold))
                        if let error = model.error {
                            Text(error).font(.system(size:14)).foregroundStyle(SessionStyle.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await model.prepare(summary:summary) } }
                                .tint(SessionStyle.mint)
                        } else {
                            Text(model.preparationStage)
                                .font(.system(size:14)).foregroundStyle(SessionStyle.secondary)
                            if model.progress == 0 {
                                ProgressView().tint(SessionStyle.mint)
                            } else {
                                ProgressView(value:model.progress).tint(SessionStyle.mint)
                                Text("\(Int(model.progress*100))%")
                                    .font(.system(size:13,weight:.medium)).monospacedDigit()
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if context.date.timeIntervalSince(model.lastProgressAt) > 20 {
                                    Text("This step is taking longer than usual. You can cancel and try again.")
                                        .font(.footnote).foregroundStyle(SessionStyle.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            Button("Cancel") { model.cancelPreparation(); dismiss() }
                                .tint(SessionStyle.mint)
                        }
                    }.padding(28)
                    Spacer()
                }
            }.padding(.top,12).padding(.bottom,20)
        }
        .sheet(isPresented:$showCounter) {
            ExportOverlayEditor(summary:summary,edit:counterEdit,sourceSize:model.result?.size ?? CGSize(width:9,height:16),
                sceneModel:model,settings:$overlays).presentationDragIndicator(.visible)
        }
        .onChange(of:overlays) { _,value in value.save() }
        .preferredColorScheme(.dark)
        .task { await model.prepare(summary:summary) }
        .task(id:displayedURL) {
            guard let url = displayedURL else { return }
            let previous = player.currentTime().seconds
            let wasPlaying = player.currentItem == nil || player.rate > 0
            player.pause()
            if let timeObserver {player.removeTimeObserver(timeObserver);self.timeObserver=nil}
            let item=AVPlayerItem(url:url)
            if comparison != .original && interactive {
                // Attach before seeking, including while paused. Attaching in
                // the view's next update can miss the only decoded seek frame.
                let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[
                    kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String:true,
                    kCVPixelBufferIOSurfacePropertiesKey as String:[String: Int]()])
                output.suppressesPlayerRendering=true;item.add(output);videoOutput=output
            } else {videoOutput=nil}
            player.replaceCurrentItem(with:item)
            let time = previous.isFinite ? max(0,min(previous,(model.result?.duration ?? 1)-0.05)) : 0
            await player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
            guard !Task.isCancelled else { return }
            timeObserver=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { stamp in
                if !scrubbing && stamp.seconds.isFinite {playbackTime=stamp.seconds}
                playing=player.rate>0
            }
            if wasPlaying { player.play();playing=true }
        }
        .onAppear { if reduceMotion { cameraMovement = false } }
        .onChange(of:playbackTime) {_,value in if scrubbing {seek(to:value)}}
        .onReceive(NotificationCenter.default.publisher(for:.AVPlayerItemDidPlayToEndTime)) { event in
            if let item=event.object as? AVPlayerItem,item === player.currentItem {playing=false}
        }
        .onDisappear {
            phoneMotion=false;player.pause()
            if let timeObserver {player.removeTimeObserver(timeObserver);self.timeObserver=nil}
            player.replaceCurrentItem(with:nil);videoOutput=nil
        }
    }
    private var comparisonPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(comparisons, id: \.self) { option in
                        Button { comparison = option } label: {
                            Text(option.rawValue)
                                .font(.system(size: 13, weight: comparison == option ? .semibold : .medium))
                                .foregroundStyle(comparison == option ? .white : SessionStyle.secondary)
                                .padding(.horizontal, 15).frame(height: 38)
                                .background(comparison == option ? SessionStyle.deepGreen : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(comparison == option ? SessionStyle.mint : .clear, lineWidth: 0.8))
                        }.buttonStyle(.plain).id(option)
                            .accessibilityAddTraits(comparison == option ? .isSelected : [])
                    }
                }.padding(4)
            }
            .background(SessionStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("scene-comparison-picker")
            .onAppear { proxy.scrollTo(comparison, anchor: .center) }
            .onChange(of: comparison) { _, value in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(value, anchor: .center) }
            }
        }.frame(height: 46)
    }
    private var selection: SceneSelection? {
        comparison == .original ? nil : SceneSelection(environment:environment,
            look:phoneMotion ? displayedLook:look,zoom:zoom,followRecordedCamera:cameraMovement)
    }
    private var counterEdit: SessionEditState {
        var result=edit;result.scene=selection;return result
    }
    private func seek(to time:Double) {
        player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    private func togglePlayback() {
        if player.rate>0 {player.pause();playing=false}
        else {
            if player.currentTime().seconds >= (model.result?.duration ?? 1)-0.05 {seek(to:0)}
            player.play();playing=true
        }
    }
}
