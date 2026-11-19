// Copied from the Effects Lab (EffectLab/MeteorScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum MeteorSkin:Int {case meteor=0}
nonisolated enum MeteorScene {
    // Fixed impact sites in object space. Unequal sizes keep the rotating stone
    // from reading as a repeating embossed texture.
    static let craters:[SIMD4<Float>] = {
      var result = (0..<64).map { i -> SIMD4<Float> in
        let f=Float(i), y=1-2*(f+0.5)/64
        let a=f*2.39996323, r=sqrt(1-y*y)
        let radius:Float = i%7 == 0 ? 0.088 : (i%3 == 0 ? 0.048 : 0.022)
        return SIMD4(cos(a)*r,y,sin(a)*r,radius*(0.8+0.4*Float((i*17)%31)/31))
      }
      let hero=simd_quatf(angle:0.69,axis:simd_normalize(SIMD3<Float>(0.3,1,0.15)))
      for (i,point,radius) in [(0,SIMD2<Float>(0.30,-0.52),Float(0.14)),(7,SIMD2<Float>(-0.39,0.04),Float(0.076)),(14,SIMD2<Float>(0.18,0.37),Float(0.042))] {
        let p=hero.inverse.act(SIMD3(point.x,point.y,sqrt(1-simd_length_squared(point))))
        result[i]=SIMD4(p.x,p.y,p.z,radius)
      }
      return result
    }()
    static func uniforms(skin:MeteorSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.20,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:MeteorSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.20,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}
