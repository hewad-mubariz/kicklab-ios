// Copied from the Effects Lab (EffectLab/CoralScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum CoralSkin:Int {case coral=0}
nonisolated struct CoralSegment {var a,b:SIMD3<Float>;var ra,rb:Float;var layer,curve:Int}
nonisolated enum CoralScene {
    static let gridSize=192
    static let extent:Float=1.08
    // A fixed mounting keeps the principal tree visible at the comparison frame.
    static let designPose=simd_quatf(angle:-0.04,axis:SIMD3<Float>(0,0,1))*simd_quatf(angle:-0.04,axis:SIMD3<Float>(0,1,0))
    static let referencePose=simd_quatf(vector:SIMD4<Float>(-0.052256435,-0.103169687,-0.391036063,0.913080633))
    static let mounting=simd_inverse(referencePose)*designPose
    static let segments:[CoralSegment] = {
        var result=[CoralSegment]()
        var curveID=0
        typealias V=SIMD2<Float>
        func bezier(_ a:V,_ b:V,_ c:V,_ d:V,_ t:Float)->V {let s=1-t;return a*s*s*s+b*3*s*s*t+c*3*s*t*t+d*t*t*t}
        func makeTree(axis:SIMD3<Float>,turn:Float,scale:Float,layer:Int,variant:Float,ivoryScale:Float=1){
            let hint:SIMD3<Float>=abs(axis.y)>0.9 ? SIMD3(0,0,1):SIMD3(0,1,0)
            let vertical=simd_normalize(hint-axis*simd_dot(axis,hint)),horizontal=simd_normalize(simd_cross(vertical,axis))
            let up=vertical*cos(turn)+horizontal*sin(turn),right=horizontal*cos(turn)-vertical*sin(turn)
            func point(_ uv:V,_ radius:Float)->SIMD3<Float>{
                let uv=uv*scale
                let direction=simd_normalize(axis+right*uv.x+up*uv.y)
                let surface:Float=layer==0 ? 0.993:0.912+0.008*sin(uv.x*6+variant)
                return direction*(surface-radius)
            }
            func curve(_ a:V,_ b:V,_ c:V,_ d:V,_ r0:Float,_ r1:Float,_ count:Int){
                let id=curveID;curveID+=1
                for i in 0..<count {
                    let t=Float(i)/Float(count),u=Float(i+1)/Float(count)
                    let minimum:Float=layer==0 ? 0.006:0.0075
                    let ra=max(minimum,r1+(r0-r1)*pow(1-t,0.82)),rb=max(minimum,r1+(r0-r1)*pow(1-u,0.82))
                    result.append(CoralSegment(a:point(bezier(a,b,c,d,t),ra),b:point(bezier(a,b,c,d,u),rb),ra:ra,rb:rb,layer:layer,curve:id))
                }
            }
            let size:Float=layer==0 ? ivoryScale:0.29
            // Uneven rising limbs follow the branching silhouette of the reference.
            // A second major stem forks from the lower trunk, rather than seven
            // regularly stacked sidebars growing from one straight axis.
            let root=V(-0.32,-2.9)
            curve(root,V(-0.62,-0.9),V(-0.38,0.45),V(-0.72,2.35),0.130*size,0.041*size,30)
            var branches:[(V,V,V,V,Float)] = [
                (V(-0.42,-1.1),V(-0.34,-0.15),V(0.44,0.57),V(1.42,0.83),0.112),
                (V(-0.39,-0.40),V(-0.73,0.05),V(-1.53,0.15),V(-1.86,0.91),0.096),
                (V(-0.39,-1.65),V(-0.15,-1.04),V(0.81,-0.95),V(1.86,-0.39),0.107),
                (V(-0.46,0.36),V(-0.32,0.73),V(0.48,0.99),V(0.54,2.14),0.082),
                (V(-0.50,0.87),V(-0.77,1.0),V(-1.13,1.17),V(-1.40,1.90),0.066),
                (V(0.35,0.49),V(0.54,0.74),V(0.35,1.13),V(0.72,1.50),0.067),
                (V(0.56,-0.90),V(0.92,-0.52),V(0.70,-0.16),V(1.13,0.17),0.071),
                (V(-0.49,-1.65),V(-0.97,-1.26),V(-1.34,-1.08),V(-1.71,-0.51),0.080)
            ]
            // These upper forks share an exact parent point, so no isolated
            // rounded stump floats above the larger stem.
            let parent=branches[0],anchor=bezier(parent.0,parent.1,parent.2,parent.3,0.70)
            branches[5].0=anchor;branches[5].1=anchor+V(0.12,0.25)
            let low=branches[2],lowAnchor=bezier(low.0,low.1,low.2,low.3,0.55)
            branches[6].0=lowAnchor;branches[6].1=lowAnchor+V(0.23,0.30)
            for (j,item) in branches.enumerated(){
                let polar=layer==0 && ivoryScale<0.8
                if polar && ![0,1,3,7].contains(j){continue}
                let (a,b,c,d,r)=item
                curve(a,b,c,d,r*size,0.033*size,20)
                for k in 0..<(polar ? 2:3) {
                    let t:Float=polar ? 0.40+Float(k)*0.32:0.32+Float(k)*0.23
                    let start=bezier(a,b,c,d,t),tangent=simd_normalize(bezier(a,b,c,d,min(1,t+0.05))-start)
                    let side:Float=(j+k)%2==0 ? 1:-1
                    let perpendicular=V(-tangent.y,tangent.x)*side
                    let spread:Float=0.27+0.07*sin(Float(j*3+k)+variant)
                    let aim=simd_normalize(tangent*0.45+perpendicular*0.60+V(0,0.35))
                    let end=start+aim*(0.52+Float(k)*0.055)
                    let cb=start+tangent*0.18,cc=end-aim*0.16+perpendicular*0.04
                    let radius=(r*0.60-Float(k)*0.003)*size
                    curve(start,cb,cc,end,radius,0.024*size,10)
                    if polar {continue}
                    let split=bezier(start,cb,cc,end,0.59)
                    let childAim=simd_normalize(aim*0.50-perpendicular*0.50+V(0,0.16))
                    let tip=split+childAim*spread
                    curve(split,split+aim*0.10,tip-childAim*0.09,tip,radius*0.68,0.017*size,7)
                }
            }
        }
        for i in 0..<3 {
            let a=Float(i)*Float.pi*2/3
            makeTree(axis:SIMD3(sin(a),0,cos(a)),turn:Float(i)*0.11,scale:1,layer:0,variant:Float(i)*1.73)
        }
        // Smaller fans bridge the polar gaps that turned into broad bare
        // orange patches at 5.2 and 5.8 seconds in the previous version.
        makeTree(axis:SIMD3(0,1,0),turn:0.63,scale:0.46,layer:0,variant:7.2,ivoryScale:0.42)
        makeTree(axis:SIMD3(0,-1,0),turn:-0.91,scale:0.46,layer:0,variant:9.3,ivoryScale:0.42)
        // Many smaller orange fans occupy a second, recessed 3D layer.
        // They replace the periodic perforated sheet from the first prototype.
        for i in 0..<42 {
            let y=1-2*(Float(i)+0.5)/42,a=Float(i)*Float.pi*(3-sqrt(5.0)),r=sqrt(1-y*y)
            makeTree(axis:SIMD3(r*cos(a),y,r*sin(a)),turn:sin(Float(i)*2.71)*1.7,scale:0.27,layer:1,variant:Float(i)*2.19)
        }
        return result
    }()
    /// Narrow-band signed distance volume, built once from curved tapered tubes.
    /// No colour or lighting is baked into the field.
    static func distanceField()->[SIMD2<Float>] {
        let n=gridSize,h=extent*2/Float(n),band:Float=0.13
        var values=[SIMD2<Float>](repeating:SIMD2(repeating:band),count:n*n*n)
        var local=[Float](repeating:band,count:n*n*n)
        var stamps=[Int32](repeating:-1,count:n*n*n),touched=[Int]()
        var activeCurve = -1,activeLayer=0
        func finishCurve(){
            guard activeCurve>=0 else{return}
            let k:Float=activeLayer==0 ? 0.029:0.007
            for i in touched {
                let old=values[i][activeLayer],d=local[i]
                let blend=max(0,k-abs(old-d))/k
                values[i][activeLayer]=min(old,d)-blend*blend*k*0.25
            }
            touched.removeAll(keepingCapacity:true)
        }
        func index(_ v:Float)->Int{max(0,min(n-1,Int(floor((v+extent)/h))))}
        for segment in segments {
            if segment.curve != activeCurve {
                finishCurve();activeCurve=segment.curve;activeLayer=segment.layer
            }
            let pad=max(segment.ra,segment.rb)+band
            let lo=simd_min(segment.a,segment.b)-SIMD3(repeating:pad),hi=simd_max(segment.a,segment.b)+SIMD3(repeating:pad)
            let delta=segment.b-segment.a,l2=simd_length_squared(delta)
            for z in index(lo.z)...index(hi.z) {for y in index(lo.y)...index(hi.y) {for x in index(lo.x)...index(hi.x) {
                let p=(SIMD3(Float(x),Float(y),Float(z))+SIMD3(repeating:0.5))*h-SIMD3(repeating:extent)
                let t=max(0,min(1,simd_dot(p-segment.a,delta)/max(0.000001,l2)))
                let d=simd_length(p-segment.a-delta*t)-(segment.ra+(segment.rb-segment.ra)*t)
                let i=(z*n+y)*n+x
                // Min over one whole curve first. Blending each short segment
                // repeatedly inflates the tube and creates ridges at its joins.
                if stamps[i] != Int32(activeCurve) {
                    stamps[i]=Int32(activeCurve);local[i]=d;touched.append(i)
                } else {local[i]=min(local[i],d)}
            }}}
        }
        finishCurve()
        // A one-voxel separable filter rounds joined forks and removes the
        // angular ridge between consecutive tapered tube segments.
        for stride in [1,n,n*n] {
            let previous=values
            for z in 1..<(n-1) {for y in 1..<(n-1) {for x in 1..<(n-1) {
                let i=(z*n+y)*n+x
                values[i]=previous[i]*0.60+(previous[i-stride]+previous[i+stride])*0.20
            }}}
        }
        return values
    }
    static func uniforms(skin:CoralSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose*mounting,source:source,roughness:0.35,relief:relief,blend:blend)
    }
    static func preview(skin:CoralSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var f=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.35,relief:relief)
        f.orientation=simd_normalize(simd_quatf(angle:(time-0.6)*0.65,axis:simd_normalize(SIMD3<Float>(0.3,1,0.15)))*designPose).vector
        return f
    }
}
