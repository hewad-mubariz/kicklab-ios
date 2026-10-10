import Foundation
import CoreVideo
import CoreGraphics
import simd

/// Appearance-derived incremental sphere rotation on normalized ball patches.
/// No detector, learned model, video buffer retention, or position-derived spin.
nonisolated enum BallSurfaceMotion {
    static let side = 128
    static let radius = 52.0
    static let center = 63.5

    static func patch(pixels: CVPixelBuffer, center point: CGPoint, radius r: Double) -> Gray? {
        guard r>=8,CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA else {return nil}
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        guard let bytes=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else {return nil}
        let w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),stride=CVPixelBufferGetBytesPerRow(pixels)
        guard point.x-r>1,point.y-r>1,point.x+r<Double(w-1),point.y+r<Double(h-1) else {return nil}
        func luma(_ x: Int,_ y: Int)->Double {
            let offset=y*stride+x*4
            return (Double(bytes[offset])*0.114+Double(bytes[offset+1])*0.587+Double(bytes[offset+2])*0.299)/255
        }
        var values=[Float](repeating:0,count:side*side)
        let step=r/radius
        for y in 0..<side {for x in 0..<side {
            let px=max(0,min(Double(w-2),point.x+(Double(x)-center)*step))
            let py=max(0,min(Double(h-2),point.y+(Double(y)-center)*step))
            let ix=Int(px),iy=Int(py),fx=px-Double(ix),fy=py-Double(iy)
            let top=luma(ix,iy)*(1-fx)+luma(ix+1,iy)*fx
            let bottom=luma(ix,iy+1)*(1-fx)+luma(ix+1,iy+1)*fx
            values[y*side+x]=Float(top*(1-fy)+bottom*fy)
        }}
        return Gray(width:side,values:values)
    }

    struct Gray: Sendable {
        let width: Int
        let values: [Float]
        func at(_ x: Double, _ y: Double) -> Double {
            let x=max(0,min(Double(width-1)-0.001,x)), y=max(0,min(Double(width-1)-0.001,y))
            let ix=Int(x), iy=Int(y), fx=x-Double(ix), fy=y-Double(iy)
            return (Double(values[iy*width+ix])*(1-fx)+Double(values[iy*width+ix+1])*fx)*(1-fy)
                + (Double(values[(iy+1)*width+ix])*(1-fx)+Double(values[(iy+1)*width+ix+1])*fx)*fy
        }
        func pyramid() -> [Gray] {
            var result=[self]
            for _ in 0..<2 {
                let a=result.last!, w=a.width/2
                var pixels=[Float](repeating:0,count:w*w)
                for y in 0..<w { for x in 0..<w {
                    var sum=0.0
                    for j in -1...1 {for i in -1...1 {
                        sum += a.at(Double(x*2+i),Double(y*2+j))*Double((i==0 ? 2:1)*(j==0 ? 2:1))
                    }}
                    pixels[y*w+x]=Float(sum/16)
                }}
                result.append(Gray(width:w,values:pixels))
            }
            return result
        }
    }

    struct Fit: Sendable {
        let rotation: SIMD3<Double>
        let accepted: Bool
        let matches: Int
        let residual: Double
        let disagreement: Double
    }

    static func features(_ image: Gray) -> [SIMD2<Double>] {
        var candidates=[(Double,SIMD2<Double>)]()
        for y in stride(from:20,to:108,by:2) { for x in stride(from:20,to:108,by:2) {
            guard hypot(Double(x)-center,Double(y)-center) < radius*0.80 else {continue}
            var xx=0.0, yy=0.0, xy=0.0
            for j in -1...1 {for i in -1...1 {
                let px=Double(x+i),py=Double(y+j)
                let gx=(image.at(px+1,py)-image.at(px-1,py))*0.5
                let gy=(image.at(px,py+1)-image.at(px,py-1))*0.5
                xx += gx*gx;yy += gy*gy;xy += gx*gy
            }}
            let value=(xx+yy-sqrt((xx-yy)*(xx-yy)+4*xy*xy))*0.5
            if value > 0.0008 {candidates.append((value,SIMD2(Double(x),Double(y))))}
        }}
        candidates.sort {$0.0 > $1.0}
        var selected=[SIMD2<Double>]()
        for (_,p) in candidates where selected.allSatisfy({simd_distance($0,p)>4}) {
            selected.append(p)
            if selected.count==90 {break}
        }
        return selected
    }

    /// Inverse compositional, pyramidal Lucas–Kanade. A reverse fit validates each match.
    static func follow(_ p: SIMD2<Double>, from a: [Gray], to b: [Gray]) -> SIMD2<Double>? {
        var displacement=SIMD2<Double>(repeating:0)
        for level in stride(from:2,through:0,by:-1) {
            if level<2 {displacement *= 2}
            let scale=Double(1<<level), origin=p/scale, image=a[level], target=b[level]
            var templates=[(SIMD2<Double>,Double,SIMD2<Double>)]()
            var xx=0.0,xy=0.0,yy=0.0
            for j in -6...6 {for i in -6...6 {
                let point=origin+SIMD2(Double(i),Double(j))
                let g=SIMD2((image.at(point.x+1,point.y)-image.at(point.x-1,point.y))*0.5,
                            (image.at(point.x,point.y+1)-image.at(point.x,point.y-1))*0.5)
                templates.append((point,image.at(point.x,point.y),g))
                xx += g.x*g.x;xy += g.x*g.y;yy += g.y*g.y
            }}
            let determinant=xx*yy-xy*xy
            guard determinant > 1e-7 else {return nil}
            for _ in 0..<22 {
                let q=origin+displacement
                guard q.x>3,q.y>3,q.x<Double(target.width-4),q.y<Double(target.width-4) else {return nil}
                var gradient=SIMD2<Double>(repeating:0)
                for (point,value,g) in templates {
                    let point=point+displacement
                    gradient += g*(target.at(point.x,point.y)-value)
                }
                let step=SIMD2((yy*gradient.x-xy*gradient.y)/determinant,
                              (xx*gradient.y-xy*gradient.x)/determinant)
                guard step.x.isFinite,step.y.isFinite,simd_length(step)<8 else {return nil}
                displacement -= step
                if simd_length(step)<0.025 {break}
            }
        }
        return p+displacement
    }

    private static func project(_ p: [Double], _ n: SIMD3<Double>) -> SIMD2<Double> {
        Projection(p).apply(n)
    }

    /// The same six parameters apply to every feature in an iteration. Prepare
    /// their quaternion/scale once; preserve projection and accumulation order.
    private struct Projection {
        let rotation: simd_quatd?
        let scale: Double
        let translation: SIMD2<Double>
        init(_ p: [Double]) {
            let r=SIMD3(p[0],p[1],p[2]), angle=simd_length(r)
            rotation=angle>1e-10 ? simd_quatd(angle:angle,axis:r/angle) : nil
            scale=exp(p[3]); translation=SIMD2(p[4],p[5])
        }
        func apply(_ n: SIMD3<Double>) -> SIMD2<Double> {
            let rotated=rotation?.act(n) ?? n
            return SIMD2(rotated.x,rotated.y)*scale+translation
        }
    }

    /// Six-variable robust reprojection fit includes crop scale/translation, so
    /// a shifted detector box is not interpreted as the ball spinning.
    static func solve(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>], initial: [Double]? = nil) -> [Double]? {
        var p=initial ?? [Double](repeating:0,count:6)
        let normals = a.map { SIMD3($0.x,$0.y,sqrt(max(0,1-simd_length_squared($0)))) }
        for _ in 0..<22 {
            let projection=Projection(p)
            let perturbed=(0..<6).map { j -> Projection in
                var value=p; value[j] += 0.0001
                return Projection(value)
            }
            var lhs=[[Double]](repeating:[Double](repeating:0,count:6),count:6)
            var rhs=[Double](repeating:0,count:6)
            for i in a.indices {
                let n=normals[i]
                let prediction=projection.apply(n), error=prediction-b[i]
                let weight=1/sqrt(1+simd_length_squared(error)/(0.018*0.018))
                var jacobian=[SIMD2<Double>]()
                for j in 0..<6 {
                    jacobian.append((perturbed[j].apply(n)-prediction)/0.0001)
                }
                for j in 0..<6 {
                    rhs[j] -= simd_dot(jacobian[j],error)*weight
                    for k in 0..<6 {lhs[j][k] += simd_dot(jacobian[j],jacobian[k])*weight}
                }
            }
            for j in 0..<6 {lhs[j][j] += 0.00001}
            guard let step=linear(lhs,rhs) else {return nil}
            var length=0.0
            for j in 0..<6 {p[j] += max(-0.2,min(0.2,step[j]));length += step[j]*step[j]}
            if length<1e-9 {break}
        }
        return p.allSatisfy(\.isFinite) ? p:nil
    }

    private static func linear(_ lhs: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a=lhs, b=rhs
        for i in 0..<6 {
            let pivot=(i..<6).max {abs(a[$0][i])<abs(a[$1][i])}!
            guard abs(a[pivot][i])>1e-10 else {return nil}
            if pivot != i {a.swapAt(i,pivot);b.swapAt(i,pivot)}
            let scale=a[i][i]
            for k in i..<6 {a[i][k] /= scale};b[i] /= scale
            for j in 0..<6 where j != i {
                let scale=a[j][i]
                for k in i..<6 {a[j][k] -= scale*a[i][k]};b[j] -= scale*b[i]
            }
        }
        return b
    }

    static func estimate(previous: Gray, current: Gray) -> Fit {
        let a=previous.pyramid(), b=current.pyramid()
        var from=[SIMD2<Double>](),to=[SIMD2<Double>]()
        for p in features(previous) {
            guard let q=follow(p,from:a,to:b),simd_distance(q,SIMD2(center,center)) < radius*0.90,
                  let back=follow(q,from:b,to:a),simd_distance(p,back)<1.1 else {continue}
            from.append((p-SIMD2(center,center))/radius*SIMD2(1,-1))
            to.append((q-SIMD2(center,center))/radius*SIMD2(1,-1))
        }
        let rejected=Fit(rotation:.zero,accepted:false,matches:from.count,residual:999,disagreement:999)
        guard from.count>=18,let initial=solve(from,to) else {return rejected}
        func residual(_ p: [Double], _ i: Int) -> Double {
            simd_distance(project(p,SIMD3(from[i].x,from[i].y,sqrt(max(0,1-simd_length_squared(from[i]))))),to[i])
        }
        let inliers=from.indices.filter {residual(initial,$0)<0.045}
        guard inliers.count>=18,Double(inliers.count)/Double(from.count)>0.7,
              let p=solve(inliers.map{from[$0]},inliers.map{to[$0]},initial:initial) else {return rejected}
        let sorted=inliers.sorted {atan2(from[$0].y,from[$0].x)<atan2(from[$1].y,from[$1].x)}
        let even=sorted.enumerated().filter {$0.offset%2==0}.map(\.element)
        let odd=sorted.enumerated().filter {$0.offset%2==1}.map(\.element)
        guard let one=solve(even.map{from[$0]},even.map{to[$0]},initial:p),
              let two=solve(odd.map{from[$0]},odd.map{to[$0]},initial:p) else {return rejected}
        func rotation(_ v:[Double])->simd_quatd {
            let r=SIMD3(v[0],v[1],v[2]),n=simd_length(r)
            return n>1e-10 ? simd_quatd(angle:n,axis:r/n):simd_quatd(angle:0,axis:SIMD3(1,0,0))
        }
        let disagreement=abs((rotation(one).inverse*rotation(two)).angle)*180 / .pi
        let errors=from.indices.map{residual(p,$0)*radius}.sorted()
        let median=errors[errors.count/2], p90=errors[Int(Double(errors.count-1)*0.9)]
        let xs=inliers.map{from[$0].x},ys=inliers.map{from[$0].y}
        // Demand broad 2D support, not a single printed seam or narrow sliver.
        let spanX=xs.max()!-xs.min()!,spanY=ys.max()!-ys.min()!
        let accepted=median<1.05 && p90<3.2 && disagreement<4 && spanX>0.8 && spanY>0.8
            && simd_length(SIMD3(p[0],p[1],p[2]))<65 * .pi/180 && abs(p[3])<0.12 && hypot(p[4],p[5])<0.17
        return Fit(rotation:SIMD3(p[0],p[1],p[2]),accepted:accepted,matches:from.count,residual:median,disagreement:disagreement)
    }
}
