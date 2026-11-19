// Copied from the Effects Lab (EffectLab/OrigamiScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct OrigamiUniforms { var viewport, ball: SIMD4<Float> }
nonisolated struct OrigamiVertex: Equatable {
    var position, normal, color, barycentric, paper: SIMD4<Float>
}
nonisolated struct OrigamiBird: Equatable {
    var id:Int
    var birth:Float
    var center:SIMD3<Float>
    var size,alpha,wing,heading,pitch,bank:Float
    var tint:SIMD3<Float>
}
nonisolated struct OrigamiFrame { var uniforms:OrigamiUniforms;var vertices:[OrigamiVertex];var birds:[OrigamiBird] }

nonisolated enum OrigamiScene {
    static func random(_ seed:Int,_ channel:Int)->Float {
        var x=UInt32(truncatingIfNeeded:seed)&*747796405 &+ UInt32(channel)&*2891336453 &+ 277803737
        x=((x>>((x>>28)&+4))^x)&*277803737;x=(x>>22)^x
        return Float(x&0x00ffffff)/Float(0x01000000)
    }
    static func smooth(_ a:Float,_ b:Float,_ v:Float)->Float {let x=max(0,min(1,(v-a)/(b-a)));return x*x*(3-2*x)}

    // A folded crane, built from planar paper faces. The wing creases hinge
    // independently of the neck and inflated diamond body; no image sprites.
    static func mesh(_ bird:OrigamiBird)->[OrigamiVertex] {
        typealias V = SIMD3<Float>
        let rotation=simd_quatf(angle:bird.heading,axis:V(0,0,1))*simd_quatf(angle:bird.pitch,axis:V(0,1,0))*simd_quatf(angle:bird.bank,axis:V(1,0,0))
        var result=[OrigamiVertex]()
        let proportions=V(0.94+random(bird.id,41)*0.12,0.93+random(bird.id,42)*0.14,0.94+random(bird.id,43)*0.12)
        func tri(_ a:V,_ b:V,_ c:V,_ shade:Float=1,_ crease:Float=0,_ normals:[V]?=nil,_ barys:[V]?=nil) {
            let n=simd_normalize(simd_cross(b-a,c-a))
            guard n.x.isFinite else{return}
            let tint=bird.tint*shade
            for (i,local) in [a,b,c].enumerated() {
                let p=rotation.act(local*proportions)*bird.size+bird.center
                let normal=simd_normalize(rotation.act((normals?[i] ?? n)/proportions))
                let bary=barys?[i] ?? [V(1,0,0),V(0,1,0),V(0,0,1)][i]
                result.append(OrigamiVertex(position:SIMD4(p.x,p.y,p.z,1),normal:SIMD4(normal.x,normal.y,normal.z,crease),color:SIMD4(tint.x,tint.y,tint.z,bird.alpha),barycentric:SIMD4(bary.x,bary.y,bary.z,0),paper:SIMD4(local.x,local.y,local.z,random(bird.id,40)*40)))
            }
        }
        // A pressed paper facet has a small amount of bow between its creases.
        // Normals vary within the facet; separate facets retain sharp folds.
        func panel(_ a:V,_ b:V,_ c:V,_ shade:Float=1,_ bow:Float=0.012,_ crease:Float=0.35) {
            let ab=b-a,ac=c-a,n=simd_normalize(simd_cross(ab,ac))
            let steps=bird.size>60 ? 5:bird.size>26 ? 3:2
            func point(_ u:Float,_ v:Float)->(V,V,V) {
                let w=1-u-v,p=a+ab*u+ac*v+n*(bow*27*u*v*w)
                let du=ab+n*(bow*27*v*(1-2*u-v)),dv=ac+n*(bow*27*u*(1-u-2*v))
                return (p,simd_normalize(simd_cross(du,dv)),V(w,u,v))
            }
            func patch(_ uv:[SIMD2<Float>]) {
                let p=uv.map{point($0.x,$0.y)}
                tri(p[0].0,p[1].0,p[2].0,shade,crease,p.map{$0.1},p.map{$0.2})
            }
            for i in 0..<steps {for j in 0..<(steps-i) {
                let u=Float(i)/Float(steps),v=Float(j)/Float(steps),d=1/Float(steps)
                patch([SIMD2(u,v),SIMD2(u+d,v),SIMD2(u,v+d)])
                if i+j<steps-1 {patch([SIMD2(u+d,v),SIMD2(u+d,v+d),SIMD2(u,v+d)])}
            }}
        }
        let front=V(0.34,0,0),back=V(-0.40,0.04,0),top=V(-0.02,-0.40,0),bottom=V(-0.02,0.29,0)
        for side:Float in [-1,1] {
            let edge=V(-0.02,0.02,side*0.25)
            panel(front,top,edge,1.0,side*0.014,0.65);panel(top,back,edge,0.94,side*0.012,0.65)
            panel(front,edge,bottom,0.83,side*0.008);panel(back,bottom,edge,0.82,side*0.008)
            // Two overlapping kite folds around the inflated body expose
            // their darker inner layer and raised outside ridge.
            let pleatTip=V(0.23,-0.05,side*0.08),pleatTop=V(-0.04,-0.32,side*0.13)
            let pleatEdge=V(-0.18,0.10,side*0.245),pleatRidge=V(-0.01,-0.06,side*0.30)
            panel(pleatTip,pleatTop,pleatRidge,1.05,side*0.006,0.65)
            panel(pleatTop,pleatEdge,pleatRidge,0.89,side*0.008,0.65)
            panel(pleatEdge,pleatTip,pleatRidge,0.78,side*0.005,0.55)
            func wing(_ p:V)->V {
                let angle=bird.wing+(side<0 ? 0.07:-0.07)*sin(bird.bank*3+bird.wing)
                return V(p.x,p.y-sin(angle)*abs(p.z),p.z*cos(angle))
            }
            let rootA=wing(V(0.27,-0.04,side*0.09)),rootB=wing(V(-0.34,0.04,side*0.09))
            let tip=wing(V(-0.32,-0.04,side*1.43)),crease=wing(V(-0.09,-0.34,side*0.61))
            let trailing=wing(V(-0.72,0.01,side*0.65))
            let secondary=wing(V(-0.42,-0.15,side*0.76))
            panel(rootA,tip,crease,1,side*0.022,0.55)
            panel(tip,secondary,crease,0.96,side*0.016,0.40)
            panel(tip,trailing,secondary,0.84,side*0.007,0.65)
            panel(trailing,rootB,secondary,0.86,side*0.012,0.55)
            panel(rootB,crease,secondary,0.93,side*0.009,0.55)
            panel(rootB,rootA,crease,0.92,side*0.012,0.55)
            // Folded-under edge exposes a narrow, darker paper lip.
            let lip=V(0,0.018,-side*0.009)
            tri(rootA+lip,tip+lip,rootA,0.82);tri(rootA,tip+lip,tip,0.82)
            tri(tip,tip+lip,trailing,0.81);tri(trailing,tip+lip,trailing+lip,0.81)
            // Narrow folded hem, lying on the underside of the leading edge.
            let hemRoot=rootA*0.94+crease*0.06+lip,hemTip=tip*0.95+crease*0.05+lip
            panel(rootA+lip,tip+lip,hemTip,0.78,0,0.7)
            panel(rootA+lip,hemTip,hemRoot,0.86,0,0.7)
        }
        func foldedBlade(_ root:V,_ tip:V,_ rootWidth:Float,_ tipWidth:Float,_ shade:Float) {
            let d=tip-root,perp=simd_normalize(V(-d.y,d.x,0))
            let a=root+perp*rootWidth,b=root-perp*rootWidth,c=tip-perp*tipWidth,e=tip+perp*tipWidth
            let ridge=(root+tip)*0.5+V(0,0,0.055)
            panel(a,b,ridge,shade*0.91,0.003,0.45);panel(b,c,ridge,shade*0.83,0.005,0.65)
            panel(c,e,ridge,shade,0.003,0.45);panel(e,a,ridge,shade*1.04,0.005,0.65)
            tri(a,e,c,shade*0.78);tri(a,c,b,shade*0.78)
            let inset=(a+b)*0.5+V(0,0,-0.009)
            tri(a,e,inset,shade*0.72,0.45);tri(inset,e,tip+V(0,0,-0.009),shade*0.86,0.55)
        }
        foldedBlade(V(0.23,0.01,0),V(0.57,-0.79,0.015),0.105,0.048,1.0)
        foldedBlade(V(0.57,-0.79,0.015),V(0.91,-0.59,0.015),0.057,0.001,0.96)
        foldedBlade(V(-0.29,0.04,0),V(-0.92,-0.81,0),0.10,0.001,0.97)
        return result
    }

    static func frame(time:Float,size:SIMD2<Float>,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->OrigamiFrame {
        let ball=sample(time);var birds=[OrigamiBird]()
        func release(_ birth:Float,_ seed:Int,_ impact:Bool,_ small:Bool=false) {
            let age=time-birth
            guard birth>=0,age>=0,age<3.0 else{return}
            func rnd(_ c:Int)->Float {random(seed,c)}
            let b=sample(birth),r=max(1,b.z),life:Float=1.9+rnd(1)*1.0
            guard age<life,b.w>0 else{return}
            let prev=sample(max(0,birth-0.025)),next=sample(birth+0.025)
            let velocity=SIMD2(next.x-prev.x,next.y-prev.y)/Float(0.05)
            let side:Float=rnd(2)<0.65 ? 1:-1
            let angle:Float = -0.92+(side<0 ? .pi:0)+(rnd(3)-0.5)*0.95
            let dir=SIMD2(cos(angle),sin(angle)),across=SIMD2(-dir.y,dir.x)
            let initial=SIMD2(b.x,b.y)+dir*r*(1.08+rnd(4)*0.4)+across*(rnd(5)-0.5)*r*0.65
            let phase=rnd(6)*Float.pi*2,speed=r*(1.0+rnd(7)*1.45)*(impact ? 1.25:1)
            let v0=dir*speed+velocity*0.15+across*(rnd(8)-0.5)*r*0.6
            let drag:Float=0.48,travel=(1-exp(-drag*age))/drag
            let weave=(sin(age*(1.5+rnd(9)*1.3)+phase)-sin(phase))*r*0.24
            let xy=initial+v0*travel+across*weave+SIMD2<Float>(0.14*r*age*age,-0.32*r*age*age)
            let z=r*((rnd(10)-0.42)*3.0+(rnd(11)-0.5)*age*0.6)
            let perspective=1100/(1100-z)
            let length=r*(small ? 0.075+0.27*pow(rnd(12),1.2):0.13+0.64*pow(rnd(12),1.5))*perspective
            let pick=rnd(13),tint:SIMD3<Float> = pick<0.43 ? SIMD3(1,0.95,0.81):pick<0.76 ? SIMD3(0.98,0.48,0.29):SIMD3(0.12,0.59,0.62)
            let alpha=smooth(0,0.09,age)*(1-smooth(life-0.40,life,age))*intensity*b.w
            // Take-off folds open, followed by slow glides and individual wing beats.
            let flapPhase=age*(4.7+rnd(14)*3.2)+phase
            let wing:Float=0.38+0.48*sin(flapPhase)+0.75*(1-smooth(0,0.25,age))
            let heading=(rnd(15)-0.5)*1.25+0.20*sin(age*2+phase)+(side<0 ? -0.15:0.15)
            let pitch:Float = 1.02+(rnd(16)-0.5)*0.70+0.18*sin(age*1.9+phase)
            let bank:Float = 0.18+(rnd(17)-0.5)*0.70+0.23*sin(age*2.7+phase)
            birds.append(OrigamiBird(id:seed,birth:birth,center:SIMD3(xy.x,xy.y,z),size:length,alpha:alpha,wing:wing,heading:heading,pitch:pitch,bank:bank,tint:tint))
        }
        let rate:Float=8.5,end=Int(floor(time*rate)),start=max(0,Int(floor((time-3)*rate)))
        if end>=start {for i in start...end {release(Float(i)/rate,10000+i,false)}}
        let smallRate:Float=5.5,smallEnd=Int(floor(time*smallRate)),smallStart=max(0,Int(floor((time-3)*smallRate)))
        if smallEnd>=smallStart {for i in smallStart...smallEnd {release(Float(i)/smallRate,3000000+i,false,true)}}
        for (event,touch) in touches.enumerated() where time>=touch && time-touch<3.1 {
            for i in 0..<8 {release(touch+Float(i)*0.045,1000000+event*100+i,true,i>=5)}
        }
        birds.sort{$0.center.z<$1.center.z}
        var vertices=birds.flatMap{mesh($0)}
        // Opaque faces use a depth buffer; sorting retains sensible fade overlap.
        let triangles=stride(from:0,to:vertices.count,by:3).map{Array(vertices[$0..<$0+3])}.sorted {
            $0.reduce(Float(0)){$0+$1.position.z} < $1.reduce(Float(0)){$0+$1.position.z}
        }
        vertices=triangles.flatMap{$0}
        return OrigamiFrame(uniforms:OrigamiUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball),vertices:vertices,birds:birds)
    }
}
