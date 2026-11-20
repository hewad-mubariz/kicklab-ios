#if DEBUG && BALL_DETECTION_DEBUG
import RealityKit
import UIKit
import simd

/// Fixed topology, updated vertex buffer: no per-frame mesh/resource creation.
@MainActor final class GoalNet {
    private struct Node { let panel: NetPanel;let uv: SIMD2<Float>;let rest: SIMD3<Float> }
    private struct Vertex { var position: SIMD3<Float>;var normal: SIMD3<Float> }
    private let mesh: LowLevelMesh
    private var nodes=[Node](),segments=[SIMD2<Int>]()
    private var deformed=false

    init(in stage: Entity) throws {
        var nodes=[Node](),segments=[SIMD2<Int>]()
        for panel in NetPanel.allCases {
            let nx=panel == .left || panel == .right ? 16:52
            let ny=panel == .roof ? 16:18
            let start=nodes.count
            for y in 0...ny { for x in 0...nx {
                let uv=SIMD2<Float>(Float(x)/Float(nx),Float(y)/Float(ny))
                nodes.append(Node(panel:panel,uv:uv,rest:panel.point(uv)))
                let i=start+y*(nx+1)+x
                if x>0 { segments.append([i-1,i]) }
                if y>0 { segments.append([i-nx-1,i]) }
            } }
        }
        self.nodes=nodes;self.segments=segments
        mesh=try LowLevelMesh(descriptor:.init(vertexCapacity:segments.count*8,
            vertexAttributes:[.init(semantic:.position,format:.float3,offset:0),
                              .init(semantic:.normal,format:.float3,offset:MemoryLayout<SIMD3<Float>>.stride)],
            vertexLayouts:[.init(bufferIndex:0,bufferStride:MemoryLayout<Vertex>.stride)],
            indexCapacity:segments.count*24,indexType:.uint32))
        mesh.withUnsafeMutableIndices { bytes in
            let indices=bytes.bindMemory(to:UInt32.self)
            for i in segments.indices { for side in 0..<4 {
                let a=UInt32(i*8+side),b=UInt32(i*8+(side+1)%4)
                let offset=i*24+side*6
                for (j,value) in [a,b,a+4,b,b+4,a+4].enumerated() { indices[offset+j]=value }
            } }
        }
        mesh.parts.replaceAll([.init(indexCount:segments.count*24,bounds:BoundingBox(min:[-5,-0.3,-4],max:[5,4,0.2]))])
        writeVertices(nodes.map(\.rest))
        let resource=try MeshResource(from:mesh)
        let net=ModelEntity(mesh:resource,materials:[SimpleMaterial(color:UIColor(white:0.76,alpha:1),roughness:1,isMetallic:false)])
        net.name="Deforming goal net";stage.addChild(net)
    }
    func update(time: Double, impacts: [NetImpact]) {
        let live=impacts.filter { time >= $0.start && ($0.released == nil || time-$0.released!<2.5) }
        guard !live.isEmpty || deformed else { return }
        deformed = !live.isEmpty
        let points=nodes.map { node -> SIMD3<Float> in
            var distance: Float=0
            for impact in live where impact.panel==node.panel { distance += impact.displacement(at:node.uv,time:time) }
            return node.rest+node.panel.normal(node.uv)*distance
        }
        writeVertices(points)
    }
    private func writeVertices(_ points: [SIMD3<Float>]) {
        mesh.withUnsafeMutableBytes(bufferIndex:0) { bytes in
            let vertices=bytes.bindMemory(to:Vertex.self)
            for (i,segment) in segments.enumerated() {
                let a=points[segment.x],b=points[segment.y],axis=simd_normalize(b-a)
                let u=simd_normalize(simd_cross(axis,abs(axis.y)<0.9 ? SIMD3<Float>(0,1,0):[1,0,0]))
                let v=simd_cross(axis,u)
                for (j,n) in [u,v,-u,-v].enumerated() {
                    vertices[i*8+j]=Vertex(position:a+n*0.006,normal:n)
                    vertices[i*8+j+4]=Vertex(position:b+n*0.006,normal:n)
                }
            }
        }
    }
}

#endif
