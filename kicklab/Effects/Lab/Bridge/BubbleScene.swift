// Copied from the Effects Lab (EffectLab/BubbleScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct BubbleUniforms {var viewport,ball:SIMD4<Float>}
nonisolated struct BubbleSphere:Equatable {var centerSize,shape,film:SIMD4<Float>}
nonisolated struct BubbleState:Equatable {
 var id:Int;var birth,life,age:Float;var center,velocity:SIMD3<Float>;var radius,phase:Float
}
nonisolated struct BubbleFrame {var uniforms:BubbleUniforms;var bubbles:[BubbleSphere];var water:WaterFrame;var states:[BubbleState]}

nonisolated enum BubbleScene {
 static func random(_ seed:Int,_ channel:Int)->Float {
  var x=UInt32(truncatingIfNeeded:seed)&*747796405 &+ UInt32(channel)&*2891336453 &+ 277803737
  x=((x>>((x>>28)&+4))^x)&*277803737;x=(x>>22)^x
  return Float(x&0x00ffffff)/Float(0x01000000)
 }
 static func smooth(_ a:Float,_ b:Float,_ t:Float)->Float {WaterScene.smooth(a,b,t)}
 // The shell is gone in roughly two video frames; spray survives independently.
 static let ruptureDuration:Float=0.075
 static let sprayDuration:Float=0.55
 static func sphere(_ state:BubbleState,intensity:Float)->BubbleSphere {
  let t=state.age,phase=state.phase
  let growth=0.72+0.28*smooth(0,0.20,t)
  let wobble=0.04*sin(t*5.6+phase)+0.018*sin(t*9.1+phase*2)
  return BubbleSphere(centerSize:SIMD4(state.center.x,state.center.y,state.center.z,state.radius*growth),
   shape:SIMD4(1+wobble,1-wobble*0.7,0.11*sin(t*1.3+phase),phase),
   film:SIMD4(330+random(state.id,21)*155,t,max(0,(t-state.life)/ruptureDuration),smooth(0,0.075,t)*intensity))
 }
 static func popDrops(_ state:BubbleState,scale:Float)->[WaterPart] {
  let popAge=state.age-state.life
  guard popAge>=0,popAge<ruptureDuration+sprayDuration else{return []}
  var drops=[WaterPart]()
  let puncture=SIMD3<Float>(0.8*cos(state.phase),0.8*sin(state.phase),0.6)
  let count=state.radius>scale*0.7 ? 78:46
  for i in 0..<count {
   let seed=state.id*101+i
   // Irregular surface samples break up behind the travelling rupture rim.
   // They do not all launch from a uniform ring on the same frame.
   let theta=Float(i)*2.39996+state.phase+(random(seed,0)-0.5)*0.9
   let z=0.06+0.92*random(seed,1),rr=sqrt(max(0,1-z*z))
   let n=SIMD3(cos(theta)*rr,sin(theta)*rr,z)
   let alignment=simd_dot(n,puncture)
   let arrival=acos(max(-1,min(1,alignment)))/Float.pi*ruptureDuration
   let age=popAge-arrival
   let life:Float=0.25+random(seed,7)*0.30
   guard age>=0,age<life else{continue}
   let tangent=simd_normalize(n*alignment-puncture+SIMD3<Float>(0.0001,0,0))
   let jet=tangent*(2.6+random(seed,2)*4.2)+n*(0.65+random(seed,4)*2.1)
   let initialVelocity=jet*state.radius+state.velocity*0.58
   let drag:Float=3.0+random(seed,6)*2.2,travel=(1-exp(-drag*age))/drag
   // state.center is sampled at rupture, never at the current ball position.
   let p=state.center+n*state.radius+initialVelocity*travel+SIMD3<Float>(scale*age*0.15,scale*age*age*6.2,0)
   let fade=1-smooth(life*0.55,life,age)
   let large=i%7==0
   let r=(0.45+state.radius*(large ? 0.019+random(seed,3)*0.020:0.004+random(seed,3)*0.012))*sqrt(max(0,fade))
   guard r>0.30 else{continue}
   // Short torn ligaments round off into drops as their launch speed decays.
   let stretch:Float=1+(large ? 2.4:1.3)*exp(-age*32)
   let angle=atan2(initialVelocity.y,initialVelocity.x)
   drops.append(WaterPart(centerSize:SIMD4(p.x,p.y,p.z,r),shape:SIMD4(stretch,1/sqrt(stretch),angle,1),material:SIMD4(0,Float(seed),age,1)))
  }
  return drops
 }
 static func popHighlights(_ drops:[WaterPart],intensity:Float)->[BubbleSphere] {
  drops.filter{$0.centerSize.w>0.7}.map {p in
   BubbleSphere(centerSize:p.centerSize,shape:p.shape,film:SIMD4(-1,p.material.z,0,intensity))
  }
 }
 static func frame(time:Float,size:SIMD2<Float>,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->BubbleFrame {
  let ball=sample(time);var states=[BubbleState](),bubbles=[BubbleSphere](),water=[WaterPart]()
  func release(_ birth:Float,_ seed:Int,_ hero:Bool) {
   let age=time-birth
   guard birth>=0,age>=0,age<3.5 else{return}
   let b=sample(birth),r=max(1,b.z)
   guard b.w>0 else{return}
   func rnd(_ c:Int)->Float {random(seed,c)}
   let life:Float=(hero ? 1.95:0.64)+rnd(1)*(hero ? 0.85:1.05)+(!hero ? rnd(10)*0.24:0)
   guard age<life+ruptureDuration+sprayDuration else{return}
   let theta:Float = -0.85+(rnd(2)<0.5 ? .pi:0)+(rnd(3)-0.5)*1.85
   let n=SIMD2(cos(theta),sin(theta)),across=SIMD2(-n.y,n.x)
   let velocity=WaterScene.velocity(at:birth,sample:sample)
   let initial=SIMD2(b.x,b.y)+n*r*(1.18+rnd(4)*0.58)+across*(rnd(5)-0.5)*r*0.48
   let phase=rnd(6)*Float.pi*2,v0=n*r*(0.52+rnd(7)*0.8)+velocity*(hero ? 0.12:0.20)
   func position(_ t:Float)->SIMD3<Float> {
    let drag:Float=0.83,travel=(1-exp(-drag*t))/drag
    let drift=across*(sin(t*1.6+phase)-sin(phase))*r*0.18
    let xy=initial+v0*travel+drift+SIMD2<Float>(r*0.12*t*t,-r*(0.32*t+0.38*t*t))
    let z=r*((rnd(8)-0.40)*3.0+(rnd(9)-0.5)*t*0.25)
    return SIMD3(xy.x,xy.y,z)
   }
   let motionAge=min(age,life),center=position(motionAge)
   let bubbleVelocity=(position(motionAge+0.005)-position(motionAge-0.005))/0.01
   let radius=r*(hero ? 0.80+rnd(10)*0.65:0.12+0.50*pow(rnd(10),1.45))*(1100/(1100-center.z))
   let state=BubbleState(id:seed,birth:birth,life:life,age:age,center:center,velocity:bubbleVelocity,radius:radius,phase:phase)
   states.append(state)
   if age<life+ruptureDuration {bubbles.append(sphere(state,intensity:intensity*b.w))}
   let drops=popDrops(state,scale:r)
   water+=drops
   bubbles+=popHighlights(drops,intensity:intensity*b.w)
  }
  let rate:Float=12.0,end=Int(floor(time*rate)),start=max(0,Int(floor((time-3.5)*rate)))
  if end>=start {for i in start...end {release((Float(i)+random(10000+i,30)*0.65)/rate,10000+i,false)}}
  let bigRate:Float=1.25,bigEnd=Int(floor(time*bigRate)),bigStart=max(0,Int(floor((time-3.5)*bigRate)))
  if bigEnd>=bigStart {for i in bigStart...bigEnd {release(Float(i)/bigRate+0.06,300000+i,true)}}
  for (event,touch) in touches.enumerated() where time>=touch && time-touch<3.5 {
   let offsets:[Float]=[0,0.022,0.048,0.085,0.13,0.19,0.26,0.34]
   for (i,offset) in offsets.enumerated() {release(touch+offset,1000000+event*100+i,false)}
   for releaseIndex in 0..<2 {
   let birth=touch+(releaseIndex==0 ? 0.025:0.115),age=time-birth
   guard age>=0,age<0.43 else{continue}
   let b=sample(birth),r=max(1,b.z),scale=r*(releaseIndex==0 ? 0.76:0.34)
   guard b.w>0 else{continue}
   let velocity=WaterScene.velocity(at:birth,sample:sample)
   let inherit=velocity*((1-exp(-age*0.60))/0.60)*0.90+SIMD2<Float>(0,r*11*age*age)
   let base=SIMD2(b.x,b.y)+SIMD2<Float>(r*0.38,-r*0.22)+inherit
   let atoms=WaterCrown.sample(age:age,seed:event%3),kernels=WaterOptics.kernels(atoms)
   let fade=smooth(0,0.035,age)*(1-smooth(0.30,0.43,age))
   let side:Float=event%2==0 ? 1:-1
   for (i,atom) in atoms.enumerated() {
    let p=base+SIMD2(atom.p.x*side,atom.p.y)*scale
    let jet=atom.id>=WaterCrown.rimCount
    let neck:Float=jet ? 0.82+0.26*sin(Float(atom.id)*0.41+Float(event)):1
    let stretch:Float=jet ? sqrt(0.9/(0.9+6.4*age)):1
    let drop=scale*0.062*(0.67+0.33*smooth(1,12,atom.neighbours))*neck*stretch*sqrt(max(0,fade))
    if drop<0.26 {continue}
    let k=kernels[i]
    water.append(WaterPart(centerSize:SIMD4(p.x,p.y,atom.p.z*scale,drop),shape:SIMD4(k.shape.x,k.shape.y,k.shape.z*side,1),material:SIMD4(0,Float(event*10000+i),age,2),quadric0:SIMD4(k.quadric0.x,k.quadric0.y*side,k.quadric0.z*side,k.quadric0.w),quadric1:k.quadric1))
   }
   for j in 0..<60 {
    let seed=event*127+j,angle:Float=1.7+random(seed,1)*3.5,n=SIMD2(cos(angle)*side,sin(angle))
    let p=base+n*scale*(1.05+(6+random(seed,2)*9)*age)
    let drop=scale*(j<8 ? 0.065+random(seed,3)*0.05:0.012+random(seed,3)*0.022)*sqrt(max(0,fade))
    if drop>0.3 {water.append(WaterPart(centerSize:SIMD4(p.x,p.y,scale*0.4,drop),shape:SIMD4(1.2,0.85,angle,1),material:SIMD4(0,Float(seed),age,1)))}
   }
  }
  }
  bubbles.sort{$0.centerSize.z<$1.centerSize.z}
  let waterFrame=WaterFrame(uniforms:WaterUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball,options:SIMD4(2,0,1,Float(water.count))),parts:water)
  return BubbleFrame(uniforms:BubbleUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball),bubbles:bubbles,water:waterFrame,states:states)
 }
 static func study(time:Float,size:SIMD2<Float>)->BubbleFrame {
  let motionTime=min(time,2.35)
  let state=BubbleState(id:3,birth:0,life:2.35,age:time,center:SIMD3(size.x*0.5+sin(motionTime*1.3)*18,size.y*0.52-motionTime*12,0),velocity:SIMD3(cos(motionTime*1.3)*23.4,-12,0),radius:180,phase:0.7)
  let ball=SIMD4<Float>(-1000,-1000,70,1),parts=popDrops(state,scale:70)
  return BubbleFrame(uniforms:BubbleUniforms(viewport:SIMD4(size.x,size.y,time,1),ball:ball),bubbles:(time<2.35+ruptureDuration ? [sphere(state,intensity:1)]:[])+popHighlights(parts,intensity:1),water:WaterFrame(uniforms:WaterUniforms(viewport:SIMD4(size.x,size.y,time,1),ball:ball,options:SIMD4(2,0,1,Float(parts.count))),parts:parts),states:[state])
 }
}
