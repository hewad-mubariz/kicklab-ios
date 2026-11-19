// Copied from the Effects Lab (EffectLab/AmberScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum AmberSkin:Int {case amber=0}
nonisolated enum AmberScene {
    /// Relax the sixteen sites on the sphere to remove the stretched spiral cells.
    /// The larger cell area stays unchanged; the accepted skins keep their layouts.
    static let panels:[SIMD4<Float>] = {
        var points:[SIMD3<Float>] = (0..<16).map { i in
            let y=1-2*(Float(i)+0.5)/16
            let angle=Float(i)*Float.pi*(3-sqrt(5))
            let radius=sqrt(1-y*y)
            return SIMD3(radius*cos(angle),y,radius*sin(angle))
        }
        for _ in 0..<600 {
            let previous=points
            for i in points.indices {
                var force=SIMD3<Float>.zero
                for j in points.indices where i != j {
                    let delta=previous[i]-previous[j],distance=simd_length(delta)
                    force+=delta/(distance*distance*distance)
                }
                let tangent=force-previous[i]*simd_dot(force,previous[i])
                points[i]=simd_normalize(previous[i]+tangent*0.005)
            }
        }
        return points.map{SIMD4($0.x,$0.y,$0.z,0)}
    }()
    /// Fixed inclusions in object space: parallax comes from the refracted view ray.
    static let bubbles:[SIMD4<Float>] = {
        var state:UInt32=0xA6BE42
        func random()->Float {state=1664525 &* state &+ 1013904223;return Float(state>>8)/Float(1<<24)}
        var result=[SIMD4<Float>]()
        for _ in 0..<10000 {
            if result.count==1536 {break}
            let p=SIMD3(random()*1.7-0.85,random()*1.7-0.85,random()*1.7-0.85)
            let radius:Float=result.count<18 ? 0.019+random()*0.017 : result.count<680 ? 0.006+pow(random(),1.6)*0.016 : 0.003+pow(random(),1.8)*0.010
            if simd_length(p)+radius>0.91 {continue}
            if result.contains(where:{simd_distance(p,SIMD3($0.x,$0.y,$0.z))<($0.w+radius)*1.10}) {continue}
            result.append(SIMD4(p.x,p.y,p.z,radius))
        }
        precondition(result.count==1536,"Amber bubble distribution must be complete")
        return result
    }()
    static func uniforms(skin:AmberSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.13,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:AmberSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.13,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}
