// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
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
    static func kernels(_ atoms:[WaterFlow.Atom])->[Kernel] {
        let h:Float=0.32
        var cells=[Cell:[Int]]()
        for i in atoms.indices {
            let p=atoms[i].p
            cells[Cell(x:Int(floor(p.x/h)),y:Int(floor(p.y/h))),default:[]].append(i)
        }
        return atoms.indices.map { i in
            let p=atoms[i].p,cx=Int(floor(p.x/h)),cy=Int(floor(p.y/h))
            var xx:Float=0,xy:Float=0,xz:Float=0,yy:Float=0,yz:Float=0,zz:Float=0,total:Float=0,count=0
            for y in (cy-1)...(cy+1) {for x in (cx-1)...(cx+1) {
                for j in cells[Cell(x:x,y:y)] ?? [] where j != i {
                    let d=atoms[j].p-p,r2=simd_length_squared(d)
                    guard r2<h*h else {continue}
                    let w=pow(1-r2/(h*h),2)
                    xx+=d.x*d.x*w;xy+=d.x*d.y*w;xz+=d.x*d.z*w
                    yy+=d.y*d.y*w;yz+=d.y*d.z*w;zz+=d.z*d.z*w;total+=w;count+=1
                }
            }}
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
}
