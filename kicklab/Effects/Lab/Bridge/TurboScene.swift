// Copied from the Effects Lab (EffectLab/TurboScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum TurboSkin:Int {case turbo=0}
nonisolated enum TurboScene {
    // Match the reference's three-quarter view at 5.40 s while retaining every
    // subsequent source-pose increment. This is a fixed local mounting.
    static let designPose = simd_quatf(angle:0.60,axis:SIMD3<Float>(0,0,1))*simd_quatf(angle:-0.24,axis:SIMD3<Float>(1,0,0))
    static let referencePose = simd_quatf(vector:SIMD4<Float>(-0.052256435,-0.103169687,-0.391036063,0.913080633))
    static let mounting=simd_inverse(referencePose)*designPose
    static func uniforms(skin:TurboSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose*mounting,source:source,roughness:0.24,relief:relief,blend:blend)
    }
    static func preview(skin:TurboSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.24,relief:relief)
        frame.orientation=simd_normalize(simd_quatf(angle:(time-0.6)*0.65,axis:simd_normalize(SIMD3<Float>(0.3,1,0.15)))*designPose).vector
        return frame
    }
}
