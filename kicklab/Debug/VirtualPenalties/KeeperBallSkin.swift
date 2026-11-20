#if DEBUG && BALL_DETECTION_DEBUG
import CoreGraphics
import Foundation
import RealityKit
import simd

/// Adapts Juggle Dude's existing material maps to the goal's 3D ball. The camera
/// overlay uses the main app's sphere renderer, prepared once off the frame loop.
nonisolated enum KeeperBallSkin {
    struct Prepared: Sendable {
        let color: CGImage
        let normal: CGImage
        let spin: [CGImage]
    }
    static let choices=BallSkin.allCases.filter { $0 != .original }

    static func prepare(_ skin: BallSkin) -> Prepared? {
        let width=1024,height=512
        guard let artwork=BallCollectionMaterial.artwork(skin:skin,width:width,height:height,panelSites:[]) else { return nil }
        var color=artwork.rgba
        var normal=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height {
            let latitude=Float.pi/2-(Float(y)+0.5)/Float(height)*Float.pi
            for x in 0..<width {
                let i=y*width+x,p=i*4
                let gap=Float(color[p+3])/2550
                let groove=1-smooth(skin == .volt ? 0.018:0.002,skin == .volt ? 0.030:0.011,gap)
                var rgb=SIMD3<Float>(Float(color[p]),Float(color[p+1]),Float(color[p+2]))/255
                if skin == .lava {
                    let crack=1-smooth(0.003,0.013,gap)
                    rgb=rgb*(1-crack)+SIMD3<Float>(1,0.30,0.025)*crack
                } else if skin != .metal {
                    rgb *= 1-groove*(skin == .volt ? 0.90:0.42)
                }
                for c in 0..<3 { color[p+c]=byte(rgb[c]) }
                // The source alpha contains seam distance, never transparency.
                color[p+3]=255
                let longitude=(Float(x)+0.5)/Float(width)*2*Float.pi-Float.pi
                let sl=sin(longitude),cl=cos(longitude),sp=sin(latitude),cp=cos(latitude)
                let tangent=SIMD3<Float>(cl,0,-sl)
                let bitangent=SIMD3<Float>(-sl*sp,cp,-cl*sp)
                let outward=SIMD3<Float>(sl*cp,sp,cl*cp)
                let n=simd_normalize(SIMD3<Float>(Float(artwork.normals[i*3]),
                    Float(artwork.normals[i*3+1]),Float(artwork.normals[i*3+2]))/127.5-1)
                // Convert the collection's object normals to the mesh UV basis.
                let local=SIMD3<Float>(simd_dot(n,tangent),simd_dot(n,bitangent),simd_dot(n,outward))
                for c in 0..<3 { normal[p+c]=byte(local[c]*0.5+0.5) }
            }
        }
        guard let colorImage=image(color,width:width,height:height),
              let normalImage=image(normal,width:width,height:height) else { return nil }
        let frames=(0..<32).compactMap { frame -> CGImage? in
            guard !Task.isCancelled else { return nil }
            let rotation=simd_quatf(angle:Float(frame)/32*2*Float.pi,axis:simd_normalize([0.4,1,0.15]))
            return BallSkinSphereRenderer.previewImage(skin:skin,time:0,orientation:rotation)
        }
        guard frames.count==32 else { return nil }
        return Prepared(color:colorImage,normal:normalImage,spin:frames)
    }

    @MainActor static func material(_ skin: BallSkin,prepared: Prepared) throws -> PhysicallyBasedMaterial {
        var material=PhysicallyBasedMaterial()
        material.baseColor = .init(texture:.init(try TextureResource(image:prepared.color,options:.init(semantic:.color))))
        material.normal.texture = .init(try TextureResource(image:prepared.normal,options:.init(semantic:.normal)))
        material.roughness = .init(floatLiteral:skin == .chrome || skin == .metal || skin == .gold ? 0.26:skin == .pearl ? 0.36:0.62)
        material.metallic = .init(floatLiteral:skin == .chrome || skin == .metal ? 0.85:skin == .gold ? 0.65:0)
        return material
    }

    @MainActor static func mesh() throws -> MeshResource {
        let columns=64,rows=32
        var vertices=[SIMD3<Float>](),normals=[SIMD3<Float>](),uv=[SIMD2<Float>](),indices=[UInt32]()
        for y in 0...rows { for x in 0...columns {
            let u=Float(x)/Float(columns),v=Float(y)/Float(rows)
            let longitude=u*2*Float.pi-Float.pi,latitude=Float.pi/2-v*Float.pi
            let n=SIMD3<Float>(sin(longitude)*cos(latitude),sin(latitude),cos(longitude)*cos(latitude))
            vertices.append(n*0.11);normals.append(n);uv.append([u,1-v])
        } }
        for y in 0..<rows { for x in 0..<columns {
            let a=UInt32(y*(columns+1)+x),b=a+1,c=a+UInt32(columns+1),d=c+1
            indices += [a,c,b,b,c,d]
        } }
        var descriptor=MeshDescriptor(name:"Juggle Dude football")
        descriptor.positions = .init(vertices);descriptor.normals = .init(normals)
        descriptor.textureCoordinates = .init(uv);descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from:[descriptor])
    }

    private static func smooth(_ low: Float,_ high: Float,_ value: Float) -> Float {
        let t=max(0,min(1,(value-low)/(high-low)))
        return t*t*(3-2*t)
    }
    private static func byte(_ value: Float) -> UInt8 { UInt8(max(0,min(255,(value*255).rounded()))) }
    private static func image(_ bytes: [UInt8],width: Int,height: Int) -> CGImage? {
        guard let provider=CGDataProvider(data:Data(bytes) as CFData) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}
#endif
