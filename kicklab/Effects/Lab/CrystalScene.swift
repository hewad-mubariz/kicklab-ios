import Foundation
import simd

// Crystal, accepted in the Effects Lab on 1 November 2026: the lab's footage scene, copied with its
// track renamed to CrystalTrack. 144 continuous crystals, 12 independently ageing fragments per touch,
// 52 mist volumes and 160 frost motes, all derived from the ball track and touch times.

/// Mirrored in CrystalLab.h; byte for byte aligned with the Metal declarations.
nonisolated struct LabUniforms: Equatable, Sendable {
    var viewport: SIMD4<Float>
    var material: SIMD4<Float>
    var scene: SIMD4<Float>
    var ball: SIMD4<Float>
}
nonisolated struct IceInstance: Equatable, Sendable {
    var centerScale: SIMD4<Float>
    var rotationSeed: SIMD4<Float>
    var appearance: SIMD4<Float>
}
nonisolated struct FootageUniforms: Equatable, Sendable {
    var lab: LabUniforms
    var footageTransform: SIMD4<Float>
    var atmosphere: SIMD4<Float>
}
nonisolated enum IceScene {
    static func hash(_ n: Float) -> Float { let v = sin(n * 127.1 + 311.7) * 43758.5453; return v - floor(v) }
}

nonisolated struct CrystalBall {
    var time: Double
    var x, y, radius, visibility: Float
}

/// The ball as the lab's footage render read it, through the shared 30 Hz sampler, and the touch times.
nonisolated struct CrystalTrack {
    let sample: (Float) -> SIMD4<Float>
    let touchTimes: [Double]
    func at(_ time: Double) -> CrystalBall {
        let b = sample(Float(time))
        return CrystalBall(time: time, x: b.x, y: b.y, radius: b.z, visibility: b.w)
    }
}

/// One moment of Crystal: its uniforms and the crystals, mist and frost it draws.
nonisolated struct CrystalFrame: Equatable, Sendable {
    var uniforms: FootageUniforms
    var objects: [IceInstance]
    var mist: [FrostElement]
    var dust: [FrostElement]
    var ball: SIMD4<Float>

    static func == (a: CrystalFrame, b: CrystalFrame) -> Bool {
        a.uniforms == b.uniforms && a.objects == b.objects && a.mist == b.mist && a.dust == b.dust && a.ball == b.ball
    }

    /// The lab's footage uniforms at `time`; `strength` fades the whole effect for lower intensities.
    static func make(time: Double, size: CGSize, strength: Float, track: CrystalTrack) -> CrystalFrame {
        let ball = track.at(time), unit = max(1, ball.radius) / 0.64
        var objects = track.naturalInstances(at: time)
        var atmosphere = track.atmosphere(at: time)
        // Every crystal, puff and mote carries its own opacity; a lower intensity scales them all.
        if strength < 1 {
            for i in objects.indices { objects[i].appearance.y *= strength }
            for i in atmosphere.mist.indices { atmosphere.mist[i].appearance.y *= strength }
            for i in atmosphere.dust.indices { atmosphere.dust[i].appearance.y *= strength }
        }
        let uniforms = FootageUniforms(lab: LabUniforms(viewport: SIMD4(Float(size.width), Float(size.height), Float(time) + 1.6, 2),
            material: SIMD4(0.58, 0.34, 0, 0), scene: SIMD4(Float(objects.count), 0, 0.72, 0.78), ball: SIMD4(0, 0, 0.64, 0)),
            footageTransform: SIMD4(ball.x, ball.y, unit, ball.visibility),
            atmosphere: SIMD4(Float(atmosphere.mist.count), Float(atmosphere.dust.count), track.recentImpact(time), 0))
        return CrystalFrame(uniforms: uniforms, objects: objects, mist: atmosphere.mist, dust: atmosphere.dust,
                            ball: SIMD4(ball.x, ball.y, unit, ball.visibility))
    }
}

nonisolated struct FrostElement: Equatable, Sendable { var centerSize: SIMD4<Float>; var appearance: SIMD4<Float> }
nonisolated struct FootageAtmosphere { var mist: [FrostElement]; var dust: [FrostElement] }
nonisolated struct IceBirth { var time: Double; var age, duration, seed: Float }
nonisolated enum FootageIceDensity {
    static let original = 104
    static let addedLarge = 5, addedMedium = 18, addedSmall = 33
    static let channels = original + addedLarge + addedMedium + addedSmall
    static let continuous = channels - 16
    static let perTouch = 12
}
nonisolated struct TouchIceFragment {
    let touchIndex, pieceIndex: Int
    let birth: IceBirth
    var large: Bool { pieceIndex < 2 }
    var medium: Bool { pieceIndex >= 2 && pieceIndex < 6 }
}

extension CrystalTrack {
    func velocity(at time: Double) -> SIMD2<Float> {
        let t=max(0,time),a=at(max(0,t-0.04)),b=at(t)
        let dt=Float(t-max(0,t-0.04))
        guard dt>0.001 else{return .zero}
        let v=SIMD2(b.x-a.x,b.y-a.y)/dt
        return simd_clamp(v,SIMD2(repeating:-b.radius*24),SIMD2(repeating:b.radius*24))
    }
    func recentImpact(_ time: Double) -> Float {
        guard let last=touchTimes.last(where:{$0<=time}),time-last<0.65 else{return 0}
        return exp(-Float(time-last)*5.8)
    }
    func emission(index: Int,time: Double,period: Float,base: Float) -> IceBirth {
        let phase=IceScene.hash(base+4)*period
        let cycle=floor((Float(time)+phase)/period)
        let birth=Double(cycle*period-phase)
        return IceBirth(time:birth,age:max(0,min(period,Float(time-birth))),duration:period,seed:base+cycle*17.61)
    }
    // The release point, velocity and radius are sampled once at birth. This
    // world-space path never reattaches a fragment to the current ball center.
    func releasedPosition(_ birth: IceBirth, inherit: Float, spread: Float, gravity: Float, drag: Float,
                          rearBias: Bool, kickBoost: Float = 0.28) -> SIMD2<Float> {
        let b=at(max(0,birth.time)),v=velocity(at:birth.time),speed=simd_length(v)
        let random=IceScene.hash(birth.seed+2)
        let angle:Float=rearBias && speed>b.radius*1.5
            ? atan2(-v.y,-v.x)+(random-0.5)*3.65
            : random*Float.pi*2
        let radial=SIMD2(cos(angle),sin(angle)),tangent=SIMD2(-radial.y,radial.x)
        let release=SIMD2(b.x,b.y)+radial*b.radius*(0.78+IceScene.hash(birth.seed+5)*0.62)
        let kick=recentImpact(max(0,birth.time))
        let initial=v*inherit+radial*b.radius*spread*(1+kick*kickBoost)+tangent*b.radius*(IceScene.hash(birth.seed+7)-0.5)*0.8
        let travel=(1-exp(-drag*birth.age))/drag
        let gravityTravel=birth.age/drag-travel/drag
        return release+initial*travel+SIMD2(0,b.radius*gravity*gravityTravel)
    }
    // Every touch owns its own small cohort. Later touches cannot recycle these
    // identities, restart their fade, or move their already-sampled release point.
    func touchFragments(at time: Double) -> [TouchIceFragment] {
        var fragments=[TouchIceFragment]()
        for (touchIndex,touch) in touchTimes.enumerated() where touch<=time && time-touch<1.22 {
            for pieceIndex in 0..<FootageIceDensity.perTouch {
                let seed=1901.17+Float(touchIndex)*71.137+Float(pieceIndex)*4.731
                let start=touch+0.012+Double(IceScene.hash(seed+6))*0.065
                let duration:Float=0.92+IceScene.hash(seed+3)*0.22
                let age=Float(time-start)
                guard age>=0 && age<duration else {continue}
                fragments.append(TouchIceFragment(touchIndex:touchIndex,pieceIndex:pieceIndex,
                    birth:IceBirth(time:start,age:age,duration:duration,seed:seed)))
            }
        }
        return fragments
    }
    func touchPosition(_ fragment: TouchIceFragment) -> SIMD2<Float> {
        releasedPosition(fragment.birth,inherit:0.16,
            spread:1.4+IceScene.hash(fragment.birth.seed+42)*1.1,
            gravity:fragment.large ? 11 : (fragment.medium ? 10 : 8),drag:1.4,
            rearBias:fragment.pieceIndex%3 != 0,kickBoost:0.3)
    }
    func touchOpacity(_ fragment: TouchIceFragment) -> Float {
        let b=fragment.birth
        let enter=min(1,b.age/0.025),leave=max(0,min(1,(b.duration-b.age)/0.24))
        // Fade by the fragment's own age, never by distance to the next ball pose.
        return (fragment.large ? 0.78 : 0.88)*enter*enter*(3-2*enter)*leave*leave*(3-2*leave)
    }
    func crystalInstance(birth: IceBirth, ball: CrystalBall, position: SIMD2<Float>,
                         large: Bool, medium: Bool, prominent: Bool, opacity: Float) -> IceInstance {
        let source=at(max(0,birth.time)),unit=max(1,ball.radius)/0.64
        let center=(position-SIMD2(ball.x,ball.y))/unit,seed=birth.seed
        let size:Float=large ? (prominent ? 0.34+IceScene.hash(seed+12)*0.11 : 0.20+pow(IceScene.hash(seed+12),1.3)*0.17)
            : (medium ? 0.055+pow(IceScene.hash(seed+12),1.25)*0.13 : 0.014+pow(IceScene.hash(seed+12),1.7)*0.045)
        let spinSign:Float=IceScene.hash(seed+9)<0.5 ? -1 : 1
        let spin=spinSign*(large ? 1.8+IceScene.hash(seed+44)*1.8 : 2.6+IceScene.hash(seed+44)*2.7)
        let pitch=(IceScene.hash(seed+19)-0.5)*(large ? 1.25 : 0.9)+birth.age*spin*0.7
        let side:Float=IceScene.hash(seed+21)<0.5 ? -1 : 1
        let yaw=large ? side*(0.45+IceScene.hash(seed+23)*0.55)+birth.age*spin*0.65
            : (IceScene.hash(seed+21)-0.5)*1.5+birth.age*spin
        let roll=IceScene.hash(seed+26)*Float.pi*2+birth.age*spin*0.7
        let silhouettes=large ? [0,4,6,4,3,0,6] : [0,4,5,6,4,3,6]
        let mesh=silhouettes[Int(IceScene.hash(seed+34)*Float(silhouettes.count))%silhouettes.count]
        let scale=min(0.48,size*source.radius/max(1,ball.radius))
        let z = -0.17+(IceScene.hash(seed+16)-0.5)*0.34
        return IceInstance(centerScale:SIMD4(center.x,center.y,z,scale),rotationSeed:SIMD4(pitch,yaw,roll,seed),
            appearance:SIMD4(0,opacity*ball.visibility*source.visibility,Float(mesh),large ? 0 : (medium ? 1 : 2)))
    }
    func naturalInstances(at time: Double) -> [IceInstance] {
        let ball=at(time),unit=max(1,ball.radius)/0.64
        var objects=[IceInstance]()
        objects.reserveCapacity(FootageIceDensity.channels+FootageIceDensity.perTouch*3)
        for index in 0..<FootageIceDensity.channels {
            // Trade six added medium channels and ten added chips for touch-born
            // survivors. The original 104 channels keep their exact seeds/motion.
            if (121..<127).contains(index) || (150..<160).contains(index) {continue}
            let extra=index-FootageIceDensity.original
            let large=index<13 || (extra>=0 && extra<FootageIceDensity.addedLarge)
            let medium=(index>=13 && index<47) || (extra>=FootageIceDensity.addedLarge && extra<FootageIceDensity.addedLarge+FootageIceDensity.addedMedium)
            let prominent=index<4 || index==FootageIceDensity.original
            let base=Float(index)*4.731+11.19
            let duration:Float=large ? 0.30+IceScene.hash(base)*0.22 : (medium ? 0.26+IceScene.hash(base)*0.24 : 0.22+IceScene.hash(base)*0.24)
            let birth=emission(index:index,time:time,period:duration,base:base)
            let life=birth.age/birth.duration
            let scatter:Float=large ? 2.0+IceScene.hash(birth.seed+42)*1.4 : (medium ? 2.5+IceScene.hash(birth.seed+42)*1.7 : 3.3+IceScene.hash(birth.seed+42)*1.7)
            let position=releasedPosition(birth,inherit:large ? 0.38 : (medium ? 0.28 : 0.20),
                spread:scatter,gravity:large ? 14.0 : (medium ? 11.0 : 8.0),drag:large ? 1.1 : 1.6,rearBias:index%4 != 0,kickBoost:0.9)
            let center=(position-SIMD2(ball.x,ball.y))/unit
            let inRamp=min(1,birth.age/0.020),outRamp=max(0,min(1,(0.88-life)/0.56))
            let distanceFade=max(0,min(1,(4.8-simd_length(center))/1.8))
            let fade=inRamp*inRamp*(3-2*inRamp)*outRamp*outRamp*(3-2*outRamp)*distanceFade
            objects.append(crystalInstance(birth:birth,ball:ball,position:position,large:large,medium:medium,prominent:prominent,opacity:fade))
        }
        for fragment in touchFragments(at:time) {
            objects.append(crystalInstance(birth:fragment.birth,ball:ball,position:touchPosition(fragment),
                large:fragment.large,medium:fragment.medium,prominent:false,opacity:touchOpacity(fragment)))
        }
        return objects
    }
    func atmosphere(at time: Double) -> FootageAtmosphere {
        let ball=at(time),unit=max(1,ball.radius)/0.64
        var mist=[FrostElement](),dust=[FrostElement]()
        for index in 0..<52 {
            let base=Float(index)*9.173+72.1
            let duration:Float=index<32 ? 0.12+IceScene.hash(base)*0.09 : 0.24+IceScene.hash(base)*0.20
            let birth=emission(index:index,time:time,period:duration,base:base)
            let b=at(max(0,birth.time)),life=birth.age/birth.duration
            let point=releasedPosition(birth,inherit:0.30,spread:1.15,gravity:-0.8,drag:2.3,rearBias:index%3 != 0,kickBoost:0.45)
            let center=(point-SIMD2(ball.x,ball.y))/unit
            let size=(0.18+IceScene.hash(birth.seed+8)*0.13+birth.age*0.25)*b.radius/max(1,ball.radius)
            let density=pow(max(0,sin(Float.pi*life)),0.8)*(index<32 ? 1.10 : 0.85)*(1+recentImpact(time)*0.18)*ball.visibility*b.visibility
            mist.append(FrostElement(centerSize:SIMD4(center.x,center.y,-0.1+(IceScene.hash(birth.seed+9)-0.5)*0.3,size),appearance:SIMD4(birth.seed,density,0.95+IceScene.hash(birth.seed+12)*0.50,birth.age)))
        }
        for index in 0..<160 {
            let base=Float(index)*3.17+204.3,duration=0.20+IceScene.hash(base)*0.22
            let birth=emission(index:index,time:time,period:duration,base:base)
            let b=at(max(0,birth.time)),life=birth.age/birth.duration
            let point=releasedPosition(birth,inherit:0.24,spread:3.2,gravity:6.5,drag:1.6,rearBias:index%4 != 0,kickBoost:0.6)
            let center=(point-SIMD2(ball.x,ball.y))/unit
            let size=(0.004+pow(IceScene.hash(birth.seed+8),2)*0.014)*b.radius/max(1,ball.radius)
            let fade=pow(max(0,sin(Float.pi*life)),0.65)*(0.55+IceScene.hash(birth.seed+12)*0.45)*ball.visibility*b.visibility
            dust.append(FrostElement(centerSize:SIMD4(center.x,center.y,-0.08+(IceScene.hash(birth.seed+15)-0.5)*0.5,size),appearance:SIMD4(birth.seed,fade,0,birth.age)))
        }
        return FootageAtmosphere(mist:mist,dust:dust)
    }
}
