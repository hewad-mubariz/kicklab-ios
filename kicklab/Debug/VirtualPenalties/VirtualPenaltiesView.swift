#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import UIKit
struct VirtualPenaltiesView: View {
    @ObservedObject var keeper: KeeperScene
    let onClose: () -> Void
    var onRealBall: (() -> Void)? = nil
    @ObservedObject private var wall=WallTargetsModel.shared
    @State private var clean=false
    @State private var displaySettings=false
    private let lime=Color(red:0.76,green:0.98,blue:0.32)
    var body: some View {
        ZStack {
            Color(red:0.035,green:0.055,blue:0.06).ignoresSafeArea()
            HStack(spacing:0) {
                if !clean { controls.frame(width:190).padding(.leading,22).padding(.trailing,18) }
                ZStack {
                    if wall.projectorConnected {
                        projectorControls
                    } else {
                        KeeperSurface(keeper:keeper,projected:keeper.projectionPreview)
                    }
                    VStack {
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(wall.projectorConnected ? "PROJECTOR CONNECTED":"VIRTUAL PENALTIES").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(lime)
                                Text(keeper.hasShot ? keeper.outcome : "Find the corner.").font(.system(size:22,weight:.bold,design:.rounded))
                                Text(keeper.status).font(.system(size:10)).foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Button { displaySettings=true } label: { Image(systemName:"display").padding(10).background(.black.opacity(0.3),in:Circle()) }.accessibilityLabel("Projection settings")
                            if !wall.projectorConnected && !keeper.projectionPreview {
                                Button { keeper.toggleFraming() } label: { Image(systemName:"camera.rotate").padding(10).background(.black.opacity(0.3),in:Circle()) }.accessibilityLabel("Change camera view")
                            }
                            Button { clean.toggle() } label: { Image(systemName:clean ? "slider.horizontal.3":"arrow.up.left.and.arrow.down.right").padding(10).background(.black.opacity(0.3),in:Circle()) }.accessibilityLabel(clean ? "Show shot controls":"Hide shot controls")
                        }.padding(.top,16)
                        Spacer()
                        if !clean { replayControls.padding(.bottom,14) }
                    }.padding(.horizontal,18)
                    if keeper.reviewActive,let result=keeper.reviewResult {
                        Color.black.opacity(keeper.reviewCurtain).allowsHitTesting(false)
                        PenaltyResultOverlay(result:result,replay:keeper.showingReplay,compact:keeper.reviewStage == "Reaction")
                            .id(keeper.showingReplay)
                    }
                }.clipped()
            }.ignoresSafeArea(.container,edges:[.top,.bottom])
            if let error=keeper.error { Text(error).padding(24).background(.black,in:RoundedRectangle(cornerRadius:16)) }
        }.tint(lime).statusBarHidden().persistentSystemOverlays(.hidden)
            .sheet(isPresented:$displaySettings) { displayPanel.presentationDetents([.medium,.large]) }
    }
    private var controls: some View {
        VStack(alignment:.leading,spacing:10) {
            Button(action:onClose) { Label("Wall games",systemImage:"chevron.left").font(.system(size:12,weight:.semibold)) }
                .accessibilityIdentifier("penalties-back")
            if let onRealBall {
                Button("Real ball camera",action:onRealBall).font(.system(size:12,weight:.bold))
            }
            Text("Place your shot").font(.system(size:19,weight:.bold,design:.rounded))
            GoalAimPad(x:keeper.settings.x,y:keeper.settings.y) { keeper.aim(x:$0,y:$1) }.frame(height:70)
            HStack {
                Text("POWER").font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(.secondary)
                Spacer();Text("\(keeper.settings.kmh) km/h").font(.system(size:10,design:.monospaced))
            }
            Slider(value:Binding(get:{keeper.settings.power},set:{keeper.settings.power=$0;keeper.reset()}),in:0...1).accessibilityLabel("Shot power")
            HStack(spacing:4) { ForEach(ShotStyle.allCases) { style in
                Button { keeper.settings.style=style;keeper.reset() } label: { Text(style.rawValue).font(.system(size:10,weight:.semibold)).padding(.vertical,8).frame(maxWidth:.infinity).background(keeper.settings.style==style ? lime.opacity(0.18):.white.opacity(0.04),in:RoundedRectangle(cornerRadius:7)) }
            } }
            Menu {
                ForEach(KeeperRead.allCases) { read in Button(read.rawValue) { keeper.settings.read=read;keeper.reset() } }
            } label: { HStack { Text(keeper.settings.read.rawValue);Spacer();Image(systemName:"chevron.down") }.font(.system(size:11)).padding(10).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:8)) }.accessibilityLabel("Keeper decision")
            HStack(spacing:6) {
                Menu("Cases") {
                    ForEach([("Centre","centre"),("Low centre","low"),("Low left","low-left"),("Low right","low-right"),("Mid left","left"),("Mid right","right"),("Top left","top-left"),("Top right","top-right"),("High centre","high"),("Panenka","panenka"),("Bounce","bounce")],id:\.1) { title,key in Button(title) { keeper.applyPreset(key) } }
                    Section("Around the goal") {
                        ForEach([("Wide","wide"),("Over the bar","over"),("High & wide","high-wide"),("Onto the roof net","roof"),("Aim at right post","post"),("Aim at crossbar","crossbar")],id:\.1) { title,key in Button(title) { keeper.applyPreset(key) } }
                    }
                }.font(.system(size:11,weight:.semibold)).frame(maxWidth:.infinity).padding(.vertical,10).background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                Button { keeper.shoot() } label: { Label("Shoot",systemImage:"arrow.up.right").font(.system(size:13,weight:.bold)).frame(maxWidth:.infinity).padding(.vertical,10).foregroundStyle(.black).background(lime,in:RoundedRectangle(cornerRadius:8)) }.disabled(!keeper.ready)
            }
            Text("Aim inside or outside the white frame.").font(.system(size:9)).foregroundStyle(.secondary)
        }.padding(.vertical,15)
    }
    private var replayControls: some View {
        HStack(spacing:12) {
            Button { keeper.replay() } label: { Image(systemName:"arrow.counterclockwise") }.accessibilityLabel("Replay shot")
            Button { keeper.togglePlayback() } label: { Image(systemName:keeper.isPlaying ? "pause.fill":"play.fill") }.accessibilityLabel(keeper.isPlaying ? "Pause replay":"Play replay")
            Slider(value:Binding(get:{keeper.playhead},set:{keeper.seek($0)}),in:0...keeper.duration).accessibilityLabel("Shot timeline").disabled(!keeper.hasShot)
            Button("Contact") { keeper.showContact() }.font(.system(size:10,weight:.semibold))
            Button("Net") { keeper.showNetImpact() }.font(.system(size:10,weight:.semibold)).accessibilityLabel("Show net impact").disabled(!keeper.hasNetImpact)
            Button(keeper.speed==1 ? "1×":"¼×") { keeper.toggleSpeed() }.font(.system(size:12,weight:.bold,design:.monospaced)).frame(width:28)
            Button(keeper.demoRunning ? "Stop demo":"Demo") { keeper.toggleDemo() }.font(.system(size:10,weight:.semibold)).accessibilityIdentifier("penalties-demo")
        }.foregroundStyle(.white).font(.system(size:12)).padding(11).background(.black.opacity(0.48),in:Capsule()).disabled(!keeper.ready)
    }
    private var projectorControls: some View {
        VStack(spacing:14) {
            Image(systemName:"display").font(.system(size:36)).foregroundStyle(lime)
            Text("The goalkeeper is on your wall.").font(.system(size:20,weight:.bold,design:.rounded))
            Text("Aim and shoot here, or run the demo loop.\nThe projected camera stays fixed.").font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Text("Goal size").font(.system(size:12))
                Slider(value:$keeper.projectionScale,in:0.75...1.15).accessibilityLabel("Projected goal size")
                Text("\(Int(keeper.projectionScale*100))%").font(.system(size:12,design:.monospaced)).frame(width:40)
            }.frame(maxWidth:360)
            Toggle("Bright wall",isOn:$keeper.brightProjection).font(.system(size:12)).frame(maxWidth:360)
        }.padding(.horizontal,28).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var displayPanel: some View {
        NavigationStack {
            Form {
                Section("Projector") {
                    Label(wall.projectorConnected ? "External display connected":"No external display connected",systemImage:wall.projectorConnected ? "checkmark.circle.fill":"display")
                    Text("Connect HDMI/USB-C or use iPhone Screen Mirroring. The external screen shows the goal; shot controls stay on this phone.")
                    if !wall.projectorConnected { Toggle("Preview fixed projector camera",isOn:$keeper.projectionPreview) }
                    HStack {
                        Text("Goal size")
                        Slider(value:$keeper.projectionScale,in:0.75...1.15).accessibilityLabel("Projected goal size")
                    }
                    Toggle("Bright wall",isOn:$keeper.brightProjection)
                }
                Section("This trial") {
                    Text("Shots are simulated and controlled from the phone. Use the wall to check goal size, contrast, keeper movement and net reaction. Physical-ball tracking is a separate next step.")
                }
            }
            .navigationTitle("Projection")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { displaySettings=false } } }
        }
    }
}
struct GoalAimPad: View {
    let x: Float,y: Float
    let changed: (Float,Float)->Void
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius:4).fill(Color.white.opacity(0.04))
                Path { p in
                    let w=g.size.width,h=g.size.height
                    let left=w*(1-7.32/11)/2,top=h*(1-2.44/4.5),width=w*7.32/11,height=h*2.44/4.5
                    p.addRect(CGRect(x:left,y:top,width:width,height:height))
                    for u in [CGFloat(1)/3,CGFloat(2)/3] {
                        p.move(to:CGPoint(x:left+width*u,y:top));p.addLine(to:CGPoint(x:left+width*u,y:h))
                        p.move(to:CGPoint(x:left,y:top+height*u));p.addLine(to:CGPoint(x:left+width,y:top+height*u))
                    }
                }.stroke(.white.opacity(0.23),lineWidth:1)
                Circle().fill(Color(red:0.76,green:0.98,blue:0.32)).frame(width:10,height:10).position(x:CGFloat((x+5.5)/11)*g.size.width,y:CGFloat(1-y/4.5)*g.size.height)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { event in changed(Float(event.location.x/g.size.width)*11-5.5,(1-Float(event.location.y/g.size.height))*4.5) })
            .accessibilityElement().accessibilityLabel("Shot target").accessibilityValue(String(format:"%.1f metres across, %.1f metres high",x,y))
        }
    }
}

#endif
