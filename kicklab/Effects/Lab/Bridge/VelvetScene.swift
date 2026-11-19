// Copied from the Effects Lab (EffectLab/VelvetScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum VelvetSkin:Int {case velvet=0}
nonisolated enum VelvetScene {
    static func uniforms(skin:VelvetSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.65,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:VelvetSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.65,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}
