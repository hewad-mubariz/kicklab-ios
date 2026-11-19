// Copied from the Effects Lab (EffectLab/ArcadeScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum ArcadeSkin:Int {case eightBall=0,puzzle,gummy,air,toon,earth,robot,treasure,goal}
nonisolated enum ArcadeScene {
    // A fixed decorative alignment makes the front design reviewable at 5.40 s.
    // Motion still follows the recorded source quaternion on every other frame.
    static let alignment=simd_quatf(vector:SIMD4<Float>(0.052256435,0.103169687,0.391036063,0.913080633))
    static func uniforms(skin:ArcadeSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose*alignment,source:source,roughness:0.23,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:ArcadeSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.23,relief:relief)
        let pose=simd_quatf(angle:(time-0.6)*0.65,axis:simd_normalize(SIMD3<Float>(0.3,1,0.15)))
        frame.orientation=pose.vector;frame.options.w=Float(skin.rawValue)
        return frame
    }
}
