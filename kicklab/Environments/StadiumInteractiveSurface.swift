import AVFoundation
import CoreMotion
import MetalKit
import SwiftUI
import simd

/// Plays the timestamp-paired color/alpha cache through the same stadium shader
/// used for prepared movies. Camera controls never repeat Vision inference.
struct StadiumInteractiveSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput?
    let recording: StadiumSceneRecording
    let alphaFolder: URL?
    let environment: PreviewEnvironment
    let look: SIMD2<Float>
    let zoom: Float
    let follow: Bool
    let phoneMotion: Bool
    let resetID: Int
    var onLookChange: (SIMD2<Float>)->Void
    var onDisplayedLookChange: (SIMD2<Float>)->Void
    var onFailure: (String)->Void

    func makeUIView(context:Context)->StadiumInteractiveView {StadiumInteractiveView()}
    func updateUIView(_ view:StadiumInteractiveView,context:Context) {
        view.onFailure=onFailure
        view.onLookChange=onLookChange
        view.onDisplayedLookChange=onDisplayedLookChange
        view.configure(player:player,videoOutput:videoOutput,recording:recording,alphaFolder:alphaFolder,environment:environment,look:look,zoom:zoom,follow:follow,phoneMotion:phoneMotion,resetID:resetID)
    }
    static func dismantleUIView(_ view:StadiumInteractiveView,coordinator:()) {view.stop()}
}

final class StadiumInteractiveView: MTKView {
    private var renderer: StadiumPreviewRenderer?
    private var cache: CVMetalTextureCache?
    private weak var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var pixels: CVPixelBuffer?
    private var alphaPixels: CVPixelBuffer?
    private var alphaReader: LosslessAlphaCache.Reader?
    private var alphaFolder: URL?
    private var alphaFailure=false
    private var time=0.0
    private var recording: StadiumSceneRecording?
    private var environment = PreviewEnvironment.classicStadium
    private var look=SIMD2<Float>.zero
    private var panOrigin=SIMD2<Float>.zero
    private var displayedLook=SIMD2<Float>.zero
    private var displayedZoom:Float=1
    private var lastTick:CFTimeInterval?
    private var playbackFPS:Float=30
    private var zoom:Float=1
    private var follow=true
    private var link:CADisplayLink?
    private var linkTarget:LinkTarget?
    private let inFlight=DispatchSemaphore(value:2)
    private let motion=CMMotionManager()
    private var origin:simd_quatf?
    private var resetID=0
    private var dirty=true
    private var reportedError=false
    var onFailure:(String)->Void = {_ in}
    var onLookChange:(SIMD2<Float>)->Void = {_ in}
    var onDisplayedLookChange:(SIMD2<Float>)->Void = {_ in}
    private var reportedLook=SIMD2<Float>(repeating:.infinity)

    init() {
        super.init(frame:.zero,device:MTLCreateSystemDefaultDevice())
        framebufferOnly=false;colorPixelFormat = .bgra8Unorm
        isPaused=true;enableSetNeedsDisplay=true;isUserInteractionEnabled=true
        backgroundColor = .black;contentScaleFactor=min(2,traitCollection.displayScale)
        addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
        do {
            let renderer=try StadiumPreviewRenderer();self.renderer=renderer;device=renderer.device
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,renderer.device,nil,&cache)==kCVReturnSuccess else {
                throw ForegroundMaskProcessor.Failure.allocation
            }
        } catch {report(error)}
    }
    required init(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}

    @objc private func pan(_ recognizer:UIPanGestureRecognizer) {
        if recognizer.state == .began {panOrigin=look}
        let translation=recognizer.translation(in:self)
        look=panOrigin+SIMD2(Float(translation.x)*0.009,Float(translation.y)*0.006)
        look.y=max(-0.55,min(0.55,look.y))
        if recognizer.state == .ended || recognizer.state == .cancelled {
            look.x=look.x.truncatingRemainder(dividingBy:2*Float.pi)
        }
        dirty=true;setNeedsDisplay();onLookChange(look)
    }

    func configure(player:AVPlayer,videoOutput:AVPlayerItemVideoOutput?,recording:StadiumSceneRecording,alphaFolder:URL?,environment:PreviewEnvironment,look:SIMD2<Float>,zoom:Float,
                   follow:Bool,phoneMotion:Bool,resetID:Int) {
        self.player=player;self.recording=recording;self.environment=environment;self.look=look;self.zoom=zoom;self.follow=follow;dirty=true
        playbackFPS=recording.frames.count>1 && recording.frames[1].time-recording.frames[0].time<0.025 ? 60:30
        link?.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:playbackFPS,preferred:playbackFPS)
        if self.alphaFolder != alphaFolder {
            self.alphaFolder=alphaFolder;alphaReader=nil;alphaPixels=nil;pixels=nil;alphaFailure=false;reportedError=false
            do {alphaReader=try alphaFolder.map {try LosslessAlphaCache.Reader(folder:$0)}}
            catch {alphaFailure=true;report(error)}
        }
        if self.resetID != resetID {origin=nil;self.resetID=resetID}
        if phoneMotion && !motion.isDeviceMotionActive && motion.isDeviceMotionAvailable {
            origin=nil;motion.deviceMotionUpdateInterval=1.0/30
            motion.startDeviceMotionUpdates(using:.xArbitraryZVertical)
        } else if !phoneMotion && motion.isDeviceMotionActive {motion.stopDeviceMotionUpdates();origin=nil}
        if output !== videoOutput {pixels=nil;alphaPixels=nil;output=videoOutput}
        setNeedsDisplay()
    }
    private final class LinkTarget:NSObject {
        weak var view:StadiumInteractiveView?
        @objc func tick(_ link:CADisplayLink) {view?.tick(link)}
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link==nil {
                let target=LinkTarget();target.view=self;linkTarget=target
                let link=CADisplayLink(target:target,selector:#selector(LinkTarget.tick(_:)))
                link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:playbackFPS,preferred:playbackFPS)
                link.add(to:.main,forMode:.common);self.link=link
            }
        } else {link?.invalidate();link=nil;linkTarget=nil;motion.stopDeviceMotionUpdates();origin=nil}
    }
    private func tick(_ link:CADisplayLink) {
        let dt=min(0.1,max(0,link.timestamp-(lastTick ?? link.timestamp-1.0/30)))
        lastTick=link.timestamp
        let amount:Float = UIAccessibility.isReduceMotionEnabled ? 1:Float(1-exp(-dt*18))
        let yaw=look.x-displayedLook.x
        let delta=SIMD2(atan2(sin(yaw),cos(yaw)),look.y-displayedLook.y)
        if simd_length(delta)>0.0001 || abs(displayedZoom-zoom)>0.0001 {
            displayedLook+=delta*amount;displayedZoom+=(zoom-displayedZoom)*amount;dirty=true
        }
        if let player,let output {
            let requested=player.rate==0 ? player.currentTime():output.itemTime(forHostTime:link.targetTimestamp)
            if output.hasNewPixelBuffer(forItemTime:requested) {
                var displayed=CMTime.invalid
                if let frame=output.copyPixelBuffer(forItemTime:requested,itemTimeForDisplay:&displayed) {
                    let stamp=max(0,(displayed.isValid ? displayed:requested).seconds)
                    do {
                        let alpha=try alphaReader?.frame(at:stamp)
                        pixels=frame;alphaPixels=alpha;time=stamp;dirty=true
                    } catch {pixels=nil;alphaPixels=nil;report(error)}
                }
            }
        }
        if motion.isDeviceMotionActive {dirty=true}
        if dirty {setNeedsDisplay()}
    }
    override func draw(_ rect:CGRect) {
        guard !alphaFailure,let renderer,let cache,let pixels,let recording,let drawable=currentDrawable,
              inFlight.wait(timeout:.now()) == .success else {return}
        do {
            var reference:CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixels,nil,.bgra8Unorm,
                CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&reference)==kCVReturnSuccess,
                  let reference,let texture=CVMetalTextureGetTexture(reference),let command=renderer.queue.makeCommandBuffer()
            else {throw ForegroundMaskProcessor.Failure.allocation}
            var alphaReference:CVMetalTexture?
            var alphaTexture=texture
            if let alphaPixels {
                guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,alphaPixels,nil,.r8Unorm,
                    CVPixelBufferGetWidth(alphaPixels),CVPixelBufferGetHeight(alphaPixels),0,&alphaReference)==kCVReturnSuccess,
                      let alphaReference,let t=CVMetalTextureGetTexture(alphaReference) else {throw ForegroundMaskProcessor.Failure.allocation}
                alphaTexture=t
            }
            var camera=recording.sample(at:time)
            camera.look=displayedLook;camera.zoom=displayedZoom;camera.followRecordedCamera=follow
            if let q=motion.deviceMotion?.attitude.quaternion,motion.isDeviceMotionActive {
                let current=simd_quatf(ix:Float(q.x),iy:Float(q.y),iz:Float(q.z),r:Float(q.w))
                if origin==nil {origin=current}
                let forward=(origin!.inverse*current).act(SIMD3<Float>(0,0,-1))
                camera.look+=SIMD2(atan2(-forward.x,-forward.z),asin(max(-1,min(1,forward.y))))
            }
            camera.look.y=max(-0.65,min(0.65,camera.look.y))
            if simd_length(camera.look-reportedLook)>0.0001 {
                reportedLook=camera.look
                let value=camera.look
                DispatchQueue.main.async { [weak self] in self?.onDisplayedLookChange(value) }
            }
            try renderer.encode(source:texture,mask:alphaTexture,target:drawable.texture,camera:camera,time:time,packed:true,
                sourceRect:recording.sourceRect ?? CGRect(x:0,y:0,width:1,height:1),environment:environment,refined:recording.matteVersion == 2,separateAlpha:alphaPixels != nil,command:command)
            let semaphore=inFlight
            let retainedAlpha=alphaPixels,retainedReference=alphaReference
            command.addCompletedHandler {_ in withExtendedLifetime((reference,pixels,retainedReference,retainedAlpha)) {};semaphore.signal()}
            command.present(drawable);command.commit();dirty=false
        } catch {inFlight.signal();report(error)}
    }
    private func report(_ error:Error) {
        guard !reportedError else {return};reportedError=true
        DispatchQueue.main.async {[weak self] in self?.onFailure(error.localizedDescription)}
    }
    func stop() {
        link?.invalidate();link=nil;linkTarget=nil;motion.stopDeviceMotionUpdates();origin=nil
        output=nil;pixels=nil;alphaPixels=nil;alphaReader=nil;alphaFolder=nil;player=nil
    }
}
