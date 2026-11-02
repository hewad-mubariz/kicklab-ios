// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app,
// and the neighbour grid is a flat counting sort instead of a dictionary (same sums, same order).
import Foundation
import simd

/// Rendering-only local covariance reconstruction. Numerical fluid positions,
/// velocities, emission timing and burst strength are unchanged.
nonisolated enum WaterOptics {
    struct Kernel {
        var shape=SIMD4<Float>(1,1,0,1)
        var quadric0=SIMD4<Float>(1,0,0,1)
        var quadric1=SIMD4<Float>(0,1,1,1)
    }
    private struct Cell:Hashable {var x,y:Int}
    private struct Moments {
        var xx:Float=0,xy:Float=0,xz:Float=0,yy:Float=0,yz:Float=0,zz:Float=0,total:Float=0,count=0
        mutating func add(_ d:SIMD3<Float>,h:Float) {
            let r2=simd_length_squared(d)
            guard r2<h*h else {return}
            let w=pow(1-r2/(h*h),2)
            xx+=d.x*d.x*w;xy+=d.x*d.y*w;xz+=d.x*d.z*w
            yy+=d.y*d.y*w;yz+=d.y*d.z*w;zz+=d.z*d.z*w;total+=w;count+=1
        }
        var kernel:Kernel {
            guard count>=3,total>0.15 else {return Kernel()}
            // Regularization bounds anisotropy without a full eigensolve. A
            // determinant normalization preserves the volume of each kernel.
            let regularizer=(xx+yy+zz)*0.12+0.0004
            var c=simd_float3x3(columns:(SIMD3(xx+regularizer,xy,xz),SIMD3(xy,yy+regularizer,yz),SIMD3(xz,yz,zz+regularizer)))
            c *= 1/pow(max(0.000000000001,simd_determinant(c)),Float(1)/3)
            let a=simd_inverse(c)
            let trace=c[0].x+c[1].y,delta=sqrt(pow(c[0].x-c[1].y,2)+4*c[0].y*c[0].y)
            let sx=sqrt(max(0.001,(trace+delta)*0.5)),sy=sqrt(max(0.001,(trace-delta)*0.5))
            return Kernel(shape:SIMD4(sx,sy,0.5*atan2(2*c[0].y,c[0].x-c[1].y),1),
                quadric0:SIMD4(a[0].x,a[0].y,a[0].z,a[1].y),quadric1:SIMD4(a[1].z,a[2].z,c[0].x,c[1].y))
        }
    }
    static func kernels(_ atoms:[WaterFlow.Atom])->[Kernel] {
        let h:Float=0.32
        guard !atoms.isEmpty else {return []}
        var cx=[Int](repeating:0,count:atoms.count),cy=cx
        var lowX=Int.max,lowY=Int.max,highX=Int.min,highY=Int.min
        for i in atoms.indices {
            let x=Int(floor(atoms[i].p.x/h)),y=Int(floor(atoms[i].p.y/h))
            cx[i]=x;cy[i]=y
            lowX=min(lowX,x);highX=max(highX,x);lowY=min(lowY,y);highY=max(highY,y)
        }
        let width=highX-lowX+1,height=highY-lowY+1
        guard width<=2048,height<=2048 else {return sparseKernels(atoms,h:h)}
        // Each cell lists its atoms in ascending order, as the lab's dictionary appended them, so
        // every neighbour sum adds the same terms in the same order.
        var start=[Int](repeating:0,count:width*height+1)
        for i in atoms.indices {start[(cy[i]-lowY)*width+cx[i]-lowX+1]+=1}
        for c in 0..<width*height {start[c+1]+=start[c]}
        var fill=start,members=[Int](repeating:0,count:atoms.count)
        for i in atoms.indices {let c=(cy[i]-lowY)*width+cx[i]-lowX;members[fill[c]]=i;fill[c]+=1}
        return atoms.indices.map { i in
            let p=atoms[i].p
            var moments=Moments()
            for y in max(lowY,cy[i]-1)...min(highY,cy[i]+1) {for x in max(lowX,cx[i]-1)...min(highX,cx[i]+1) {
                let c=(y-lowY)*width+x-lowX
                for k in start[c]..<start[c+1] where members[k] != i {moments.add(atoms[members[k]].p-p,h:h)}
            }}
            return moments.kernel
        }
    }
    /// The lab's dictionary grid, for atoms spread too far for a flat one.
    static func sparseKernels(_ atoms:[WaterFlow.Atom],h:Float)->[Kernel] {
        var cells=[Cell:[Int]]()
        for i in atoms.indices {
            let p=atoms[i].p
            cells[Cell(x:Int(floor(p.x/h)),y:Int(floor(p.y/h))),default:[]].append(i)
        }
        return atoms.indices.map { i in
            let p=atoms[i].p,cx=Int(floor(p.x/h)),cy=Int(floor(p.y/h))
            var moments=Moments()
            for y in (cy-1)...(cy+1) {for x in (cx-1)...(cx+1) {
                for j in cells[Cell(x:x,y:y)] ?? [] where j != i {moments.add(atoms[j].p-p,h:h)}
            }}
            return moments.kernel
        }
    }
}
