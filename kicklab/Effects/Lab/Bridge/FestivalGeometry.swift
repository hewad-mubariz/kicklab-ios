// Copied from the Effects Lab (EffectLab/FestivalGeometry.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated struct FestivalVertex { var position,normal,color,material,local:SIMD4<Float> }
nonisolated struct FestivalPuff { var centerRadius,shape,color,detail:SIMD4<Float> }
nonisolated struct FestivalParticle { var id:Int;var birth,age,life,size,alpha:Float;var center,angles:SIMD3<Float> }
nonisolated struct FestivalFrame {var uniforms:LiquidUniforms;var vertices:[FestivalVertex];var puffs:[FestivalPuff];var liquid:LiquidFrame?;var particles:[FestivalParticle]}

// Meshes are constructed in object coordinates and rotated as solid objects.
// Geometry and lighting vary per material; no concept images are render assets.
nonisolated struct FestivalMesh {
 typealias V=SIMD3<Float>
 var vertices=[FestivalVertex]()
 var center=V.zero,scale:Float=1,rotation=simd_quatf(angle:0,axis:V(0,0,1))
 var color=V(1,0.65,0.12),alpha:Float=1,material=SIMD4<Float>(0.23,1,1,0)
 mutating func transform(_ p:FestivalParticle){center=p.center;scale=p.size;alpha=p.alpha;rotation=simd_quatf(angle:p.angles.z,axis:V(0,0,1))*simd_quatf(angle:p.angles.y,axis:V(0,1,0))*simd_quatf(angle:p.angles.x,axis:V(1,0,0));material.w=Float(p.id%997)}
 mutating func triangle(_ a:V,_ b:V,_ c:V,_ normals:[V]?=nil){
  let cross=simd_cross(b-a,c-a);guard simd_length_squared(cross)>0.000000001 else{return}
  let face=simd_normalize(cross)
  for(i,p) in [a,b,c].enumerated(){let world=center+rotation.act(p)*scale,n=rotation.act(normals?[i] ?? face)
   vertices.append(FestivalVertex(position:SIMD4(world.x,world.y,world.z,1),normal:SIMD4(n.x,n.y,n.z,0),color:SIMD4(color.x,color.y,color.z,alpha),material:material,local:SIMD4(p.x,p.y,p.z,0)))
  }
 }
 mutating func quad(_ a:V,_ b:V,_ c:V,_ d:V){triangle(a,b,c);triangle(a,c,d)}
 mutating func sphere(_ origin:V = .zero,_ radii:V=V(repeating:1),steps:Int=16,rough:Float=0){
  func point(_ i:Int,_ j:Int)->(V,V){let t=Float(i)/Float(steps)*Float.pi,a=Float(j)/Float(steps*2)*Float.pi*2
   let n=V(sin(t)*cos(a),cos(t),sin(t)*sin(a));let noise=1+rough*sin(n.x*8+material.w)*sin(n.y*11)*sin(n.z*9+2)
   return(origin+n*radii*noise,simd_normalize(n/radii))}
  for i in 0..<steps {for j in 0..<steps*2{let a=point(i,j),b=point(i+1,j),c=point(i+1,j+1),d=point(i,j+1);triangle(a.0,b.0,c.0,[a.1,b.1,c.1]);triangle(a.0,c.0,d.0,[a.1,c.1,d.1])}}
 }
 mutating func tube(_ points:[V],radii:[Float],sides:Int=8){
  guard points.count>1 else{return}
  var rings=[[V]](),normals=[[V]]()
  for i in points.indices {let tangent=simd_normalize(points[min(i+1,points.count-1)]-points[max(0,i-1)])
   let axis=abs(tangent.z)<0.88 ? V(0,0,1):V(0,1,0),n=simd_normalize(simd_cross(tangent,axis)),b=simd_cross(tangent,n)
   let ns=(0..<sides).map{j->V in let a=Float(j)/Float(sides)*Float.pi*2;return n*cos(a)+b*sin(a)}
   normals.append(ns);rings.append(ns.map{points[i]+$0*radii[min(i,radii.count-1)]})
  }
  for i in 0..<points.count-1 {for j in 0..<sides {let k=(j+1)%sides
   triangle(rings[i][j],rings[i+1][j],rings[i+1][k],[normals[i][j],normals[i+1][j],normals[i+1][k]])
   triangle(rings[i][j],rings[i+1][k],rings[i][k],[normals[i][j],normals[i+1][k],normals[i][k]])
  }}
 }
 mutating func coin(){
  let count=48
  let profile:[SIMD2<Float>]=[SIMD2(0,-0.13),SIMD2(0.87,-0.13),SIMD2(0.97,-0.10),SIMD2(1,-0.06),SIMD2(1,0.06),SIMD2(0.97,0.14),SIMD2(0.84,0.14),SIMD2(0.81,0.10),SIMD2(0,0.10)]
  for k in 0..<profile.count-1 {for j in 0..<count {func v(_ p:SIMD2<Float>,_ j:Int)->V {let a=Float(j)*2*Float.pi/Float(count);return V(cos(a)*p.x,sin(a)*p.x,p.y)}
   quad(v(profile[k],j),v(profile[k],j+1),v(profile[k+1],j+1),v(profile[k+1],j))}}
  let gold=color;color*=0.68
  for j in 0..<48 {let a=Float(j)*2*Float.pi/48;let p=V(cos(a),sin(a),0);tube([p+V(0,0,-0.065),p+V(0,0,0.075)],radii:[0.012],sides:4)}
  color=gold*1.06
  let emblem=(0...6).map{i->V in let a=Float(i)*Float.pi/3;return V(cos(a)*0.41,sin(a)*0.41,0.135)}
  tube(emblem,radii:[0.038],sides:6)
  tube((0...40).map{i in let a=Float(i)*2*Float.pi/40;return V(cos(a)*0.72,sin(a)*0.72,0.13)},radii:[0.018],sides:5)
 }
 mutating func star(round:Bool=false){
  let points=(0..<10).map{i->V in let a=Float(i)*Float.pi/5-Float.pi/2,r:Float=i%2==0 ? 1:0.43;return V(cos(a)*r,sin(a)*r,0)}
  for i in 0..<10 {let j=(i+1)%10,a=points[i],b=points[j],z:Float=round ? 0.22:0.30
   let aa=a*0.87+V(0,0,0.13),bb=b*0.87+V(0,0,0.13)
   triangle(V(0,0,z),aa,bb);quad(aa,a,b,bb);quad(a,b,b-V(0,0,0.14),a-V(0,0,0.14));triangle(V(0,0,-0.15),b-V(0,0,0.14),a-V(0,0,0.14))
  }
 }
 mutating func shard(_ seed:Int){
  let w:Float=0.22+FestivalScene.random(seed,13)*0.48
  let a=V(-w,-0.55,0),b=V(w,-0.13,0),c=V(0.05,1.55,0),top=V(0,-0.10,0.30),back=V(0,-0.1,-0.09)
  triangle(a,b,top);triangle(b,c,top);triangle(c,a,top);triangle(b,a,back);triangle(c,b,back);triangle(a,c,back)
 }
 mutating func box(){
  // Six rounded patches join at bevels; the outline is actual 3D geometry.
  let axes:[(V,V,V)]=[(V(1,0,0),V(0,1,0),V(0,0,1)),(V(-1,0,0),V(0,-1,0),V(0,0,1)),(V(0,1,0),V(0,0,1),V(1,0,0)),(V(0,-1,0),V(0,0,-1),V(1,0,0)),(V(0,0,1),V(1,0,0),V(0,1,0)),(V(0,0,-1),V(-1,0,0),V(0,1,0))]
  let knots:[Float]=[-1,-0.9,-0.76,0,0.76,0.9,1]
  for(n,u,v) in axes {func point(_ i:Int,_ j:Int)->(V,V){let p=n+u*knots[i]+v*knots[j],q=simd_clamp(p,V(repeating:-0.76),V(repeating:0.76)),nn=simd_normalize(p-q);return(q+nn*0.24,nn)}
   for i in 0..<6{for j in 0..<6{let a=point(i,j),b=point(i+1,j),c=point(i+1,j+1),d=point(i,j+1);triangle(a.0,b.0,c.0,[a.1,b.1,c.1]);triangle(a.0,c.0,d.0,[a.1,c.1,d.1])}}
  }
 }
 mutating func note(double:Bool){
  sphere(V(-0.35,0.65,0),V(0.46,0.31,0.27),steps:12)
  let stem=[V(-0.12,0.62,0),V(-0.12,-0.84,0)];tube(stem,radii:[0.11],sides:10)
  if double {
   sphere(V(0.64,0.42,0),V(0.46,0.31,0.27),steps:12);tube([V(0.87,0.40,0),V(0.87,-1.07,0)],radii:[0.11],sides:10)
   tube([V(-0.12,-0.83,0),V(0.38,-0.95,0),V(0.87,-1.07,0)],radii:[0.16],sides:10)
  }else{tube([V(-0.12,-0.84,0),V(0.15,-0.65,0),V(0.40,-0.50,0),V(0.46,-0.24,0)],radii:[0.16,0.17,0.13,0.05],sides:10)}
 }
 mutating func popcorn(_ seed:Int){
  color=V(0.75,0.31,0.045);sphere(.zero,V(0.39,0.42,0.36),steps:10,rough:0.08)
  for j in 0..<7 {let a=Float(j)*2.399963,t=Float(j)/7*2-0.88,n=V(cos(a)*sqrt(max(0,1-t*t)),t,sin(a)*sqrt(max(0,1-t*t)))
   let k=FestivalScene.random(seed,j+40),c:Float=0.90+k*0.10;color=V(c,c*0.97,c*0.84);sphere(n*(0.36+k*0.27),V(0.32+k*0.24,0.30+k*0.26,0.32+k*0.22),steps:12,rough:0.13)
  }
 }
 mutating func spring(age:Float,seed:Int){
  let compression:Float=1+0.24*sin(age*13+Float(seed))*exp(-age*1.1)
  let turns:Float=4.4,steps=96
  let points=(0...steps).map{i->V in let t=Float(i)/Float(steps),a=t*turns*2*Float.pi;return V(cos(a)*0.57,(t-0.5)*3.5*compression,sin(a)*0.57)}
  tube(points,radii:[0.14],sides:8)
 }
 mutating func confetti(age:Float,seed:Int,streamer:Bool){
  let count=streamer ? 30:5,length:Float=streamer ? 4.0:1.1,width:Float=streamer ? 0.16:0.38
  func point(_ i:Int,_ side:Float)->V{let t=Float(i)/Float(count),a=t*(streamer ? 12:2.8)+age*5+Float(seed)
   return V(sin(a)*(streamer ? 0.4:0.12)+side*width*cos(a*0.8),(t-0.5)*length,cos(a)*(streamer ? 0.42:0.12)+side*width*sin(a*0.8))}
  for i in 0..<count{quad(point(i,-1),point(i,1),point(i+1,1),point(i+1,-1))}
 }
}
