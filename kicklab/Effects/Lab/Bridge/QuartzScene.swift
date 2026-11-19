// Copied from the Effects Lab (EffectLab/QuartzScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum QuartzSkin:Int {case quartz=0}
nonisolated struct QuartzFracture {var centerSize,normalAspect,tangentSeed,detail:SIMD4<Float>}
nonisolated enum QuartzScene {
    static let facets:[SIMD4<Float>] = {
        var points:[SIMD3<Float>] = (0..<12).map { i in
            let y=1-2*(Float(i)+0.5)/12,a=Float(i)*Float.pi*(3-sqrt(5)),r=sqrt(1-y*y)
            return SIMD3(r*cos(a),y,r*sin(a))
        }
        for _ in 0..<220 {
            let previous=points
            for i in points.indices {
                var force=SIMD3<Float>.zero
                for j in points.indices where i != j {let d=previous[i]-previous[j],l=simd_length(d);force+=d/(l*l*l)}
                points[i]=simd_normalize(previous[i]+(force-previous[i]*simd_dot(force,previous[i]))*0.006)
            }
        }
        return points.enumerated().map { i,p in
            let j=SIMD3<Float>(sin(Float(i)*4.1),cos(Float(i)*3.3),sin(Float(i)*2.9))*0.14
            let v=simd_normalize(p+j);return SIMD4(v.x,v.y,v.z,0)
        }
    }()
    /// Fixed finite sheets inside the crystal. Their depth and angular response
    /// are evaluated by the refracted view ray, never advanced by a clock.
    static let fractures:[QuartzFracture] = {
        var state:UInt32=0x90A4F6
        func random()->Float {state=1664525 &* state &+ 1013904223;return Float(state>>8)/Float(1<<24)}
        func direction()->SIMD3<Float> {
            let y=random()*2-1,a=random()*Float.pi*2,r=sqrt(max(0,1-y*y))
            return SIMD3(r*cos(a),y,r*sin(a))
        }
        return (0..<10).map { i in
            let center=direction()*pow(random(),1/3)*(i<4 ? 0.46:0.78)
            let normal=direction(),axis:SIMD3<Float>=abs(normal.y)>0.9 ? SIMD3(1,0,0):SIMD3(0,1,0)
            let base=simd_normalize(simd_cross(normal,axis)),angle=random()*Float.pi*2
            let tangent=base*cos(angle)+simd_cross(normal,base)*sin(angle)
            let size:Float=i<4 ? 0.48+random()*0.33:i<8 ? 0.24+random()*0.28:0.10+random()*0.20
            return QuartzFracture(centerSize:SIMD4(center.x,center.y,center.z,size),normalAspect:SIMD4(normal.x,normal.y,normal.z,0.45+random()*0.75),tangentSeed:SIMD4(tangent.x,tangent.y,tangent.z,random()*128),detail:SIMD4(i<4 ? 1:0.55,random(),random(),Float(i)))
        }
    }()
    static func uniforms(skin:QuartzSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.13,relief:relief,blend:blend)
    }
    static func preview(skin:QuartzSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        GoldScene.preview(time:time,size:size,moving:moving,roughness:0.13,relief:relief)
    }
}
