// Copied from the Effects Lab (EffectLab/PlasmaScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum PlasmaSkin:Int {case plasma=0}
nonisolated enum PlasmaScene {
    // 24 unit sites, distributed from a Fibonacci spiral and relaxed with
    // 1200 tangent Coulomb steps at 0.012. A separate layout keeps all other skins intact.
    static let panels:[SIMD4<Float>] = [
        SIMD4(0.33915438,0.94049762,0.02094107,0),
        SIMD4(-0.31841157,0.89690064,0.30689299,0),
        SIMD4(0.06598807,0.77990865,-0.62240507,0),
        SIMD4(0.26380786,0.63179495,0.72886251,0),
        SIMD4(-0.59112771,0.73331324,-0.33588648,0),
        SIMD4(0.76069242,0.48663571,-0.42957273,0),
        SIMD4(-0.44062400,0.34834513,0.82734888,0),
        SIMD4(-0.39325240,0.22815001,-0.89067397,0),
        SIMD4(0.83207924,0.44410263,0.33229052,0),
        SIMD4(-0.88958058,0.36954921,0.26847677,0),
        SIMD4(0.36693722,0.14122349,-0.91946343,0),
        SIMD4(0.21450249,-0.04040830,0.97588721,0),
        SIMD4(-0.90501255,0.04040830,-0.42346127,0),
        SIMD4(0.97757975,-0.14122349,-0.15618498,0),
        SIMD4(-0.45717679,-0.36954921,0.80896401,0),
        SIMD4(-0.14156229,-0.44410263,-0.88472197,0),
        SIMD4(0.78264482,-0.22815001,0.57914995,0),
        SIMD4(-0.90388413,-0.34834513,0.24829246,0),
        SIMD4(0.58605614,-0.48663571,-0.64786101,0),
        SIMD4(0.19795494,-0.73331324,0.65043488,0),
        SIMD4(-0.65318952,-0.63179495,-0.41734709,0),
        SIMD4(0.62171192,-0.77990865,0.07222725,0),
        SIMD4(-0.36929533,-0.89690064,0.24329034,0),
        SIMD4(0.05400761,-0.94049762,-0.33548084,0),
    ]

    static func uniforms(skin:PlasmaSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.40,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:PlasmaSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.40,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}
