// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import simd

/// Explicit moving water films. The flow is a reduced, art-directed advection
/// model; it is not the FLIP solver in the cited thin-sheet research. Keeping
/// a surface here avoids collapsing a cupped film into a 2D density silhouette.
nonisolated struct WaterSurfaceVertex: Equatable, Sendable {
    var positionThickness, normal, material: SIMD4<Float>
}
nonisolated enum WaterSheet {
    static let columns=100, rows=22
    static let lifetime:Float=0.72, dt:Float=1/120
    struct Node {var p,v:SIMD3<Float>}
    struct Frame {var nodes:[Node]}
    struct Surface {var vertices:[WaterSurfaceVertex];var rim:[WaterPart]}
    struct Edge:Hashable {var a,b:Int;init(_ i:Int,_ j:Int){a=min(i,j);b=max(i,j)}}
    private static let lock=NSLock()
    nonisolated(unsafe) private static var cache:[Int:[Frame]]=[:]
    static func hash(_ n:Float)->Float {WaterScene.hash(n)}
    static func initial(seed:Int)->[Node] {
        let phase=Float(seed)*0.67
        var nodes=[Node]()
        for j in 0...rows {for i in 0...columns {
            let u=Float(i)/Float(columns),v=Float(j)/Float(rows)
            let a:Float=1.78+u*3.55+0.04*sin(phase)
            let n=SIMD2<Float>(cos(a),sin(a)),t=SIMD2(-n.y,n.x)
            let rib:Float=0.065*sin(u*44+phase)+0.024*sin(u*103-phase)
            let fingers=pow(max(0,sin(u*91+phase)),6)*0.28*pow(v,7)
            let radial:Float=0.86+1.36*sin(v*2.02)+rib*v+fingers+0.66*exp(-u*17)*v
            let ripple:Float=0.055*sin(u*46+v*21+phase)+0.026*sin(u*97-v*34)
            // Curl the lip toward the viewer and back over the thin inner film.
            let z:Float=0.10+0.72*(1-cos(v*3.3))+ripple+0.16*sin(a*2+phase)
            var p=SIMD3(n.x*radial-0.30,n.y*radial-0.17,z)
            let x=p.x*0.985+p.z*0.17
            p.z = -p.x*0.17+p.z*0.985;p.x=x
            var velocity=SIMD3<Float>(n.x*(0.6+v*1.8)+t.x*(0.8+1.4*v),n.y*(0.6+v*1.8)+t.y*(0.8+1.4*v),0)
            velocity.z = -1.8*sin(v*2.8)+0.9*sin(u*9+phase)
            velocity+=SIMD3(0.18*sin(u*21),0.30*cos(v*10+u*7),0.25*cos(u*17))
            nodes.append(Node(p:p,v:velocity))
        }}
        return nodes
    }
    static func step(_ nodes:inout [Node],time:Float,seed:Int) {
        // Spatially varying curl force bends different regions independently.
        // No frame uses an animated transform of a fixed complete splash.
        let phase=Float(seed)*0.67
        for i in nodes.indices {
            let p=nodes[i].p
            let force=SIMD3<Float>(-0.65*sin(p.y*2.3+time*3+phase),
                                   0.65*sin(p.x*2.2-time*2.7),
                                   0.9*sin(p.x*2+p.y*1.3+time*4+phase))
            nodes[i].v += (force-nodes[i].v*0.20)*dt
            nodes[i].p += nodes[i].v*dt
        }
    }
    static func sample(age:Float,seed:Int)->[Node] {
        let key=((seed%12)+12)%12
        lock.lock()
        if cache[key]==nil {
            var nodes=initial(seed:key),frames=[Frame(nodes:nodes)]
            for i in 1...Int(ceil(lifetime/dt)) {
                step(&nodes,time:Float(i)*dt,seed:key)
                if i%2==0 {frames.append(Frame(nodes:nodes))}
            }
            cache[key]=frames
        }
        let frames=cache[key]!
        lock.unlock()
        let value=max(0,min(Float(frames.count-1),age*60)),a=Int(value),b=min(a+1,frames.count-1),f=value-Float(a)
        return zip(frames[a].nodes,frames[b].nodes).map{Node(p:simd_mix($0.p,$1.p,SIMD3(repeating:f)),v:simd_mix($0.v,$1.v,SIMD3(repeating:f)))}
    }
    private static func point(age:Float,seed:Int,index:Int)->Node {
        let key=((seed%12)+12)%12
        lock.lock();let frames=cache[key]!;lock.unlock()
        let value=max(0,min(Float(frames.count-1),age*60)),a=Int(value),b=min(a+1,frames.count-1),f=value-Float(a)
        let p=frames[a].nodes[index],q=frames[b].nodes[index]
        return Node(p:simd_mix(p.p,q.p,SIMD3(repeating:f)),v:simd_mix(p.v,q.v,SIMD3(repeating:f)))
    }
    static func surface(age:Float,seed:Int)->Surface {
        var nodes=sample(age:age,seed:seed)
        let stride=columns+1
        var coordinates=nodes.indices.map{SIMD2<Float>(Float($0%stride)/Float(columns),Float($0/stride)/Float(rows))}
        var triangles=[SIMD3<Int>](),edges=[Edge:Int]()
        // Thin films tear where the transported sheet stretches. Seeded voids
        // expand with age; their boundaries become real rounded mesh rims.
        let holeCount=36
        var holes=[SIMD3<Float>]()
        for i in 0..<holeCount {
            let k=Float(i*13+seed*61)
            holes.append(SIMD3(0.04+hash(k)*0.92,0.08+hash(k+2)*0.75,0.021+hash(k+3)*0.023))
        }
        func distance(_ uv:SIMD2<Float>)->Float {
            var value:Float=1
            for hole in holes {
                let d=SIMD2((uv.x-hole.x)*2.8,(uv.y-hole.y)*0.83)
                value=min(value,simd_length(d)-hole.z*(1+age*5.5))
            }
            return value
        }
        let distances=coordinates.map{distance($0)}
        var crossings=[Edge:Int]()
        func intersection(_ a:Int,_ b:Int)->Int {
            let edge=Edge(a,b)
            if let index=crossings[edge] {return index}
            let f=distances[a]/(distances[a]-distances[b]),index=nodes.count
            nodes.append(Node(p:simd_mix(nodes[a].p,nodes[b].p,SIMD3(repeating:f)),v:simd_mix(nodes[a].v,nodes[b].v,SIMD3(repeating:f))))
            coordinates.append(simd_mix(coordinates[a],coordinates[b],SIMD2(repeating:f)))
            crossings[edge]=index;return index
        }
        func append(_ a:Int,_ b:Int,_ c:Int) {
            let p=nodes[a].p,q=nodes[b].p,r=nodes[c].p
            guard max(simd_distance(p,q),max(simd_distance(q,r),simd_distance(r,p)))<0.42 else{return}
            triangles.append(SIMD3(a,b,c))
            for e in [Edge(a,b),Edge(b,c),Edge(c,a)] {edges[e,default:0]+=1}
        }
        func clip(_ a:Int,_ b:Int,_ c:Int) {
            let input=[a,b,c];var polygon=[Int]()
            for i in 0..<3 {
                let previous=input[(i+2)%3],current=input[i]
                let pin=distances[previous]>=0,cin=distances[current]>=0
                if cin != pin {polygon.append(intersection(previous,current))}
                if cin {polygon.append(current)}
            }
            if polygon.count>=3 {for i in 1..<(polygon.count-1) {append(polygon[0],polygon[i],polygon[i+1])}}
        }
        for j in 0..<rows {for i in 0..<columns {
            let a=j*stride+i,b=a+1,c=a+stride,d=c+1
            clip(a,b,c);clip(c,b,d)
        }}
        var normals=[SIMD3<Float>](repeating:.zero,count:nodes.count)
        var areas=[Float](repeating:0,count:nodes.count)
        for tri in triangles {
            let n=simd_cross(nodes[tri.y].p-nodes[tri.x].p,nodes[tri.z].p-nodes[tri.x].p)
            for i in [tri.x,tri.y,tri.z] {normals[i]+=n;areas[i]+=simd_length(n)/6}
        }
        var vertices=[WaterSurfaceVertex]();vertices.reserveCapacity(triangles.count*3+edges.count*12)
        let fade=1-WaterScene.smooth(0.43,0.68,age)
        func vertex(_ p:SIMD3<Float>,_ n:SIMD3<Float>,_ thick:Float,_ kind:Float)->WaterSurfaceVertex {
            WaterSurfaceVertex(positionThickness:SIMD4(p.x,p.y,p.z,thick),normal:SIMD4(n.x,n.y,n.z,0),material:SIMD4(fade,kind,0,0))
        }
        for tri in triangles {
            for i in [tri.x,tri.y,tri.z] {
                let p=nodes[i].p,n=simd_normalize(normals[i]+SIMD3(0,0,0.000001))
                let v=coordinates[i].y
                let thickness=max(0.007,min(0.10,0.00014/max(0.001,areas[i])))*(0.7+v*0.65)
                var value=vertex(p,n,thickness,0)
                value.normal.w=coordinates[i].x;value.material.w=v
                vertices.append(value)
            }
        }
        // Cylindrical water rims give the silhouettes thickness and grazing
        // highlights that the previous screen-space panel could not represent.
        let sides=6
        for (edge,count) in edges.sorted(by:{$0.key.a==$1.key.a ? $0.key.b<$1.key.b:$0.key.a<$1.key.a}) where count==1 {
            let p=nodes[edge.a].p,q=nodes[edge.b].p
            guard simd_distance(p,q)>0.00001 else {continue}
            let t=simd_normalize(q-p)
            let helper=abs(t.z)>0.8 ? SIMD3<Float>(0,1,0):SIMD3<Float>(0,0,1)
            let n=simd_normalize(simd_cross(t,helper)),b=simd_cross(t,n)
            let k=Float(edge.a+seed*19),outer=coordinates[edge.a].y>0.999 && coordinates[edge.b].y>0.999
            let radius:Float=(outer ? 0.027+0.016*hash(k):0.013+0.013*hash(k))*(1-age*0.45)
            for j in 0..<sides {
                let a=Float(j)*2*Float.pi/Float(sides),a1=Float(j+1)*2*Float.pi/Float(sides)
                let na=n*cos(a)+b*sin(a),nb=n*cos(a1)+b*sin(a1)
                let va=vertex(p+na*radius,na,radius*2.8,1),vb=vertex(q+na*radius,na,radius*2.8,1)
                let vc=vertex(p+nb*radius,nb,radius*2.8,1),vd=vertex(q+nb*radius,nb,radius*2.8,1)
                vertices += [va,vb,vc,vc,vb,vd]
            }
        }
        var rim=[WaterPart]()
        for i in 0..<150 {
            let key=Float(i*29+seed*101),u=hash(key)
            let edgeIndex=rows*stride+min(columns,Int(u*Float(columns)))
            let birth=hash(key+1)*0.12,flight=max(0,age-birth)
            let node=point(age:birth,seed:seed,index:edgeIndex)
            let n=simd_normalize(SIMD3(node.p.x+0.3,node.p.y+0.17,0.1))
            let impulse=node.v+n*(2.5+hash(key+2)*5)
            let p=node.p+impulse*flight+SIMD3(0,flight*flight*4,0)
            let size=hash(key+3)
            let dropRadius:Float=size>0.94 ? 0.055+(size-0.94)*0.65:0.014+0.028*size*size
            let r:Float=dropRadius*sqrt(max(0,fade))*WaterScene.smooth(0,0.025,age)
            if r>0.002 {
                rim.append(WaterPart(centerSize:SIMD4(p.x,p.y,p.z,r),shape:SIMD4(1.25,0.8,atan2(impulse.y,impulse.x),1),material:SIMD4(u,Float(7000+i),age,1)))
            }
        }
        return Surface(vertices:vertices,rim:rim)
    }
}
