#if DEBUG && BALL_DETECTION_DEBUG
import RealityKit
import UIKit
import simd

/// Static environment geometry is batched to keep the mobile draw-call count modest.
@MainActor enum TrainingGround {
    static func build(in stage: Entity) {
        let sunlight=DirectionalLight()
        sunlight.light.intensity=4200
        sunlight.light.color=UIColor(red:1,green:0.92,blue:0.79,alpha:1)
        sunlight.shadow = .init(maximumDistance:35,depthBias:0.7)
        sunlight.look(at:[0,0,0],from:[-8,12,8],relativeTo:nil)
        stage.addChild(sunlight)
        let fill=PointLight();fill.position=[5,5,4];fill.light.intensity=2400;fill.light.attenuationRadius=24
        fill.light.color=UIColor(red:0.69,green:0.82,blue:1,alpha:1);stage.addChild(fill)
        let rim=PointLight();rim.position=[-4,5,-4];rim.light.intensity=2000;rim.light.attenuationRadius=18;stage.addChild(rim)
        let grass=grassMaterial()
        let floor=ModelEntity(mesh:.generatePlane(width:90,depth:100),materials:[grass]);floor.position=[0,-0.015,22];stage.addChild(floor)
        let chalk=SimpleMaterial(color:UIColor(white:0.88,alpha:1),roughness:0.95,isMetallic:false)
        var markings=GeometryBatch()
        markings.box([68,0.006,0.09],[0,-0.004,-0.35])
        for (width,depth): (Float,Float) in [(18.32,5.5),(40.32,16.5)] {
            markings.box([width,0.006,0.09],[0,-0.004,depth-0.35])
            for sign: Float in [-1,1] { markings.box([0.09,0.006,depth],[sign*width/2,-0.004,depth/2-0.35]) }
        }
        markings.box([0.20,0.006,0.20],[0,-0.004,10.65]);markings.add(to:stage,material:chalk)
        let metal=SimpleMaterial(color:UIColor(white:0.94,alpha:1),roughness:0.29,isMetallic:false)
        var posts=GeometryBatch()
        for x: Float in [-3.72,3.72] {
            posts.rod([x,0,-0.35],[x,2.5,-0.35],radius:0.06,sides:16)
            posts.rod([x,0.04,-0.35],[x,0.04,-2.55],radius:0.025)
            posts.rod([x,0.04,-2.55],[x,2.35,-2.55],radius:0.025)
            posts.rod([x,2.5,-0.35],[x,2.35,-2.55],radius:0.025)
        }
        posts.rod([-3.72,2.5,-0.35],[3.72,2.5,-0.35],radius:0.06,sides:16)
        posts.rod([-3.72,0.04,-2.55],[3.72,0.04,-2.55],radius:0.025)
        posts.add(to:stage,material:metal)
        var concrete=GeometryBatch(),seats=GeometryBatch(),seatAccent=GeometryBatch(),rail=GeometryBatch()
        for row in 0..<10 {
            let y=Float(row)*0.40,z = -9-Float(row)*0.75
            concrete.box([44,0.4,0.78],[0,y+0.2,z])
            for column in 0..<65 where column%16 != 0 {
                let x=Float(column-32)*0.64
                if (column+row)%5==0 {
                    seatAccent.box([0.45,0.12,0.40],[x,y+0.48,z+0.10]);seatAccent.box([0.45,0.42,0.09],[x,y+0.67,z-0.08])
                } else {
                    seats.box([0.45,0.12,0.40],[x,y+0.48,z+0.10]);seats.box([0.45,0.42,0.09],[x,y+0.67,z-0.08])
                }
            }
        }
        concrete.box([48,0.9,0.3],[0,0.45,-7])
        concrete.add(to:stage,material:SimpleMaterial(color:UIColor(red:0.11,green:0.15,blue:0.17,alpha:1),roughness:0.95,isMetallic:false))
        seats.add(to:stage,material:SimpleMaterial(color:UIColor(red:0.08,green:0.20,blue:0.23,alpha:1),roughness:0.7,isMetallic:false))
        seatAccent.add(to:stage,material:SimpleMaterial(color:UIColor(red:0.25,green:0.40,blue:0.37,alpha:1),roughness:0.7,isMetallic:false))
        rail.rod([-23,1.3,-7],[23,1.3,-7],radius:0.025)
        for i in -12...12 { rail.rod([Float(i)*2,0,-7],[Float(i)*2,1.3,-7],radius:0.025) }
        rail.add(to:stage,material:SimpleMaterial(color:.darkGray,roughness:0.5,isMetallic:true))
        for x: Float in [-13,13] {
            var tower=GeometryBatch();tower.rod([x,0,-8],[x,10,-8],radius:0.09,sides:8)
            tower.box([2.6,0.85,0.20],[x,10,-8]);tower.add(to:stage,material:SimpleMaterial(color:.darkGray,roughness:0.6,isMetallic:true))
            var lamps=GeometryBatch()
            for k in 0..<6 { lamps.box([0.32,0.50,0.06],[x+Float(k)*0.39-0.98,10,-7.86]) }
            lamps.add(to:stage,material:UnlitMaterial(color:UIColor(red:0.87,green:0.94,blue:1,alpha:1)))
        }
        for (text,x) in [("KEEPER LAB",Float(-8)),("JUGGLE DUDE",Float(4.5))] {
            let letters=ModelEntity(mesh:.generateText(text,extrusionDepth:0.004,font:.systemFont(ofSize:0.28,weight:.bold)),materials:[UnlitMaterial(color:UIColor(white:0.75,alpha:1))])
            letters.position=[x,0.36,-6.82];stage.addChild(letters)
        }
    }
    private static func grassMaterial() -> PhysicallyBasedMaterial {
        let size=CGSize(width:1024,height:1024)
        let image=UIGraphicsImageRenderer(size:size).image { context in
            let c=context.cgContext
            UIColor(red:0.12,green:0.25,blue:0.075,alpha:1).setFill();c.fill(CGRect(origin:.zero,size:size))
            var seed: UInt64=42
            func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1;return CGFloat((seed>>32)%10000)/10000 }
            for _ in 0..<60000 {
                let x=random()*1024,y=random()*1024,l=random()
                c.setStrokeColor(UIColor(red:0.08+0.10*l,green:0.18+0.18*l,blue:0.035+0.055*l,alpha:0.6).cgColor)
                c.setLineWidth(0.6+random());c.move(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:x+random()*2-1,y:y+2+random()*5));c.strokePath()
            }
        }
        var material=PhysicallyBasedMaterial()
        if let cg=image.cgImage,let texture=try? TextureResource(image:cg,options:.init(semantic:.color)) {
            material.baseColor = .init(texture:.init(texture));material.textureCoordinateTransform.scale=[28,32]
        } else { material.baseColor = .init(tint:.systemGreen) }
        material.roughness=0.95
        return material
    }
}

struct GeometryBatch {
    var vertices=[SIMD3<Float>](),normals=[SIMD3<Float>](),indices=[UInt32]()
    mutating func rod(_ a: SIMD3<Float>,_ b: SIMD3<Float>,radius: Float,sides: Int=6) {
        let axis=simd_normalize(b-a),u=simd_normalize(simd_cross(axis,abs(axis.y)<0.9 ? SIMD3(0,1,0):SIMD3(1,0,0))),v=simd_cross(axis,u)
        let start=UInt32(vertices.count)
        for p in [a,b] { for i in 0..<sides { let t=Float(i)*2 * .pi/Float(sides),n=u*cos(t)+v*sin(t);vertices.append(p+n*radius);normals.append(n) } }
        for i in 0..<sides { let j=UInt32(i),k=UInt32((i+1)%sides),s=UInt32(sides);indices += [start+j,start+k,start+j+s,start+k,start+k+s,start+j+s] }
    }
    mutating func box(_ size: SIMD3<Float>,_ center: SIMD3<Float>) {
        let p=size/2
        let corners: [SIMD3<Float>] = [[-p.x,-p.y,-p.z],[p.x,-p.y,-p.z],[p.x,p.y,-p.z],[-p.x,p.y,-p.z],[-p.x,-p.y,p.z],[p.x,-p.y,p.z],[p.x,p.y,p.z],[-p.x,p.y,p.z]]
        for face in [[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]] {
            let start=UInt32(vertices.count),n=simd_normalize(simd_cross(corners[face[1]]-corners[face[0]],corners[face[2]]-corners[face[0]]))
            for i in face { vertices.append(corners[i]+center);normals.append(n) };indices += [start,start+1,start+2,start,start+2,start+3]
        }
    }
    @MainActor func add(to parent: Entity,material: any Material) {
        var descriptor=MeshDescriptor();descriptor.positions=MeshBuffers.Positions(vertices);descriptor.normals=MeshBuffers.Normals(normals);descriptor.primitives = .triangles(indices)
        if let mesh=try? MeshResource.generate(from:[descriptor]) { parent.addChild(ModelEntity(mesh:mesh,materials:[material])) }
    }
}

#endif
