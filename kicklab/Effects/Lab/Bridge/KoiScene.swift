// Copied from the Effects Lab (EffectLab/KoiScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct KoiUniforms {var viewport,ball:SIMD4<Float>}
nonisolated struct KoiVertex:Equatable {var position,normal,color,uv:SIMD4<Float>}
nonisolated struct KoiFish:Equatable {
 var id:Int;var center:SIMD3<Float>;var size,heading,bank,pitch,phase,bend,effort,alpha:Float
}
nonisolated struct KoiBead:Equatable {var id:Int;var birth:Float;var center:SIMD3<Float>;var radius,alpha:Float}
nonisolated struct KoiFrame {var uniforms:KoiUniforms;var vertices:[KoiVertex];var fish:[KoiFish];var beads:[KoiBead]}
nonisolated struct KoiFinAnchor {var root,direction,side,normal:SIMD3<Float>}

nonisolated enum KoiScene {
 typealias V=SIMD3<Float>
 static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float {let t=max(0,min(1,(x-a)/(b-a)));return t*t*(3-2*t)}
 static func random(_ seed:Int,_ channel:Int)->Float {
  var x=UInt32(truncatingIfNeeded:seed)&*747796405 &+ UInt32(channel)&*2891336453 &+ 277803737
  x=((x>>((x>>28)&+4))^x)&*277803737;x=(x>>22)^x
  return Float(x&0xffffff)/Float(0x1000000)
 }
 static func pose(id:Int,time:Float,touches:[Float],sample:(Float)->SIMD4<Float>)->KoiFish {
  let b=sample(time),r=max(1,b.z),k=Float(id)
  // A history filter eases acceleration, while the mean velocity steers the head.
  var follow=SIMD2<Float>(repeating:0),velocity=SIMD2<Float>(repeating:0),sum:Float=0
  for i in 0..<16 {
   let dt=Float(i)/60+k*0.015,w=exp(-Float(i)*0.22),t=max(0,time-dt),a=sample(t),before=sample(max(0,t-0.045))
   follow+=SIMD2(a.x,a.y)*w;velocity+=SIMD2(a.x-before.x,a.y-before.y)*(w/0.045);sum+=w
  }
  follow/=sum;velocity/=sum
  var lag=follow-SIMD2(b.x,b.y);let lagLength=simd_length(lag)
  if lagLength>0.001 {lag *= (r*1.25*tanh(lagLength/(r*1.25)))/lagLength}
  var phase=time*(id==0 ? 5.7:6.2)+k*2.2,impulse:Float=0
  for touch in touches where touch<=time {
   let age=time-touch
   // Zero initial slope prevents the tail and centre from jolting on contact.
   phase+=0.44*(1-(1+age*5)*exp(-age*5))
   impulse+=age*age*28*exp(-age*6)
  }
  let swim=time*(id==0 ? 0.90:0.77)+k*1.7
  let x:Float=id==0 ? 2.20+0.35*sin(swim):(-1.62+0.28*sin(swim+0.8))
  let y:Float=id==0 ? -1.95+0.28*sin(swim*1.23+1):(-0.10+0.22*cos(swim*1.18))
  let baseHeading:Float=id==0 ? 3.00+0.22*sin(swim+0.4):(-1.55+0.28*sin(swim+1.3))
  let baseDirection=SIMD2(cos(baseHeading),sin(baseHeading))
  let steer:Float=0.46*tanh((baseDirection.x*velocity.y-baseDirection.y*velocity.x)/(r*11))
  let heading=baseHeading+steer
  let length=r*(id==0 ? 1.95:1.65),forward=SIMD2(cos(heading),sin(heading))
  var centre=SIMD2(b.x,b.y)+lag*0.48+SIMD2(x,y)*r+forward*r*impulse*0.18
  // Keep the face readable while the fins can pass behind the ball.
  let head=centre+forward*length*0.40-SIMD2(b.x,b.y),headDistance=simd_length(head)
  if headDistance<r*1.40 {centre+=head/max(0.001,headDistance)*(r*1.40-headDistance)}
  let effort=0.64+0.22*tanh(simd_length(velocity)/(r*9))+0.22*min(1,impulse)
  return KoiFish(id:id,center:V(centre.x,centre.y,r*(0.25+0.36*sin(swim+k))),size:length,heading:heading,bank:0.10*sin(swim*0.8+k)+(id==0 ? 0.60:-0.42)-steer*0.32,pitch:0.06*sin(swim*0.9+k),phase:phase,bend:(id==0 ? 0.18:0.50)+0.10*sin(swim)-steer*0.25,effort:effort,alpha:b.w*smooth(0,0.22,time))
 }
 static func spineAxes(_ u:Float,_ f:KoiFish)->(V,V,V) {
  let mask=smooth(0.10,1.0,u),coast=0.88+0.12*sin(f.phase*0.47)
  let angle=f.bend*1.55*smooth(0.05,1.05,u)+0.38*mask*f.effort*coast*sin(f.phase-u*3.8)
  let roll:Float=0.025*mask*sin(f.phase-u*3+0.6)
  let tangent=V(-cos(angle)*cos(roll),sin(angle)*cos(roll),sin(roll)),side=V(sin(angle),cos(angle),0)
  return (tangent,side,simd_normalize(simd_cross(side,tangent)))
 }
 static func tailAnchor(_ f:KoiFish)->KoiFinAnchor {
  let rotation=simd_quatf(angle:f.heading,axis:V(0,0,1))*simd_quatf(angle:f.pitch,axis:V(0,1,0))*simd_quatf(angle:f.bank,axis:V(1,0,0))
  var root=V(0.55,0,0)
  for i in 0..<64 {root+=spineAxes((Float(i)+0.5)/64,f).0*(1.4/64)}
  let axes=spineAxes(1,f)
  return KoiFinAnchor(root:rotation.act(root)*f.size+f.center,direction:rotation.act(axes.0),side:rotation.act(axes.1),normal:rotation.act(axes.2))
 }
 static func mesh(_ f:KoiFish,history:[KoiFish]=[])->[KoiVertex] {
  var vertices=[KoiVertex]();vertices.reserveCapacity(30000)
  let rotation=simd_quatf(angle:f.heading,axis:V(0,0,1))*simd_quatf(angle:f.pitch,axis:V(0,1,0))*simd_quatf(angle:f.bank,axis:V(1,0,0))
  // Integrate unit-length spine segments instead of displacing a straight
  // mesh sideways. Each cross-section rotates with its tangent: no rubber stretch.
  var spine=[V(0.55,0,0)],sides=[V](),backs=[V]()
  let segments=128,step:Float=2/128
  func axes(_ u:Float)->(V,V,V) {
   spineAxes(u,f)
  }
  for i in 0...segments {
   let u=Float(i)*step,a=axes(u);sides.append(a.1);backs.append(a.2)
   if i<segments {spine.append(spine[i]+axes(u+step*0.5).0*(1.4*step))}
  }
  func deform(_ p:V)->V {
   let u=max(0,min(2,(0.55-p.x)/1.4)),slot=u/step,i=min(segments-1,Int(slot)),t=slot-Float(i)
   let centre=spine[i]+(spine[i+1]-spine[i])*t
   let side=simd_normalize(sides[i]+(sides[i+1]-sides[i])*t),back=simd_normalize(backs[i]+(backs[i+1]-backs[i])*t)
   return centre+side*p.y+back*p.z
  }
  func vertex(_ p:V,_ n:V,_ uv:SIMD2<Float>,_ kind:Float,_ tint:V,_ alpha:Float)->KoiVertex {
   let world=rotation.act(p)*f.size+f.center,normal=rotation.act(n)
   return KoiVertex(position:SIMD4(world.x,world.y,world.z,1),normal:SIMD4(normal.x,normal.y,normal.z,kind),color:SIMD4(tint.x,tint.y,tint.z,alpha*f.alpha),uv:SIMD4(uv.x,uv.y,Float(f.id),f.phase))
  }
  // Parametric normals follow deformation; fins and body remain rounded in motion.
  func surface(_ nu:Int,_ nv:Int,_ kind:Float,_ tint:V,_ alpha:Float,world:Bool=false,_ point:(Float,Float)->V) {
   func transformed(_ u:Float,_ v:Float)->V {let p=point(u,v);return world ? p:deform(p)}
   var grid=[KoiVertex]();grid.reserveCapacity((nu+1)*(nv+1))
   for i in 0...nu {for j in 0...nv {
    let u=Float(i)/Float(nu),v=Float(j)/Float(nv),e:Float=0.0005
    let p=transformed(u,v),du=transformed(min(1,u+e),v)-transformed(max(0,u-e),v),dv=transformed(u,min(1,v+e))-transformed(u,max(0,v-e))
    let cross=simd_cross(du,dv),n=simd_length_squared(cross)>1e-14 ? simd_normalize(cross):V(0,0,1)
    if world {
     grid.append(KoiVertex(position:SIMD4(p.x,p.y,p.z,1),normal:SIMD4(n.x,n.y,n.z,kind),color:SIMD4(tint.x,tint.y,tint.z,alpha*f.alpha),uv:SIMD4(u,v,Float(f.id),f.phase)))
    } else {grid.append(vertex(p,n,SIMD2(u,v),kind,tint,alpha))}
   }}
   for i in 0..<nu {for j in 0..<nv {
    let a=i*(nv+1)+j,b=a+nv+1
    vertices += [grid[a],grid[b],grid[a+1],grid[a+1],grid[b],grid[b+1]]
   }}
  }
  func radius(_ u:Float)->Float {
   let knots:[SIMD2<Float>]=[SIMD2(0,0.045),SIMD2(0.08,0.15),SIMD2(0.20,0.245),SIMD2(0.36,0.267),SIMD2(0.54,0.208),SIMD2(0.74,0.123),SIMD2(0.91,0.060),SIMD2(1,0.038)]
   for i in 0..<knots.count-1 where u<=knots[i+1].x {
    let a=knots[i],b=knots[i+1],p=knots[max(0,i-1)],n=knots[min(knots.count-1,i+2)],d=b.x-a.x,t=max(0,min(1,(u-a.x)/d))
    let ma=(b.y-p.y)/(b.x-p.x),mb=(n.y-a.y)/(n.x-a.x)
    return (2*t*t*t-3*t*t+1)*a.y+(t*t*t-2*t*t+t)*d*ma+(-2*t*t*t+3*t*t)*b.y+(t*t*t-t*t)*d*mb
   }
   return 0.038
  }
  surface(80,48,0,V(1,1,1),1) {u,v in
   let t=v*2*Float.pi,r=radius(u)
   return V(0.55-1.4*u,r*cos(t),r*0.84*sin(t))
  }
  let finTint:V=f.id==0 ? V(1,0.91,0.78):V(0.74,0.97,0.90)
  // Ray chains use delayed world-space tail anchors. On a rise or fall the
  // base follows first, then the membrane and fine ends. Segment projections
  // keep the long fins from stretching when the ball changes direction.
  let past:[KoiFish]=history.isEmpty ? (0..<20).map {i in
   var p=f;p.phase-=Float(i)*0.035*(f.id==0 ? 5.7:6.2);return p
  }:history
  let anchors=past.map{tailAnchor($0)},current=tailAnchor(f)
  func delayed(_ delay:Float)->KoiFinAnchor {
   let slot=min(Float(anchors.count-1),max(0,delay/0.035)),i=min(anchors.count-2,Int(slot)),t=slot-Float(i)
   let p=anchors[max(0,i-1)],a=anchors[i],b=anchors[i+1],n=anchors[min(anchors.count-1,i+2)]
   func blend(_ p:V,_ a:V,_ b:V,_ n:V)->V {
    let m=(b-p)*0.5,q=(n-a)*0.5
    return a*(2*t*t*t-3*t*t+1)+m*(t*t*t-2*t*t+t)+b*(-2*t*t*t+3*t*t)+q*(t*t*t-t*t)
   }
   return KoiFinAnchor(root:blend(p.root,a.root,b.root,n.root),direction:simd_normalize(blend(p.direction,a.direction,b.direction,n.direction)),side:simd_normalize(blend(p.side,a.side,b.side,n.side)),normal:simd_normalize(blend(p.normal,a.normal,b.normal,n.normal)))
  }
  for side:Float in [-1,1] {
   let rayCount=28,nodeCount=64,maxS:Float=1.46
   var rays=[[V]]()
   for ray in 0...rayCount {
    let v=Float(ray)/Float(rayCount),across=v*2-1
    let reach:Float=0.94+0.38*abs(across),spread=side*(0.37+across*0.30)
    let restStep=f.size*sqrt(reach*reach+spread*spread)*maxS/Float(nodeCount)
    let root=current.root+current.side*(side*0.012*f.size)
    var chain=[root],direction=simd_normalize(current.direction*reach+current.side*spread)
    func guide(_ s:Float)->V {
     let a=delayed(s*0.36),delta=a.root-current.root,distance=simd_length(delta),limit=f.size*1.25
     let lag=delta*(limit*tanh(distance/limit)/max(0.0001,distance))*(0.65*smooth(0,0.65,s))
     let wave=sin(f.phase-s*3.3+side*0.16)*s*s*(0.06+0.05*f.effort)
     let lift=sin(f.phase*0.84-s*2.7+side*0.24)*s*s*0.085
     return root+lag+a.direction*(reach*s*f.size)+a.side*((spread*s+wave)*f.size)+a.normal*(sin(f.phase-s*3.5)*s*0.045*f.size)+V(0,lift*f.size,0)
    }
    for i in 1...nodeCount {
     let s=(Float(i)-0.5)*maxS/Float(nodeCount),delta=guide(s+0.008)-guide(max(0,s-0.008))
     if simd_length_squared(delta)>0.00001 {
      let desired=simd_normalize(delta),angle=acos(max(-1,min(1,simd_dot(direction,desired))))
      // Integrate the guide tangent rather than chasing its position. This
      // avoids folding back when a long ray overshoots a slowed guide point.
      let fraction:Float=angle>0.0001 ? min(0.65,0.085/angle):1
      let axis=simd_cross(direction,desired)
      if simd_length_squared(axis)>0.000001 {direction=simd_quatf(angle:angle*fraction,axis:simd_normalize(axis)).act(direction)}
     }
     chain.append(chain[i-1]+direction*restStep)
    }
    rays.append(chain)
   }
   func tail(_ s:Float,_ v:Float)->V {
    let slot=min(Float(nodeCount),max(0,s/maxS*Float(nodeCount))),i=min(nodeCount-1,Int(slot)),t=slot-Float(i)
    let raySlot=min(Float(rayCount),max(0,v*Float(rayCount))),j=min(rayCount-1,Int(raySlot)),w=raySlot-Float(j)
    let a=rays[j][i]+(rays[j][i+1]-rays[j][i])*t,b=rays[j+1][i]+(rays[j+1][i+1]-rays[j+1][i])*t
    return a+(b-a)*w
   }
   surface(56,28,1.1,finTint,0.60,world:true,tail)
   // Fine ray extensions continue beyond the membrane as tapered filaments.
   for ray in 0..<7 {
    let v=Float(ray)/6
    surface(24,2,2,finTint,0.58,world:true) {s,w in
     let t=1+s*(0.22+0.22*sin(v*5+1)*sin(v*5+1)),p=tail(t,v)
     return p+current.side*((w-0.5)*0.006*(1-s)*f.size)
    }
   }
   // Paired pectoral fins fan out behind the gills, with their own phase.
   surface(28,24,1,finTint,0.54) {s,v in
    let flap=sin(f.phase*0.50+side*0.3)
    let x=0.18-s*(0.23+0.37*v)
    let y=side*(0.20+sin(s*Float.pi*0.68)*(0.30+0.035*flap)*sin(Float.pi*(0.18+v*0.65)))
    let z=0.055+sin(s*Float.pi)*0.07+s*flap*0.065+0.007*sin(v*Float.pi*24)*s
    return V(x,y,z)
   }
   // Smaller pelvic fins add another depth layer without becoming a halo.
   surface(18,16,1,finTint,0.44) {s,v in
    V(-0.22-s*(0.20+0.30*v),side*(0.13+s*0.23*sin(v*Float.pi)),0.01+s*0.08*sin(f.phase*0.63+side))
   }
  }
  surface(36,12,1,finTint,0.52) {u,v in
   let t=0.27+u*0.55
   return V(0.55-1.4*t,-v*0.055,radius(t)*0.84+v*sin(u*Float.pi)*0.18+v*0.012*sin(f.phase-u*3))
  }
  func sphere(_ centre:V,_ scale:V,_ kind:Float,_ tint:V) {
   surface(12,20,kind,tint,1) {u,v in
    let a=u*Float.pi,b=v*Float.pi*2
    return centre+V(sin(a)*cos(b),sin(a)*sin(b),cos(a))*scale
   }
  }
  for side:Float in [-1,1] {
   let eye=V(0.37,side*0.11,0.123)
   sphere(eye,V(0.036,0.029,0.022),3,V(0.45,0.41,0.28))
   sphere(eye+V(0.004,side*0.003,0.018),V(0.022,0.020,0.014),3,V(0.016,0.022,0.022))
   sphere(V(0.465,side*0.044,0.077),V(0.008,0.006,0.004),3,V(0.24,0.25,0.20))
   // Short carp barbels, not long fantasy antennae.
   surface(18,6,3,V(0.91,0.84,0.64),0.83) {u,v in
    let t=v*2*Float.pi,width:Float=0.005*(1-u)+0.001
    return V(0.51+u*0.09,side*(0.045+u*0.08),0.005-u*u*0.055)+V(0,cos(t)*width,sin(t)*width)
   }
  }
  // Recessed mouth rim at the nose.
  surface(20,8,3,V(0.46,0.35,0.24),1) {u,v in
   let a=u*Float.pi*2,t=v*Float.pi*2
   return V(0.554+0.004*cos(t),cos(a)*(0.027+0.003*sin(t)),sin(a)*(0.018+0.003*sin(t)))
  }
  return vertices
 }
 static func beadMesh(_ b:KoiBead)->[KoiVertex] {
  var vertices=[KoiVertex]()
  func at(_ u:Float,_ v:Float)->KoiVertex {
   let a=u*Float.pi,t=v*Float.pi*2,n=V(sin(a)*cos(t),sin(a)*sin(t),cos(a)),p=b.center+n*b.radius
   return KoiVertex(position:SIMD4(p.x,p.y,p.z,1),normal:SIMD4(n.x,n.y,n.z,4),color:SIMD4(0.80,0.95,0.96,b.alpha),uv:SIMD4(u,v,0,0))
  }
  for i in 0..<8 {for j in 0..<12 {
   let u=Float(i)/8,v=Float(j)/12,du:Float=1/8,dv:Float=1/12
   vertices += [at(u,v),at(u+du,v),at(u,v+dv),at(u,v+dv),at(u+du,v),at(u+du,v+dv)]
  }}
  return vertices
 }
 static func frame(time:Float,size:SIMD2<Float>,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->KoiFrame {
  let ball=sample(time)
  let fish=(0..<2).map{pose(id:$0,time:time,touches:touches,sample:sample)}
  var beads=[KoiBead]()
  func bead(_ birth:Float,_ seed:Int,_ id:Int,_ impact:Bool) {
   let age=time-birth,life:Float=0.85+random(seed,1)*0.55
   guard birth>=0,age>=0,age<life else{return}
   let b=sample(birth),f=pose(id:id,time:birth,touches:touches,sample:sample),r=max(1,b.z)
   let angle=f.heading+Float.pi+(random(seed,2)-0.5)*1.3
   let direction=SIMD2(cos(angle),sin(angle))
   let origin=SIMD2(f.center.x,f.center.y)+direction*f.size*0.85
   let speed=r*(0.4+random(seed,3)*1.4)*(impact ? 1.3:1)
   let p=origin+direction*speed*(1-exp(-age*1.2))/1.2+SIMD2<Float>(0,r*age*age*0.8)
   let alpha=smooth(0,0.06,age)*(1-smooth(life-0.32,life,age))*b.w*intensity
   let radius=r*(seed%5==0 ? 0.065+0.035*random(seed,5):0.018+0.033*pow(random(seed,5),2))
   beads.append(KoiBead(id:seed,birth:birth,center:V(p.x,p.y,f.center.z+r*(random(seed,4)-0.5)),radius:radius,alpha:alpha))
  }
  let rate:Float=8,start=max(0,Int(floor((time-1.5)*rate))),end=Int(floor(time*rate))
  if end>=start {for i in start...end {bead(Float(i)/rate,10000+i,i%2,false)}}
  for (event,touch) in touches.enumerated() where time-touch<1.6 && time>=touch {
   for j in 0..<5 {bead(touch+Float(j)*0.035,100000+event*10+j,j%2,true)}
  }
  let all=fish.flatMap {f in
   let history=(0..<20).map{i in pose(id:f.id,time:max(0,time-Float(i)*0.035),touches:touches,sample:sample)}
   return mesh(f,history:history)
  }+beads.flatMap{beadMesh($0)}
  // Back-to-front triangles retain overlapping translucent fins with depth tests.
  var order=Array(stride(from:0,to:all.count,by:3))
  order.sort {a,b in
   let za=all[a].position.z+all[a+1].position.z+all[a+2].position.z,zb=all[b].position.z+all[b+1].position.z+all[b+2].position.z
   return za==zb ? a<b:za<zb
  }
  var vertices=[KoiVertex]();vertices.reserveCapacity(all.count)
  for i in order {vertices.append(contentsOf:all[i..<i+3])}
  return KoiFrame(uniforms:KoiUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball),vertices:vertices,fish:fish,beads:beads)
 }
}
