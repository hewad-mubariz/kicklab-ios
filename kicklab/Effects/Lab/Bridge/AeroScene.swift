// Copied from the Effects Lab (EffectLab/AeroScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum AeroSkin:Int {case aero=0}
nonisolated enum AeroScene {
    // A constant decorative-layout registration at the 5.40 s reference
    // frame. Recorded relative rotation remains unchanged across the clip.
    static let layoutAlignment=simd_quatf(vector:SIMD4<Float>(0.016588423,0.424963043,0.418741527,0.802363241))
    static func uniforms(skin:AeroSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.40,relief:relief,blend:blend)
        if source {frame.orientation=simd_normalize(pose*layoutAlignment).vector}
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:AeroSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.40,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}
