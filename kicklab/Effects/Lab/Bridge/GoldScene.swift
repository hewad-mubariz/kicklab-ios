// Copied from the Effects Lab (EffectLab/GoldScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct GoldUniforms {
    var viewport,ball,orientation,options:SIMD4<Float>
}

nonisolated enum GoldScene {
    // Icosahedron vertices and face centres produce 12 pentagonal and 20
    // hexagonal spherical cells. No lighting is baked into a colour texture.
    static let panels:[SIMD4<Float>] = {
        let phi=Float((1+sqrt(5.0))/2)
        var vertices=[SIMD3<Float>]()
        for a:Float in [-1,1] {for b:Float in [-phi,phi] {
            vertices += [SIMD3(0,a,b),SIMD3(a,b,0),SIMD3(b,0,a)]
        }}
        var sites=vertices.map(simd_normalize)
        for i in vertices.indices {for j in (i+1)..<vertices.count {for k in (j+1)..<vertices.count {
            if abs(simd_distance(vertices[i],vertices[j])-2)<0.001 && abs(simd_distance(vertices[i],vertices[k])-2)<0.001 && abs(simd_distance(vertices[j],vertices[k])-2)<0.001 {
                sites.append(simd_normalize(vertices[i]+vertices[j]+vertices[k]))
            }
        }}}
        return sites.map{SIMD4($0.x,$0.y,$0.z,0)}
    }()
    static func uniforms(time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,roughness:Float=0.19,relief:Float=1,blend:Float=1)->GoldUniforms {
        GoldUniforms(viewport:SIMD4(size.x,size.y,time,blend),ball:ball,
                     orientation:simd_normalize(pose).vector,options:SIMD4(roughness,relief,source ? 1:0,0))
    }
    static func preview(time:Float,size:SIMD2<Float>,moving:Bool,roughness:Float,relief:Float)->GoldUniforms {
        let r=min(size.x,size.y)*(moving ? 0.17:0.36)
        let offset=moving ? SIMD2(sin(time*1.3)*r*1.2,-abs(sin(time*2.2))*r*1.7):.zero
        let ball=SIMD4(size.x*0.5+offset.x,size.y*(moving ? 0.66:0.5)+offset.y,r,1)
        let pose=simd_quatf(angle:time*0.65+0.3,axis:simd_normalize(SIMD3(0.3,1,0.15)))
        return uniforms(time:time,size:size,ball:ball,pose:pose,source:false,roughness:roughness,relief:relief)
    }
}

/// Saved source-video orientation estimates. Seeking is deterministic; rejected
/// tracker increments already hold their last pose in the supplied recording.
nonisolated struct GoldPoseTrack {
    struct Row:Decodable {
        var time:Double
        var quaternion_xyzw:[Float]
        var accepted:Bool
    }
    let rows:[Row]
    init(url:URL)throws {
        rows=try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
        guard !rows.isEmpty,rows.allSatisfy({$0.time.isFinite && $0.quaternion_xyzw.count==4 && $0.quaternion_xyzw.allSatisfy(\.isFinite) && $0.quaternion_xyzw.reduce(Float(0),{$0+$1*$1})>0.000001}),zip(rows,rows.dropFirst()).allSatisfy({$0.time<$1.time}) else {
            throw NSError(domain:"GoldLab",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid source rotation timeline"])
        }
    }
    func at(_ time:Double)->simd_quatf {
        var low=0,high=rows.count
        while low<high {let mid=(low+high)/2;if rows[mid].time<time {low=mid+1}else{high=mid}}
        let b=min(low,rows.count-1),a=max(0,b-1)
        func q(_ i:Int)->simd_quatf {let v=rows[i].quaternion_xyzw;return simd_normalize(simd_quatf(vector:SIMD4(v[0],v[1],v[2],v[3])))}
        let t=Float(max(0,min(1,(time-rows[a].time)/max(0.000001,rows[b].time-rows[a].time))))
        return simd_slerp(q(a),q(b),t)
    }
}
