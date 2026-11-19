// Copied from the Effects Lab (EffectLab/SilkScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct SilkUniforms {var viewport,ball:SIMD4<Float>;var peel=SIMD4<Float>(repeating:0)}
nonisolated struct SilkNode:Equatable {var positionWidth,drape:SIMD4<Float>}
nonisolated struct SilkRibbon:Equatable {var material:SIMD4<Float>}
nonisolated struct SilkFrame {var uniforms:SilkUniforms;var nodes:[SilkNode];var ribbons:[SilkRibbon]}

/// Constrained ribbon spines with a weak animated wind guide. This is an
/// art-directed ribbon model, without full cloth or self-collision simulation.
nonisolated final class SilkSimulation {
 static let count=81,dt:Float=1/120
 private var positions=[[SIMD3<Float>]](),previous=[[SIMD3<Float>]]()
 private var restLengths=[[Float]]()
 private var rolls=[[Float]](),rollSpeeds=[[Float]]()
 private var step=0
 func reset(){positions=[];previous=[];restLengths=[];rolls=[];rollSpeeds=[];step=0}
 private func kind(_ lane:Int)->Int {lane==1 || lane==5 ? 1:0}
 private func guide(_ t:Float,_ lane:Int,_ raw:Float,_ sample:(Float)->SIMD4<Float>)->SIMD3<Float> {
  let strandLength:Float=raw<0 ? 0.38+0.065*Float(lane):0.20+0.14*Float(lane%3)
  let s=raw*(lane<2 ? 1:strandLength)
  let k=Float(kind(lane)),b=sample(max(0,t-abs(s)*(lane<2 ? 0.008:0.055))),r=max(1,b.z)
  var x:Float,y:Float,z:Float
  if k==0 {
   x=s>=0 ? -4.9*sin(s*Float.pi)+3.4*s : -3.6*s+0.6*sin(s*6)
   y=s>=0 ? 0.82-5.7*s : 0.82-3.1*s+0.7*sin(s*5)
  } else {
   x=0.55+3.5*s+0.65*sin(s*6)
   y=0.18-5.7*s+0.46*sin(s*4)
  }
  x+=abs(s)*0.7*sin(t*2.1+s*4+k*1.8)
  y+=abs(s)*0.65*sin(t*2.6-s*5+k*2)
  z = -0.6+sin(s*6+t*1.4+k)*0.65
  // A changing wind envelope opens and closes the upper sweep. It is not a
  // rigid C-shaped guide translating with the ball.
  let free=pow(abs(s),0.7),phase=t*3.6-abs(s)*7+k*2.3
  let angle=free*(0.30*sin(t*2.7+k*2)+0.18*sin(t*4.1-k))
  let rotatedX=x*cos(angle)-y*sin(angle),rotatedY=x*sin(angle)+y*cos(angle)
  x=rotatedX+free*(0.65*sin(phase)+0.32*sin(t*6.5-s*11+k))
  y=rotatedY+free*0.72*sin(phase+1.3)
  z+=free*(0.8*sin(phase-0.6)+0.25*sin(t*7-s*14+k))
  if lane>=2 {
   let f=Float(lane),side:Float=lane%2==0 ? -1:1
   x+=s*side*(0.5+0.09*f)+sin(s*7+t*2.5+f)*abs(s)*0.65
   y+=s*(0.4*sin(f*2))+sin(s*5-t*2+f)*abs(s)*0.6
   z+=s*sin(f)*0.9
  }
  return SIMD3(b.x+x*r,b.y+y*r,z*r)
 }
 private func anchor(_ t:Float,_ lane:Int,_ sample:(Float)->SIMD4<Float>)->SIMD3<Float> {guide(t,lane,0,sample)}
 private func initialize(_ sample:(Float)->SIMD4<Float>) {
  for lane in 0..<8 {
   var chain=[SIMD3<Float>]()
   for i in 0..<Self.count {chain.append(guide(0,lane,Float(i-40)/40,sample))}
   positions.append(chain);previous.append(chain)
   rolls.append((0..<Self.count).map {0.35*sin(Float($0)/80*10+Float(lane))})
   rollSpeeds.append([Float](repeating:0,count:Self.count))
   let r=max(1,sample(0).z)
   restLengths.append((0..<80).map {simd_distance(chain[$0],chain[$0+1])/r})
  }
 }
 private func advance(_ t:Float,_ touches:[Float],_ sample:(Float)->SIMD4<Float>) {
  let ball=sample(t),r=max(1,ball.z),dt=Self.dt
  for lane in 0..<8 {
   let k=Float(lane),pin=anchor(t,lane,sample)
   let priorRolls=rolls[lane]
   for i in 0..<Self.count where i != 40 {
    let s=Float(i-40)/40,side:Float=s>0 ? 1:-1
    let free=pow(abs(s),0.7)
    var pulse:Float=0
    for touch in touches where t>=touch && t-touch<0.8 {
     let age=t-touch
     pulse+=exp(-pow((abs(s)-age*2.7)/0.22,2))*exp(-age*2.2)
    }
    let p=positions[lane][i],v=(p-previous[lane][i])*(lane<2 ? 0.93+0.035*free:0.965)
    let gust=sin(t*2.7+s*4.6+k*2.5),flutter=sin(t*8.8-s*11+k*1.8)
    let wind=SIMD3<Float>(side*5+gust*(16+free*14),flutter*(12+free*12)-pulse*42,cos(t*4.2+s*6.1+k*2)*(16+free*22)+pulse*24)*r
    let guidance=(guide(t,lane,s,sample)-p)*(lane<2 ? 245-150*free:68)
    previous[lane][i]=p;positions[lane][i]=p+v+(wind+guidance)*dt*dt
    let targetRoll=free*(0.9*sin(abs(s)*10-t*4.7+k*1.8)+0.5*sin(s*17-t*7.1+k))
    let coupling=priorRolls[max(0,i-1)]+priorRolls[min(80,i+1)]-2*priorRolls[i]
    let torque=(targetRoll-priorRolls[i])*26+coupling*65+side*pulse*21
    rollSpeeds[lane][i]=(rollSpeeds[lane][i]+torque*dt)*0.968
    rolls[lane][i]=priorRolls[i]+rollSpeeds[lane][i]*dt
   }
   positions[lane][40]=pin;previous[lane][40]=pin
   func constrain(_ a:Int,_ b:Int,_ length:Float,_ strength:Float) {
    let delta=positions[lane][b]-positions[lane][a],distance=max(0.001,simd_length(delta))
    let wa:Float=a==40 ? 0:1,wb:Float=b==40 ? 0:1
    let correction=delta*((distance-length)/distance*strength/(wa+wb))
    positions[lane][a]+=correction*wa;positions[lane][b]-=correction*wb
   }
   for pass in 0..<14 {
    for j in 0..<40 {constrain(40+j,41+j,r*restLengths[lane][40+j],1);constrain(40-j,39-j,r*restLengths[lane][39-j],1)}
    if pass%2==0 {for i in 0..<79 {constrain(i,i+2,r*(restLengths[lane][i]+restLengths[lane][i+1])*0.98,0.08)}}
    for i in 0..<Self.count where i != 40 {
     var p=positions[lane][i]
     let offset=p-pin,maximum=restLengths[lane][min(i,40)..<max(i,40)].reduce(0,+)*r*1.04
     if simd_length(offset)>maximum {p=pin+simd_normalize(offset)*maximum}
     let center=SIMD3(ball.x,ball.y,0),delta=p-center,dist=simd_length(delta)
     if dist<r*1.03 {p=center+delta/max(0.001,dist)*r*1.03}
     positions[lane][i]=p
    }
   }
  }
 }
 func frame(time:Float,size:SIMD2<Float>,intensity:Float=1,touches:[Float],sample:(Float)->SIMD4<Float>)->SilkFrame {
  let target=max(0,Int(round(time/Self.dt)))
  if positions.isEmpty || target<step {reset();initialize(sample)}
  while step<target {step+=1;advance(Float(step)*Self.dt,touches,sample)}
  let ball=sample(time),r=max(1,ball.z)
  var nodes=[SilkNode](),ribbons=[SilkRibbon]()
  for lane in 0..<8 {
   let offset=nodes.count,k=kind(lane)
   var surface=positions[lane]
   if lane<2 {
    for _ in 0..<1 {
     let input=surface
     for i in 2..<79 {surface[i]=(input[i-2]+input[i-1]*4+input[i]*6+input[i+1]*4+input[i+2])/16}
    }
   }
   for i in 0..<Self.count {
    let s=Float(i)/80,end=min(s,1-s),taper=min(1,pow(max(0,end)*(lane<2 ? 10:5.4),lane<2 ? 0.45:0.85))
    let widthBase:Float=lane==0 ? 1.4:lane==1 ? 1.15:0.011+0.042*pow(0.5+0.5*sin(Float(lane)*3.7),2)
    let varied:Float=0.76+0.24*sin(s*8+Float(lane)*2.1)
    let p=surface[i],width=r*widthBase*taper*varied
    let lo=max(0,i-3),hi=min(80,i+3)
    let arc=restLengths[lane][lo..<hi].reduce(0,+)*r
    let compression=max(0,min(1,1-simd_distance(surface[lo],surface[hi])/max(1,arc)))
    nodes.append(SilkNode(positionWidth:SIMD4(p.x,p.y,p.z,width),drape:SIMD4(rolls[lane][i],compression,rollSpeeds[lane][i],0)))
   }
   // The main band includes a translucent side panel. Its narrow opaque folds
   // and broad gauze use the same surface, rather than duplicate edge loops.
   ribbons.append(SilkRibbon(material:SIMD4(Float(offset),Float(k),lane<2 ? 1:0,Float(lane))))
  }
  return SilkFrame(uniforms:SilkUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball),nodes:nodes,ribbons:ribbons)
 }
}
