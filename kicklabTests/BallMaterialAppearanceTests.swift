import CoreImage
import CoreVideo
import simd
import XCTest
@testable import kicklab

final class BallMaterialAppearanceTests: XCTestCase {
    func testSurfaceCoordinatesIgnoreFineOutlineNoise() {
        let size = CGSize(width:720,height:1280)
        let stable = BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:640),radius:50,
            radii:Array(repeating:50,count:64),feather:1,padding:0)
        // Contour changes alone must not make printed landmarks swim around
        // the ball while the centre, size and source orientation stay fixed.
        let noisy = BallReplacementFootprint(sourceSize:size,center:stable.center,radius:50,
            radii:(0..<64).map {50+6*cos(Double($0)*2 * .pi/64*8)},feather:1,padding:0)
        let a = BallMaterialRenderer.SurfaceProjection(footprint:stable)
        let b = BallMaterialRenderer.SurfaceProjection(footprint:noisy)
        for y in stride(from:610.0,through:670.0,by:10) {
            for x in stride(from:330.0,through:390.0,by:10) {
                XCTAssertEqual(a.point(x:x,y:y).x,b.point(x:x,y:y).x,accuracy:1e-12)
                XCTAssertEqual(a.point(x:x,y:y).y,b.point(x:x,y:y).y,accuracy:1e-12)
            }
        }
        XCTAssertEqual(a.point(x:385,y:640).x,0.5,accuracy:1e-12)
        XCTAssertEqual(a.point(x:360,y:665).y,0.5,accuracy:1e-12)
    }

    func testEllipticalProjectionKeepsViewAxesAndIsScaleIndependent() {
        let angle = 0.6, c = cos(angle), s = sin(angle)
        for scale in [0.5,1,1.5,3] {
            let f = BallReplacementFootprint(sourceSize:CGSize(width:720*scale,height:1280*scale),
                center:CGPoint(x:360*scale,y:640*scale),radius:50*scale,
                radii:(0..<64).map {(50+10*cos(2*(Double($0)*2 * .pi/64-angle)))*scale},
                feather:scale,padding:0)
            let p = BallMaterialRenderer.SurfaceProjection(footprint:f)
            // Inverting image-plane ellipticity must not add surface rotation.
            let x = (360+c*60*0.4-s*40*0.3)*scale
            let y = (640+s*60*0.4+c*40*0.3)*scale
            XCTAssertEqual(p.point(x:x,y:y).x,c*0.4-s*0.3,accuracy:1e-12)
            XCTAssertEqual(p.point(x:x,y:y).y,s*0.4+c*0.3,accuracy:1e-12)
        }
    }

    func testSphereRotationRevealsOtherHemisphereAndReturnsAfterFullTurn() throws {
        let identity = simd_quatf(angle:0,axis:SIMD3<Float>(0,1,0))
        let half = simd_quatf(angle:.pi,axis:SIMD3<Float>(0,1,0))
        let full = simd_quatf(angle:2 * .pi,axis:SIMD3<Float>(0,1,0))
        let images = try [identity,half,full].map {
            try XCTUnwrap(BallSkinSphereRenderer.image(skin:.galaxy,time:9,orientation:$0))
        }
        let bytes = images.map { [UInt8]($0.dataProvider!.data! as Data) }
        var halfDifference = 0.0, fullDifference = 0.0, count = 0.0
        for i in stride(from:0,to:bytes[0].count,by:4) {
            XCTAssertEqual(bytes[0][i+3],bytes[1][i+3]); XCTAssertEqual(bytes[0][i+3],bytes[2][i+3])
            for c in 0..<3 {
                halfDifference += abs(Double(bytes[0][i+c])-Double(bytes[1][i+c]))
                fullDifference += abs(Double(bytes[0][i+c])-Double(bytes[2][i+c]))
                count += 1
            }
        }
        XCTAssertGreaterThan(halfDifference/count,5)
        XCTAssertLessThan(fullDifference/count,0.02)
    }

    // A fast photographed ball can be vertically elongated while a local
    // circular fit locks onto its lower half. Include a right-side occluder.
    private func elongatedMask() -> BallMask {
        let w=104,h=144
        let alpha=(0..<(w*h)).map { i -> UInt8 in
            let x=Double(i%w)+0.5-52,y=Double(i/w)+0.5-72
            let inside=x*x/(48*48)+y*y/(68*68)<1
            let occluded=x>14 && y > -15 && y<35
            return inside && !occluded ? 255:0
        }
        return BallMask(rect:CGRect(x:308.0/720,y:568.0/1280,width:104.0/720,height:144.0/1280),
                        width:w,height:h,alpha:alpha)
    }

    func testFastMotionSmearCoversElongatedMaskAndMaterialCanvas() throws {
        // The track reports vertical motion. Coverage may extend into the owned
        // mask's lobes along that axis, never across it, and limbs stay in front.
        let size=CGSize(width:720,height:1280),mask=elongatedMask(),smear=CGVector(dx:0,dy:40)
        let f=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:660),radius:50,
            radii:Array(repeating:50,count:64),feather:1,padding:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:f,size:size,smear:smear)
        XCTAssertLessThan(matte.footprint.center.y,650, "Project the material around the observed elongated ball")
        XCTAssertGreaterThan(matte.coverage(x:360,y:589),0.99, "Upper lobe along the motion")
        XCTAssertGreaterThan(matte.coverage(x:360,y:700),0.99, "Lower lobe along the motion")
        XCTAssertEqual(matte.coverage(x:390,y:660),0, "Keep the occluding limb visible")
        XCTAssertEqual(matte.coverage(x:420,y:595),0, "Do not dilate the background")
        let still=BallReplacementCoverage(mask:mask,fitted:f,size:size)
        XCTAssertGreaterThan(still.coverage(x:360,y:589),0.99, "A photographed lobe is covered even when the track has no motion")
        XCTAssertEqual(still.coverage(x:390,y:660),0, "and the limb still stays in front")
        let patch=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:matte.footprint,skin:.galaxy,time:1,
            coverage:{matte.coverage(x:$0,y:$1)},coverageBounds:matte.bounds,orientation:BallSurfaceTimeline.initial,smear:smear))
        XCTAssertLessThanOrEqual(patch.image.width,256)
        XCTAssertLessThan(patch.rect.minY*1280,580)
        let bytes=[UInt8](patch.image.dataProvider!.data! as Data)
        func alpha(_ x:Double,_ y:Double) -> UInt8 {
            let ix=Int((x/720-patch.rect.minX)/patch.rect.width*Double(patch.image.width))
            let iy=Int((y/1280-patch.rect.minY)/patch.rect.height*Double(patch.image.height))
            guard ix>=0,iy>=0,ix<patch.image.width,iy<patch.image.height else {return 0}
            return bytes[iy*patch.image.bytesPerRow+ix*4+3]
        }
        XCTAssertGreaterThan(alpha(360,589),250, "The upper lobe must survive rasterization, not just the matte")
        XCTAssertEqual(alpha(390,660),0)
    }

    func testOrdinaryMaskBiasDoesNotBulgeACleanBall() {
        // Decoded masks run a few percent taller than the ball. That is bias, not
        // blur: the outline must stay one round body with no top/bottom bumps.
        let size=CGSize(width:720,height:1280),w=120,h=128
        let binary=(0..<(w*h)).map { i -> UInt8 in
            let x=Double(i%w)+0.5-60,y=Double(i/w)+0.5-64
            return x*x/(50*50)+y*y/(53*53)<1 ? 255:0
        }
        let mask=BallMask(rect:CGRect(x:300.0/720,y:576.0/1280,width:120.0/720,height:128.0/1280),width:w,height:h,
                          alpha:BallMask.featheredCoverage(binary,width:w,height:h))
        let f=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:640),radius:50,
            radii:Array(repeating:50,count:64),feather:1,padding:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:f,size:size)
        let r=matte.footprint.radius
        for i in 0..<96 {
            let angle=Double(i)*2 * .pi/96
            XCTAssertEqual(matte.coverage(x:360+cos(angle)*(r+2.5),y:640+sin(angle)*(r+2.5)),0,accuracy:1e-9,"angle \(i)")
        }
    }

    func testMaskCoverageAndCutoutScaleAcrossPreviewAndExportResolutions() {
        let mask=elongatedMask()
        for scale in [0.5,1,1.5,3] {
            let size=CGSize(width:720*scale,height:1280*scale)
            let f=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360*scale,y:660*scale),radius:50*scale,
                radii:Array(repeating:50*scale,count:64),feather:scale,padding:2*scale)
            let matte=BallReplacementCoverage(mask:mask,fitted:f,size:size,smear:CGVector(dx:0,dy:40*scale))
            XCTAssertEqual(matte.coverage(x:360*scale,y:589*scale),1,accuracy:0.000001)
            XCTAssertEqual(matte.coverage(x:390*scale,y:660*scale),0,accuracy:0.000001)
            XCTAssertLessThanOrEqual(matte.bounds.minY,mask.rect.minY*size.height+1e-9)
            XCTAssertGreaterThanOrEqual(matte.bounds.maxY,mask.rect.maxY*size.height-1e-9)
        }
    }

    func testAlignedRoundMaskKeepsSourceAlignmentWithoutAnExtraRim() {
        let alpha=(0..<(104*104)).map { i -> UInt8 in
            let x = Double(i%104)+0.5-52
            let y = Double(i/104)+0.5-52
            return hypot(x,y)<48 ? 255:0
        }
        let mask=BallMask(rect:CGRect(x:308.0/720,y:588.0/1280,width:104.0/720,height:104.0/1280),
                          width:104,height:104,alpha:alpha)
        let f=BallReplacementFootprint(sourceSize:CGSize(width:720,height:1280),center:CGPoint(x:360,y:640),
            radius:50,radii:Array(repeating:50,count:64),feather:1.5,padding:2,textureBlur:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:f,size:f.sourceSize)
        XCTAssertTrue(matte.reconstructsBody)
        XCTAssertEqual(matte.footprint.center.x,f.center.x,accuracy:0.02)
        XCTAssertEqual(matte.footprint.center.y,f.center.y,accuracy:0.02)
        XCTAssertEqual(matte.coverage(x:409,y:640),1,accuracy:0.001)
        XCTAssertEqual(matte.coverage(x:413,y:640),0)
        XCTAssertEqual(matte.footprint.textureBlur,f.textureBlur)
    }

    private func facetedMask(occluded: Bool = false) -> BallMask {
        let alpha = (0..<(104*104)).map { i -> UInt8 in
            let x = Double(i%104)+0.5-52, y = Double(i/104)+0.5-52
            let angle = atan2(y,x)
            let sector = (angle+4 * .pi).truncatingRemainder(dividingBy: .pi/4) - .pi/8
            let edge = 48*cos(.pi/8)/cos(sector)
            let cutout = occluded && abs(x)<10 && y < -12
            return hypot(x,y)<edge && !cutout ? 255:0
        }
        // Production masks carry the decoder's 3×3 dilation and feather; the
        // replacement corrects for exactly that outward bias.
        return BallMask(rect:CGRect(x:308.0/720,y:588.0/1280,width:104.0/720,height:104.0/1280),
                        width:104,height:104,alpha:BallMask.featheredCoverage(alpha,width:104,height:104))
    }

    func testFacetedFullMaskGetsOneSourceSupportedContour() throws {
        let mask = facetedMask()
        for scale in [0.5,1,1.5,3] {
            let size = CGSize(width:720*scale,height:1280*scale)
            let f = BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360*scale,y:640*scale),
                radius:48*scale,radii:Array(repeating:48*scale,count:64),feather:scale,padding:scale,textureBlur:2*scale)
            let matte = BallReplacementCoverage(mask:mask,fitted:f,size:size)
            // A confirmed round source must have one contour, including where
            // the coarse model supplied an octagon. No second alpha rim.
            var edges = [Double]()
            for ray in 0..<128 {
                let angle = Double(ray)*2 * .pi/128
                XCTAssertGreaterThan(matte.coverage(x:(360+cos(angle)*47)*scale,y:(640+sin(angle)*47)*scale),0.75)
                XCTAssertEqual(matte.coverage(x:(360+cos(angle)*52)*scale,y:(640+sin(angle)*52)*scale),0)
                var edge = 0.0
                for radius in stride(from:42.0,through:51.0,by:0.125) {
                    if matte.coverage(x:(360+cos(angle)*radius)*scale,y:(640+sin(angle)*radius)*scale)>0.5 {
                        edge = radius
                    }
                }
                edges.append(edge)
            }
            XCTAssertLessThan(edges.max()!-edges.min()!,1.25, "Remove the roughly four-pixel flat/corner difference")
            var rawArea = 0.0, addedArea = 0.0
            for y in stride(from:589.5,through:690.5,by:2) {
                for x in stride(from:309.5,through:410.5,by:2) {
                    let raw = mask.coverage(x:x/720,y:y/1280), repaired = matte.coverage(x:x*scale,y:y*scale)
                    rawArea += raw; addedArea += max(0,repaired-raw)
                }
            }
            XCTAssertLessThan(addedArea/rawArea,0.17, "A known 48-pixel circle bounds the reconstructed body")
            XCTAssertEqual(matte.footprint.textureBlur,f.textureBlur)
        }
    }

    func testRoundRimDoesNotFillDeepContactOrInventAnUnfittedBall() {
        let size = CGSize(width:720,height:1280)
        let f = BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:640),radius:41,
            radii:Array(repeating:41,count:64),feather:1,padding:1)
        let contact = facetedMask(occluded:true)
        let matte = BallReplacementCoverage(mask:contact,fitted:f,size:size)
        XCTAssertEqual(matte.coverage(x:360,y:600),0)
        XCTAssertEqual(matte.coverage(x:360,y:620),0)
        // Without an image fit the body comes from the mask circle, corrected for
        // the mask's outward bias: it may shrink the raw mask, never inflate it.
        let mask = facetedMask()
        let unfitted = BallReplacementCoverage(mask:mask,fitted:nil,size:size)
        var raw = 0.0, body = 0.0
        for y in 590...690 { for x in 310...410 {
            let px = Double(x), py = Double(y)
            raw += mask.coverage(x:px/720,y:py/1280); body += unfitted.coverage(x:px,y:py)
            if hypot(px-360,py-640) > 49 { XCTAssertEqual(unfitted.coverage(x:px,y:py),0) }
        } }
        XCTAssertLessThanOrEqual(body,raw)
        XCTAssertEqual(unfitted.coverage(x:360,y:640),1)
    }

    func testCroppedCapAndFalseSpikeRecoverOneRoundSourceBody() {
        let size=CGSize(width:720,height:1280),w=124,h=108
        let alpha=(0..<(w*h)).map { i -> UInt8 in
            let x=Double(i%w)+0.5-62, y=Double(i/w)+0.5-47
            let ball=x*x+y*y<50*50
            let falseTip=x>45 && x<58 && abs(y)<2
            return ball || falseTip ? 255:0
        }
        // Crop three pixels off the top; a narrow false extension is separate
        // from that missing boundary. The source itself is a 50-pixel circle.
        let mask=BallMask(rect:CGRect(x:298.0/720,y:593.0/1280,width:124.0/720,height:108.0/1280),width:w,height:h,alpha:alpha)
        let f=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:640),radius:50,
            radii:Array(repeating:50,count:64),feather:1,padding:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:f,size:size)
        XCTAssertTrue(matte.reconstructsBody)
        XCTAssertGreaterThan(matte.coverage(x:360,y:591),0.95,"Recover a crop boundary supported by the circular source")
        XCTAssertEqual(matte.coverage(x:416,y:640),0,"Reject the isolated mask spike")
        XCTAssertGreaterThan(mask.coverage(x:416.0/720,y:640.0/1280),0.95,"Owned detector alpha stays immutable")
        XCTAssertEqual(matte.coverage(x:360,y:640),1)
    }

    func testFingerCutoutUsesObservedAlphaWithoutAnAddedRim() {
        let w=120,h=120
        let alpha=(0..<(w*h)).map { i -> UInt8 in
            let x=Double(i%w)+0.5-60,y=Double(i/w)+0.5-60
            return x*x+y*y<50*50 && !(abs(x)<6 && y < -36) ? 255:0
        }
        let mask=BallMask(rect:CGRect(x:300.0/720,y:580.0/1280,width:120.0/720,height:120.0/1280),width:w,height:h,alpha:alpha)
        let f=BallReplacementFootprint(sourceSize:CGSize(width:720,height:1280),center:CGPoint(x:360,y:640),radius:50,radii:Array(repeating:50,count:64),feather:1,padding:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:f,size:f.sourceSize)
        // The finger reaches 14 px into the ball: an occluder, kept visible.
        XCTAssertEqual(matte.coverage(x:360,y:600),0)
        XCTAssertEqual(matte.coverage(x:360,y:596),0)
        XCTAssertEqual(matte.coverage(x:360,y:680),1)
        for i in 0..<96 {
            let angle=Double(i)*2 * .pi/96
            XCTAssertEqual(matte.coverage(x:360+cos(angle)*53,y:640+sin(angle)*53),0, "No added outer rim")
        }
    }

    func testInteriorHoleStaysVisibleButShallowRimNotchIsMaskNoise() {
        // An occluder must reach deep into the ball. A 4 px rim notch on a 50 px
        // ball is coarse-mask quantization; treating it as a hand made the
        // outline switch shape from frame to frame while the ball was held.
        let size=CGSize(width:720,height:1280)
        for hole in [false,true] {
            let alpha=(0..<(120*120)).map { i -> UInt8 in
                let x=Double(i%120)+0.5-60,y=Double(i/120)+0.5-60
                let cut=hole ? hypot(x,y+36)<3 : abs(x)<4 && y < -46
                return x*x+y*y<50*50 && !cut ? 255:0
            }
            let mask=BallMask(rect:CGRect(x:300.0/720,y:580.0/1280,width:120.0/720,height:120.0/1280),width:120,height:120,alpha:alpha)
            let f=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:360,y:640),radius:50,
                radii:Array(repeating:50,count:64),feather:1,padding:2)
            let matte=BallReplacementCoverage(mask:mask,fitted:f,size:size)
            XCTAssertTrue(matte.reconstructsBody)
            if hole { XCTAssertEqual(matte.coverage(x:360,y:604),0) }
            else { XCTAssertGreaterThan(matte.coverage(x:360,y:592),0.9) }
        }
    }

    func testCompleteBodyCoversOffsetPhotographedEdgeWithoutLayeredRims() {
        let size=CGSize(width:720,height:1280)
        let alpha=(0..<(120*120)).map { i -> UInt8 in
            let x=Double(i%120)+0.5-60,y=Double(i/120)+0.5-60
            return x*x+y*y<50*50 ? 255:0
        }
        let mask=BallMask(rect:CGRect(x:300.0/720,y:580.0/1280,width:120.0/720,height:120.0/1280),width:120,height:120,alpha:alpha)
        let fit=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:365,y:642),radius:50,
            radii:Array(repeating:50,count:64),feather:1,padding:2)
        let matte=BallReplacementCoverage(mask:mask,fitted:fit,size:size)
        XCTAssertTrue(matte.reconstructsBody)
        for i in 0..<96 {
            let angle=Double(i)*2 * .pi/96
            XCTAssertGreaterThan(matte.coverage(x:365+cos(angle)*50,y:642+sin(angle)*50),0.99)
        }
        XCTAssertLessThan(matte.footprint.radius,55)
    }

    func testOutdoorSavedContoursDoNotProduceRadialNotches() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"smooth-outline-controls",withExtension:"json"))
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [[String:Any]]
        for row in rows where row["contact"] as? Bool != true {
            let m=row["mask"] as! [String:Any],r=m["rect"] as! [Double]
            let mask=BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:m["width"] as! Int,
                height:m["height"] as! Int,alpha:Array(Data(base64Encoded:m["alpha"] as! String)!))
            let saved=row["fit"] as! [String:Any],c=saved["center"] as! [Double]
            let f=BallReplacementFootprint(sourceSize:CGSize(width:1080,height:1920),center:CGPoint(x:c[0],y:c[1]),
                radius:saved["radius"] as! Double,radii:saved["radii"] as! [Double],
                feather:saved["feather"] as! Double,padding:saved["padding"] as! Double)
            let matte=BallReplacementCoverage(mask:mask,fitted:f,size:f.sourceSize)
            XCTAssertTrue(matte.reconstructsBody)
            let center=matte.footprint.center,radius=matte.footprint.radius
            var outline=[Double]()
            for ray in 0..<192 {
                let angle=Double(ray)*2 * .pi/192
                var outer=0.0
                for distance in stride(from:radius*0.65,through:radius*1.3,by:0.125) {
                    if matte.coverage(x:center.x+cos(angle)*distance,y:center.y+sin(angle)*distance)>0.5 {outer=distance}
                }
                outline.append(outer)
            }
            for i in outline.indices {
                XCTAssertLessThan(abs(outline[i]-outline[(i+1)%outline.count]),1.0,
                    "Downloaded 7/17/40 s controls previously had abrupt angular rim notches")
            }
        }
    }

    func testSavedContactOutlinesKeepDeepCutoutsVisible() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"smooth-outline-controls",withExtension:"json"))
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [[String:Any]]
        var checked = 0
        for row in rows where row["contact"] as? Bool == true {
            let m=row["mask"] as! [String:Any],r=m["rect"] as! [Double],s=row["size"] as! [Double]
            let size=CGSize(width:s[0],height:s[1])
            let mask=BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:m["width"] as! Int,
                height:m["height"] as! Int,alpha:Array(Data(base64Encoded:m["alpha"] as! String)!))
            let saved=row["fit"] as! [String:Any],c=saved["center"] as! [Double]
            let fit=BallReplacementFootprint(sourceSize:size,center:CGPoint(x:c[0],y:c[1]),
                radius:saved["radius"] as! Double,radii:saved["radii"] as! [Double],
                feather:saved["feather"] as! Double,padding:saved["padding"] as! Double)
            let matte=BallReplacementCoverage(mask:mask,fitted:fit,size:size)
            let body=matte.footprint
            // Wherever the saved hand removed the ball deep inside it, the hand stays in front.
            for y in 0..<mask.height {for x in 0..<mask.width {
                let px=r[0]+(Double(x)+0.5)/Double(mask.width)*r[2], py=r[1]+(Double(y)+0.5)/Double(mask.height)*r[3]
                let dx=px*size.width-body.center.x, dy=py*size.height-body.center.y
                let depth=body.edge(at:atan2(dy,dx))-hypot(dx,dy)
                guard depth > 0.3*body.radius, mask.coverage(x:px,y:py) < 0.05 else {continue}
                XCTAssertLessThan(matte.coverage(x:px*size.width,y:py*size.height),0.1); checked += 1
            }}
        }
        XCTAssertGreaterThan(checked,0, "The saved contact controls contain deep cutouts")
    }

    private func source(blur:Double) throws -> CVPixelBuffer {
        let info=CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context=try XCTUnwrap(CGContext(data:nil,width:720,height:1280,bitsPerComponent:8,bytesPerRow:720*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info))
        context.setFillColor(CGColor(gray:0.18,alpha:1));context.fill(CGRect(x:0,y:0,width:720,height:1280))
        context.setFillColor(CGColor(gray:0.92,alpha:1));context.fillEllipse(in:CGRect(x:310,y:590,width:100,height:100))
        context.setFillColor(CGColor(gray:0.1,alpha:1));context.fillEllipse(in:CGRect(x:344,y:624,width:23,height:23))
        let image=try XCTUnwrap(context.makeImage())
        var pixels:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,720,1280,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&pixels),kCVReturnSuccess)
        var input=CIImage(cgImage:image)
        if blur>0 {input=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:blur]).cropped(to:input.extent)}
        CIContext(options:[.workingColorSpace:NSNull()]).render(input,to:pixels!)
        return pixels!
    }
    private var sample:BallStyleSample {
        BallStyleSample(frame:RecordedFrame(time:1,x:0.5,y:0.5,width:100.0/720,height:100.0/1280,score:0.9,smoothedX:0.5,smoothedY:0.5,vy:0,motion:.unknown,detected:true,person:nil))
    }
    func testSoftnessFollowsPhotographedEdgeWithoutMovingTheMask() throws {
        let sharp=try source(blur:0),soft=try source(blur:2.5)
        let a=try XCTUnwrap(BallReplacementFootprint.fit(pixels:sharp,sample:sample,measureTexture:true))
        let b=try XCTUnwrap(BallReplacementFootprint.fit(pixels:soft,sample:sample,measureTexture:true))
        let geometry=try XCTUnwrap(BallReplacementFootprint.fit(pixels:soft,sample:sample))
        XCTAssertLessThanOrEqual(a.textureBlur,1)
        XCTAssertGreaterThan(b.textureBlur,a.textureBlur+0.6)
        XCTAssertLessThanOrEqual(b.textureBlur,3)
        XCTAssertEqual(b.center,geometry.center);XCTAssertEqual(b.radii,geometry.radii)
        XCTAssertEqual(b.feather,geometry.feather);XCTAssertEqual(b.padding,geometry.padding)
    }
    func testRimSoftnessNoLongerBlursPrintButMotionSmearDoes() throws {
        // Reviewed frames: the real print is about as sharp as the video, so a soft
        // rim estimate must not soften it. Motion smear does, along the motion only.
        let f=try XCTUnwrap(BallReplacementFootprint.fit(pixels:source(blur:0),sample:sample))
        var soft=f;soft.textureBlur=3
        let coverage:(Double,Double)->Double={x,y in hypot(x-360,y-640)<49 && !(x>350 && x<370 && y<646) ? 1:0}
        let pose=BallSurfaceTimeline.initial,smear=CGVector(dx:8,dy:0)
        let a=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:f,skin:.galaxy,time:1,coverage:coverage,orientation:pose))
        let b=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:soft,skin:.galaxy,time:1,coverage:coverage,orientation:pose))
        let c=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:f,skin:.galaxy,time:1,coverage:coverage,orientation:pose,smear:smear))
        let seek=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:f,skin:.galaxy,time:90,coverage:coverage,orientation:pose,smear:smear))
        let aa=[UInt8](a.image.dataProvider!.data! as Data),bb=[UInt8](b.image.dataProvider!.data! as Data)
        let cc=[UInt8](c.image.dataProvider!.data! as Data)
        XCTAssertEqual(aa,bb, "Rim softness does not blur the print")
        XCTAssertNotEqual(aa,cc, "Motion smear blurs the print")
        XCTAssertEqual(cc,[UInt8](seek.image.dataProvider!.data! as Data), "Deterministic across seeks")
        for i in stride(from:0,to:min(aa.count,cc.count),by:4) {
            XCTAssertLessThanOrEqual(cc[i],cc[i+3]);XCTAssertLessThanOrEqual(cc[i+1],cc[i+3]);XCTAssertLessThanOrEqual(cc[i+2],cc[i+3])
        }
    }
}
