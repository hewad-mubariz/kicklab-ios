// Copied from the Effects Lab (EffectLab/FestivalScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum FestivalScene {
 typealias V=SIMD3<Float>
 static func random(_ seed:Int,_ channel:Int)->Float{var x=UInt32(truncatingIfNeeded:seed)&*747796405 &+ UInt32(truncatingIfNeeded:channel)&*2891336453 &+ 277803737;x=((x>>((x>>28)&+4))^x)&*277803737;x=(x>>22)^x;return Float(x&0xffffff)/Float(0x1000000)}
 static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float{let t=max(0,min(1,(x-a)/(b-a)));return t*t*(3-2*t)}
 static func xy(_ b:SIMD4<Float>)->SIMD2<Float>{SIMD2(b.x,b.y)}
 static func rotate(_ p:SIMD2<Float>,_ a:Float)->SIMD2<Float>{SIMD2(p.x*cos(a)-p.y*sin(a),p.x*sin(a)+p.y*cos(a))}
 static let palette:[V]=[V(1,0.22,0.12),V(1,0.69,0.015),V(0.015,0.66,0.77),V(0.12,0.31,0.92),V(0.97,0.86,0.62),V(0.97,0.07,0.42)]
 static func motion(_ birth:Float,_ time:Float,_ seed:Int,_ mode:Int,_ small:Bool,sample:(Float)->SIMD4<Float>)->FestivalParticle?{
  let age=time-birth,life:Float=(mode==13 ? 1.65:1.20)+random(seed,1)*0.35
  guard birth>=0,age>=0,age<life else{return nil};let b=sample(birth),r=b.z
  guard b.w>0,r>1 else{return nil}
  let previous=sample(max(0,birth-0.035)),next=sample(birth+0.035),velocity=simd_clamp((xy(next)-xy(previous))/0.07,SIMD2(repeating:-r*17),SIMD2(repeating:r*17))
  let side:Float=random(seed,2)<0.73 ? 1:-1
  let angle:Float = -0.78+(side<0 ? -1.85:0)+(random(seed,3)-0.5)*1.5
  let direction=SIMD2(cos(angle),sin(angle)),normal=SIMD2(-direction.y,direction.x)
  let initial=xy(b)+direction*r*(1.05+random(seed,4)*0.72)+normal*r*(random(seed,5)-0.5)*0.9
  let speed=r*(1.8+random(seed,6)*3.2)*(mode==1 ? 1.4:1)
  let v=direction*speed+velocity*(mode==13 ? 0.28:0.53)
  let drag:Float=mode==13 ? 1.5:0.72,travel=(1-exp(-drag*age))/drag
  let gravity:Float=mode==13 ? 1.4:mode==9 ? 4.8:2.9
  let p=initial+v*travel+SIMD2<Float>(0,r*gravity*age*age)+normal*(sin(age*5+Float(seed))-sin(Float(seed)))*r*(mode==13 ? 0.18:0.04)
  let z=r*(random(seed,7)-0.45)*2.7+r*(random(seed,8)-0.5)*age
  let prominent=random(seed,9)>0.72
  var scale=r*(small ? 0.035+random(seed,10)*0.09:prominent ? 0.42+random(seed,10)*0.24:0.13+random(seed,10)*0.19)
  if mode==11 {scale *= 0.86};if mode==13{scale *= 0.95};if mode==8{scale *= 1.25}
  let alpha=smooth(0,0.045,age)*(1-smooth(life-0.30,life,age))*b.w*(1-smooth(1600,1700,p.y))
  let spin:Float=mode==13 ? 7:mode==8 ? 1.6:4.8
  let angles=V((random(seed,11)-0.5)*1.6+age*(random(seed,12)-0.5)*spin,(random(seed,13)-0.5)*1.5+age*(random(seed,14)-0.5)*spin,random(seed,15)*6.28+age*(random(seed,16)-0.5)*spin)
  return FestivalParticle(id:seed,birth:birth,age:age,life:life,size:scale,alpha:alpha,center:V(p.x,p.y,z),angles:angles)
 }
 static func fluid(time:Float,size:SIMD2<Float>,mode:Int,intensity:Float,touches:[Float],sample:(Float)->SIMD4<Float>)->LiquidFrame{
  var parts=[LiquidPart]();let ball=sample(time)
  for(event,t) in touches.enumerated() where time>=t && time-t<1.05 {
   for lane in 0..<3 {
    let birth=t+0.022+Float(lane)*0.085,age=time-birth
    guard age>=0,age<LiquidFluid.lifetime else{continue}
    let b=sample(birth);guard b.w>0 else{continue}
    let seed=event*3+lane,r=b.z*(lane==0 ? 1.12:0.70)
    let theta:Float=2.7+random(seed,3)*1.1+Float(lane)*0.28
    let vel=LiquidScene.velocity(at:birth,sample:sample)*0.68
    let base=xy(b)+vel*((1-exp(-age*0.8))/0.8)
    let fade=smooth(0,0.035,age)*(1-smooth(0.57,0.92,age))
    for(i,atom) in FestivalFluid.sample(age:age,seed:seed,medium:mode).enumerated(){
     // Rotate the launch frame while gravity stays in video coordinates.
     let falling=SIMD2<Float>(0,(mode==0 ? 4.25:mode==6 ? 2.9:1.95)*age*age),local=rotate(SIMD2(atom.p.x,atom.p.y)-falling,theta)+falling
     let p=base+local*r
     let xx=atom.covariance.x,yy=atom.covariance.z,xy=atom.covariance.y,disc=sqrt((xx-yy)*(xx-yy)+4*xy*xy),tr=xx+yy
     let stretch=min(2.6,max(1,pow((tr+disc)/max(0.0001,tr-disc),0.29)))
     let angle=0.5*atan2(2*xy,xx-yy)+theta
     let radius=r*(mode==0 ? 0.078:0.091)*sqrt(atom.volume)*sqrt(fade)
     if radius>0.25 {parts.append(LiquidPart(centerSize:SIMD4(p.x,p.y,atom.p.z*r,radius),shape:SIMD4(stretch,1/stretch,angle,1),material:SIMD4(mode==0 ? Float(lane)/2:atom.dye,Float(seed*1000+i),age,0)))}
    }
   }
  }
  return LiquidFrame(uniforms:LiquidUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball,options:SIMD4(Float(mode),0,1,Float(parts.count))),parts:parts)
 }
 static func frame(time:Float,size:SIMD2<Float>,mode:Int,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->FestivalFrame{
  let ball=sample(time),u=LiquidUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball,options:SIMD4(Float(mode),0,0,0))
  guard intensity>0,ball.w>0,ball.z>1 else{return FestivalFrame(uniforms:u,vertices:[],puffs:[],liquid:nil,particles:[])}
  var mesh=FestivalMesh(),particles=[FestivalParticle](),puffs=[FestivalPuff]()
  let isFluid=[0,6,10].contains(mode)
  let liquid=isFluid ? fluid(time:time,size:size,mode:mode,intensity:intensity,touches:touches,sample:sample):nil
  // IDs: Paint, Solar, Vector, Victory, Storm, Coin, Slime, Toy,
  // Music, Popcorn, Bubblegum, Disco, Rubber, Party, Star.
  let actualCounts:[Int]=[7,25,0,12,0,9,7,12,7,13,7,20,4,48,9]
  let rate:[Float]=[4,10,0,4,0,3,4,5,2,7,4,7,1.2,12,4]
  func add(_ birth:Float,_ seed:Int,_ small:Bool=false,_ hero:Int = -1){if var p=motion(birth,time,seed,mode,small,sample:sample){
   if hero>=0 && hero<2 {
    let b=sample(birth),r=b.z
    if [3,5,7,8,9,12,14].contains(mode) {p.size=r*(hero==0 ? 0.63:0.45)*(mode==9 ? 0.85:mode==12 ? 0.82:mode==8 ? 1.42:1)}
    if [5,8].contains(mode) {p.angles.x=0.23+0.4*sin(p.age*3+Float(seed));p.angles.y=0.42+0.5*sin(p.age*4+Float(seed));p.angles.z=(hero==0 ? -0.2:0.35)+0.25*sin(p.age*4+Float(seed))}
   }
   p.alpha*=intensity;particles.append(p)}}
  for(event,t) in touches.enumerated() where time>=t && time-t<2.0 {
   for j in 0..<actualCounts[mode]{add(t+Float(j)*0.013,10000+event*137+j,j>actualCounts[mode]*2/3,j)}
  }
  if rate[mode]>0 {let start=max(0,Int(floor((time-1.8)*rate[mode]))),end=Int(floor(time*rate[mode]));if end>=start{for i in start...end{add(Float(i)/rate[mode],1000000+i,true)}}}
  particles.sort{$0.center.z<$1.center.z}
  for var p in particles {
   mesh=withMaterial(mesh,mode:mode,seed:p.id)
   if mode==0 || mode==6 || mode==10 {p.size*=0.60}
   mesh.transform(p)
   switch mode {
    case 0:mesh.sphere(.zero,V(0.72,1.25,0.72),steps:10)
    case 1:mesh.shard(p.id)
    case 3:if p.id%5==0 {mesh.color=V(0.88,0.93,1);mesh.confetti(age:p.age,seed:p.id,streamer:false)}else{mesh.star()}
    case 5:mesh.coin()
    case 6:mesh.sphere(.zero,V(1,1.1+0.15*sin(p.age*11),1),steps:14)
    case 7:mesh.box()
    case 8:mesh.note(double:p.id%3==0)
    case 9:mesh.popcorn(p.id)
    case 10:mesh.sphere(.zero,V(repeating:1),steps:18)
    case 11:mesh.confetti(age:p.age,seed:p.id,streamer:false)
    case 12:mesh.spring(age:p.age,seed:p.id)
    case 13:mesh.confetti(age:p.age,seed:p.id,streamer:p.id%7==0)
    case 14:mesh.star(round:true)
    default:break
   }
   if [1,3,5,11].contains(mode) && p.id%4==0 {
    let pulse=pow(max(0,sin(time*9+Float(p.id))),14)*p.alpha
    if pulse>0.08 {puffs.append(FestivalPuff(centerRadius:SIMD4(p.center.x,p.center.y,p.center.z+3,max(6,p.size*0.62)),shape:SIMD4(1,1,0,1),color:SIMD4(1,0.87,0.57,pulse),detail:SIMD4(1,0,0,0)))}
   }
  }
  // Slashes have an advancing head, a tapered tail and age-specific curl.
  // Their released centres retain inertia rather than following a rigid ring.
  if mode==2 {
   for(event,t) in touches.enumerated() where time>=t && time-t<0.82 {
    for blade in 0..<4 {
     let birth=t+Float(blade)*0.065,age=time-birth;guard age>=0,age<0.62 else{continue}
     let b=sample(birth),r=b.z,vel=LiquidScene.velocity(at:birth,sample:sample),centre=xy(b)+vel*age*0.65
     let alpha=smooth(0,0.04,age)*(1-smooth(0.35,0.62,age))*intensity
     let angle=Float(blade)*1.65+Float(event)*0.59+age*(blade%2==0 ? 5:-4)
     mesh.center=V(centre.x,centre.y,-r*0.05);mesh.scale=r;mesh.rotation=simd_quatf(angle:angle,axis:V(0,0,1));mesh.alpha=alpha
     for layer in 0..<3 {mesh.color=layer==0 ? V(0.62,0.004,0.03):layer==1 ? V(1,0.015,0.05):V(1,0.93,0.90);mesh.material=SIMD4(0.2,0,layer==2 ? 8:3,0)
      func point(_ i:Int,_ edge:Float)->V{let s=Float(i)/30,a = -1.2+s*2.6,rr=1.25+s*(0.8+age*1.8),width=pow(sin(s*Float.pi),0.8)*(layer==0 ? 0.18:layer==1 ? 0.12:0.04)
       return V(cos(a)*(rr+edge*width),sin(a)*(rr+edge*width)*0.67,Float(layer)*0.02+sin(a)*0.3)}
      for i in 0..<30 {mesh.quad(point(i,-1),point(i,1),point(i+1,1),point(i+1,-1))}
     }
    }
   }
  }
  if mode==4 {
   let rate:Float=36,start=max(0,Int((time-0.64)*rate)),end=Int(time*rate)
   if end>=start {for i in start...end {
    let birth=Float(i)/rate,age=time-birth,b=sample(birth),r=b.z;guard b.w>0 else{continue}
    let theta:Float=i%6==0 ? 2.0+random(i,1): -1.2+random(i,1)*1.15;let dir=SIMD2(cos(theta),sin(theta)),v=simd_clamp(LiquidScene.velocity(at:birth,sample:sample),SIMD2(repeating:-r*5.5),SIMD2(repeating:r*5.5))
    let centre=xy(b)+dir*r*(1.25+age*0.8)+v*age*0.45+SIMD2<Float>(r*age*2.2,-r*age*0.3)
    let alpha=smooth(0,0.08,age)*(1-smooth(0.35,0.64,age))*0.97*intensity
    puffs.append(FestivalPuff(centerRadius:SIMD4(centre.x,centre.y,-r*0.4,r*(0.48+random(i,2)*0.24)*(1+age*0.6)),shape:SIMD4(1.1,1,random(i,3)*6.28,0),color:SIMD4(0.23,0.29,0.37,alpha),detail:SIMD4(0,Float(i)*13.1,age,0)))
    let offset=SIMD2<Float>(-dir.y,dir.x)*r*0.48
    for side:Float in [-1,1] {let c=centre+offset*side+dir*r*0.35;puffs.append(FestivalPuff(centerRadius:SIMD4(c.x,c.y,-r*0.4,r*(0.32+random(i,9)*0.21)*(1+age*0.55)),shape:SIMD4(1.1,1,random(i,3)*6.28,0),color:SIMD4(0.23,0.29,0.37,alpha*0.83),detail:SIMD4(0,Float(i)*13.1+side*12,age,0)))}
   }}
   for(event,t) in touches.enumerated() where time>=t && time-t<0.34 {
    let age=time-t,flash=(age<0.20) ? Float(1):Float(0.22),b=sample(t+0.085),r=b.z
    mesh.center=V(b.x,b.y,0);mesh.scale=r;mesh.rotation=simd_quatf(angle:0.15*sin(Float(event)*0.71),axis:V(0,0,1));mesh.alpha=flash*intensity;mesh.color=V(0.35,0.66,1);mesh.material=SIMD4(0,0,8,0)
    let pts=(0...24).map{i->V in let s=Float(i)/24;return V(0.75+s*2.1+(random(event*71+i,2)-0.5)*0.19,0.2-s*2.6+(random(event*71+i,3)-0.5)*0.19,0.2)}
    mesh.alpha=flash*intensity*0.20;mesh.color=V(0.15,0.39,1);mesh.tube(pts,radii:[0.07],sides:6)
    mesh.alpha=flash*intensity;mesh.color=V(0.44,0.72,1);mesh.tube(pts.map{$0+V(0,0,0.09)},radii:[0.021],sides:6)
    mesh.color=V(0.95,0.99,1);mesh.tube(pts.map{$0+V(0,0,0.13)},radii:[0.010],sides:6)
    for i in [6,12,18]{let p=pts[i]+V(0,0,0.13);mesh.tube([p,p+V(0.22,-0.08,0),p+V(0.28,-0.37,0),p+V(0.61,-0.55,0),p+V(0.70,-0.90,0)],radii:[0.012,0.010,0.007,0.004,0.001],sides:5)}

   }
  }
  if mode==14 {
   mesh.center = .zero;mesh.scale=1;mesh.rotation=simd_quatf(angle:0,axis:V(0,0,1));mesh.material=SIMD4(0,0,8,0)
   for p in particles where p.size>ball.z*0.18 {
    for lane in 0..<3 {mesh.color=lane==1 ? V(0.80,0.95,1):V(0.16,0.55,1)
     for k in 0..<10 {
      let lag=Float(k)*0.022,t0=time-lag,t1=t0-0.022
      guard let a=motion(p.birth,t0,p.id,mode,false,sample:sample),let b=motion(p.birth,t1,p.id,mode,false,sample:sample) else{continue}
      let d=b.center-a.center;guard simd_length(d)>0.01 else{continue}
      let n=simd_normalize(V(-d.y,d.x,0)),offset=n*Float(lane-1)*p.size*0.09,w=p.size*(0.023+Float(10-k)*0.005)
      mesh.alpha=p.alpha*(1-Float(k)/10)*0.62
      mesh.quad(a.center+offset+n*w,a.center+offset-n*w,b.center+offset-n*w,b.center+offset+n*w)
     }
    }
   }
  }
  if mode==14 || mode==11 {
   mesh.center = .zero;mesh.scale=1;mesh.rotation=simd_quatf(angle:0,axis:V(0,0,1));mesh.material=SIMD4(0,0,8,0)
   for lane in 0..<5 {
    mesh.color=mode==14 ? (lane%2==0 ? V(0.24,0.68,1):V(0.8,0.94,1)):palette[lane]
    for i in 0..<28 {let s=Float(i)/28,age=s*0.53,a=sample(max(0,time-age)),b=sample(max(0,time-age-0.019));guard a.w>0,b.w>0 else{continue}
     let d=xy(a)-xy(b);guard simd_length(d)>0.1 else{continue};let n=simd_normalize(SIMD2(-d.y,d.x)),offset=Float(lane-2)*a.z*0.10
     let pa=xy(a)+n*offset,pb=xy(b)+n*offset,width=max(0.7,a.z*(1-s)*0.018)
     mesh.alpha=(1-s)*0.55*intensity
     mesh.quad(V(pa.x+n.x*width,pa.y+n.y*width,-a.z),V(pa.x-n.x*width,pa.y-n.y*width,-a.z),V(pb.x-n.x*width,pb.y-n.y*width,-b.z),V(pb.x+n.x*width,pb.y+n.y*width,-b.z))
    }
   }
  }
  return FestivalFrame(uniforms:u,vertices:mesh.vertices,puffs:puffs,liquid:liquid,particles:particles)
 }
 static func withMaterial(_ value:FestivalMesh,mode:Int,seed:Int)->FestivalMesh {
  var m=value;m.color=V(1,0.66,0.13);m.material=SIMD4(0.23,1,1,Float(seed))
  switch mode {
   case 0:m.color=[V(1,0.015,0.42),V(0.76,0.96,0.01),V(0.025,0.12,0.95)][seed%3];m.material=SIMD4(0.15,0,3,0)
   case 6:m.color=V(0.58,0.91,0.015);m.material=SIMD4(0.08,0,6,0)
   case 7:m.color=palette[seed%5];m.material=SIMD4(0.24,0,3,0)
   case 8:m.color=[V(0.04,0.76,0.85),V(1,0.20,0.30),V(1,0.53,0.06)][seed%3];m.material=SIMD4(0.14,0.7,3,0)
   case 9:m.color=V(1,0.91,0.62);m.material=SIMD4(0.82,0,7,0)
   case 10:m.color=seed%5==0 ? V(0.1,0.75,0.90):V(1,0.14,0.48);m.material=SIMD4(0.12,0,6,0)
   case 11:m.color=V(0.93,0.97,1);m.material=SIMD4(0.08,1,2,0)
   case 12:m.color=[V(1,0.26,0.025),V(0.035,0.75,0.77),V(1,0.74,0.01)][seed%3];m.material=SIMD4(0.32,0,4,0)
   case 13:m.color=palette[seed%6];m.material=SIMD4(0.28,seed%3==0 ? 0.8:0,5,0)
   case 14:m.material=SIMD4(0.20,0.55,3,0);m.color=V(1,0.76,0.055)
   default:break
  }
  return m
 }
}
