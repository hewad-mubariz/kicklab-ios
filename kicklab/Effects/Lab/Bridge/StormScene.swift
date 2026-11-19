// Copied from the Effects Lab (EffectLab/StormScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct StormUniforms {
 var viewport,ball,minimum,extent,counts:SIMD4<Float>
}
nonisolated struct StormLobe {var centerRadius,shape:SIMD4<Float>}
nonisolated struct StormSegment {var a,b:SIMD4<Float>}
nonisolated struct StormFrame {var uniforms:StormUniforms;var lobes:[StormLobe];var bolts:[StormSegment]}

nonisolated enum StormScene {
 typealias V=SIMD3<Float>
 static func random(_ seed:Int,_ channel:Int)->Float {
  var x=UInt32(truncatingIfNeeded:seed)&*747796405 &+ UInt32(truncatingIfNeeded:channel)&*2891336453 &+ 277803737
  x=((x>>((x>>28)&+4))^x)&*277803737;x=(x>>22)^x
  return Float(x&0xffffff)/Float(0x1000000)
 }
 static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float {let t=max(0,min(1,(x-a)/(b-a)));return t*t*(3-2*t)}
 static func velocity(_ time:Float,_ sample:(Float)->SIMD4<Float>)->SIMD2<Float> {
  let a=sample(max(0,time-0.025)),b=sample(time+0.025)
  return simd_clamp(SIMD2(b.x-a.x,b.y-a.y)/0.05,SIMD2(repeating:-a.z*17),SIMD2(repeating:a.z*17))
 }
 static func frame(time:Float,size:SIMD2<Float>,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->StormFrame {
  let ball=sample(time),r=max(1,ball.z)
  var lobes=[StormLobe](),bolts=[StormSegment]()
  func cluster(_ birth:Float,_ seed:Int,_ side:Float,_ amount:Float,_ life:Float) {
   let age=time-birth;guard birth>=0,age>=0,age<life else{return}
   let b=sample(birth);guard b.w>0 else{return}
   let velocity=velocity(birth,sample),travel=(1-exp(-age*1.25))/1.25
   let angle:Float = side>0 ? -0.60+0.50*sin(Float(seed)*1.7):2.7+0.26*sin(Float(seed)*1.3)
   let dir=SIMD2(cos(angle),sin(angle)),normal=SIMD2(-dir.y,dir.x)
   let distance:Float=side>0 ? 1.7+random(seed,2)*0.95:0.98+random(seed,2)*0.32
   let initial=SIMD2(b.x,b.y)+dir*b.z*distance
   let drift=dir*b.z*(age*4.1)+normal*b.z*(sin(age*6+Float(seed))-sin(Float(seed)))*0.28
   let wake=sample(min(time,birth+0.24))
   let entrainment=SIMD2(wake.x-b.x,wake.y-b.y)*0.90
   let center=initial+velocity*travel*0.12+entrainment+drift+SIMD2<Float>(0,-age*age*b.z*0.7)
   let proximity=1-smooth(r*2.7,r*4.0,simd_distance(center,SIMD2(ball.x,ball.y)))
   let fade=smooth(0,0.035,age)*(1-smooth(life*0.45,life,age))*proximity
   let radius=b.z*(0.90+random(seed,3)*0.30)*(0.84+age*0.8)*amount
   let z=b.z*(-0.35+random(seed,4)*0.85)
   lobes.append(StormLobe(centerRadius:SIMD4(center.x,center.y,z,radius),shape:SIMD4(1.0,0.92,0.92,fade)))
   let bridge=center-dir*b.z*0.74
   lobes.append(StormLobe(centerRadius:SIMD4(bridge.x,bridge.y,z-b.z*0.35,radius*0.90),shape:SIMD4(1.1,0.92,0.85,fade*0.88)))
   // Interlocking lobes share one density field and shadow one another.
   for k in 0..<9 {
    let a=Float(k)*2.39996+Float(seed)*1.12+age*(side>0 ? 1.3:-1.1)
    let offset=V(cos(a)*0.70,sin(a)*0.66,sin(a*1.3)*0.32)*radius
    let rr=radius*(0.36+random(seed,k+21)*0.17)
    lobes.append(StormLobe(centerRadius:SIMD4(center.x+offset.x,center.y+offset.y,z+offset.z,rr),shape:SIMD4(1,1,1,fade*0.90)))
   }
  }
  if intensity>0 && ball.w>0 {
   // Brief continual emissions keep the body connected between impacts.
   let start=max(0,Int(floor((time-0.44)*20))),end=Int(floor(time*20))
   if end>=start {for i in start...end {cluster(Float(i)/20,1000+i,i%4==0 ? -1:1,0.93,0.44)}}
   for (event,t) in touches.enumerated() where time>=t && time-t<0.6 {
    for j in 0..<4 {cluster(t+0.025+Float(j)*0.025,event*71+j,j==2 ? -1:1,1.08,0.44)}
    let age=time-t
    // Short double flashes. A branch changes on the second pulse, never every frame.
    let pulse=exp(-pow((age-0.078)/0.022,2))*0.88+exp(-pow((age-0.145)/0.038,2))
    if pulse>0.025 {
     let b=sample(t+0.045),v=velocity(t+0.045,sample),dt=max(0,age-0.045)
     let wake=sample(min(time,t+0.045+0.24))
     let c=SIMD2(b.x,b.y)+SIMD2(wake.x-b.x,wake.y-b.y)*0.90+v*((1-exp(-dt*1.25))/1.25)*0.12
     let seed=event*101+(age>0.11 ? 1700:0),scale=b.z
     func path(_ start:V,_ finish:V,_ seed:Int,_ width:Float,_ n:Int)->[V] {
      var pts=[V]()
      let d=finish-start,normal=simd_normalize(V(-d.y,d.x,0))
      for i in 0...n {
       let s=Float(i)/Float(n),edge=sin(s*Float.pi)
       let curl=sin(s*8+Float(seed))*0.19+sin(s*17+Float(seed))*0.07
       let p=start+d*s+normal*((random(seed+i,1)-0.5)*0.28+curl)*edge
       pts.append(p)
       if i>0 {let a=pts[i-1],w=width*(1-s*0.55)
        bolts.append(StormSegment(a:SIMD4(c.x+a.x*scale,c.y+a.y*scale,a.z*scale,w*scale),b:SIMD4(c.x+p.x*scale,c.y+p.y*scale,p.z*scale,pulse*intensity)))
       }
      }
      return pts
     }
     let p=path(V(-1.0,0.7,0.45),V(3.3,-2.9,0.32),seed,0.026,23)
     for k in [6,10,13,17,20] {
      let sign:Float=k==13 ? -1:1
      _=path(p[k],p[k]+V(sign*0.7,-0.70,0.1),seed+k*13,0.011,7)
     }
    }
   }
  }
  var minimum=V(ball.x-r*4.5,ball.y-r*4.8,-r*2.6),maximum=V(ball.x+r*5,ball.y+r*4.5,r*2.6)
  for l in lobes {let c=V(l.centerRadius.x,l.centerRadius.y,l.centerRadius.z),s=l.centerRadius.w*1.15
   minimum=simd_min(minimum,c-V(repeating:s));maximum=simd_max(maximum,c+V(repeating:s))}
  minimum.x=max(-r,minimum.x);minimum.y=max(-r,minimum.y);maximum.x=min(size.x+r,maximum.x);maximum.y=min(1720,maximum.y)
  let extent=maximum-minimum
  let u=StormUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball,minimum:SIMD4(minimum.x,minimum.y,minimum.z,0),extent:SIMD4(extent.x,extent.y,extent.z,0),counts:SIMD4(Float(lobes.count),Float(bolts.count),0,0))
  return StormFrame(uniforms:u,lobes:lobes,bolts:bolts)
 }
}
