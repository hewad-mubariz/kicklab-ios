import CoreGraphics
import Foundation
import simd
import UIKit
import XCTest
@testable import kicklab

@MainActor final class BallSkinMetalTests: XCTestCase {
    private let skins = BallSkin.allCases.filter { $0 != .original && !$0.isLabSkin }
    private func bytes(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }
    private func compare(_ a: CGImage, _ b: CGImage, label: String) {
        let a = bytes(a), b = bytes(b)
        XCTAssertEqual(a.count, b.count)
        guard a.count == b.count else { return }
        var maxRGB = 0, maxAlpha = 0, sum = 0
        for i in a.indices {
            let d = abs(Int(a[i])-Int(b[i])); sum += d
            if i%4 == 3 { maxAlpha = max(maxAlpha,d) } else { maxRGB = max(maxRGB,d) }
        }
        XCTAssertLessThanOrEqual(maxRGB, 2, label)
        XCTAssertLessThanOrEqual(maxAlpha, 1, label)
        XCTAssertLessThan(Double(sum)/Double(a.count), 0.01, label)
    }

    func testAllArtworkMatchesCPUAtBothSizesAndPoseSources() throws {
        let renderer = try BallSkinMetalRenderer()
        for skin in skins {
            let maps = try XCTUnwrap(BallCollectionMaterial.artwork(skin:skin,width:1024,height:512,panelSites:[]))
            for preview in [false,true] { for time in [0.0,1.7] { for sourcePose in [false,true] {
                let q = sourcePose ? simd_quatf(angle:0.79,axis:simd_normalize(SIMD3<Float>(0.2,1,0.3))) : nil
                let t = Float((time*60).rounded()/60)
                let pose = q ?? (simd_quatf(angle:t*1.1+0.35,axis:SIMD3(0,1,0))*simd_quatf(angle:t*0.29+0.18,axis:SIMD3(1,0,0)))
                let cpu = try BallSkinMetalRenderer.$forceCPUForReview.withValue(true) {
                    try XCTUnwrap(BallSkinSphereRenderer.uncachedImageForReview(skin:skin,time:time,orientation:q,preview:preview))
                }
                let gpu = try XCTUnwrap(renderer.image(skin:skin,size:preview ? 144 : 256,pose:pose,rgba:maps.rgba,normals:maps.normals,permitsGPU:{true}))
                compare(cpu,gpu,label:"\(skin), preview \(preview), source pose \(sourcePose)")
            } } }
            XCTAssertLessThanOrEqual(renderer.retainedBytesForReview, 2*1024*512*7+256*256*4)
        }
    }

    func testFailureAndCPUOnlyBackgroundKeepSameBall() throws {
        BallSkinMetalRenderer.observeApplication()
        let pose = simd_quatf(angle:0.32,axis:SIMD3<Float>(0,1,0))
        func image() throws -> CGImage { try XCTUnwrap(BallSkinSphereRenderer.uncachedImageForReview(skin:.arctic,time:2,orientation:pose)) }
        let expected = try BallSkinMetalRenderer.$forceCPUForReview.withValue(true) { try image() }
        let failed = try BallSkinMetalRenderer.$failDrawForReview.withValue(true) { try image() }
        XCTAssertEqual(bytes(expected), bytes(failed), "GPU draw failure must render the real CPU material")
        let lease = VideoWorkLease(allowed:true,cpuOnly:true,backgroundGPU:false)
        lease.setForeground(false)
        try VideoWorkExecution.$lease.withValue(lease) {
            XCTAssertFalse(BallSkinMetalRenderer.isAllowed)
            XCTAssertEqual(bytes(expected),bytes(try image()))
            lease.setForeground(true)
            XCTAssertEqual(BallSkinMetalRenderer.isAllowed, UIApplication.shared.applicationState == .active)
        }
        let gpuLease = VideoWorkLease(allowed:true,cpuOnly:false,backgroundGPU:true)
        gpuLease.setForeground(false)
        VideoWorkExecution.$lease.withValue(gpuLease) {
            XCTAssertTrue(BallSkinMetalRenderer.isAllowed)
            gpuLease.expire()
            XCTAssertFalse(BallSkinMetalRenderer.isAllowed)
        }
    }

    func testBackgroundTransitionBeforeSubmissionRefusesGPU() throws {
        let renderer=try BallSkinMetalRenderer()
        let maps=try XCTUnwrap(BallCollectionMaterial.artwork(skin:.lava,width:1024,height:512,panelSites:[]))
        var checks=0
        let result=renderer.image(skin:.lava,size:256,pose:simd_quatf(angle:0,axis:SIMD3(0,1,0)),rgba:maps.rgba,normals:maps.normals) {
            checks += 1
            return checks == 1 // loses access after entry, before committing the command
        }
        XCTAssertNil(result)
        XCTAssertEqual(checks,2)
        XCTAssertNotNil(renderer.image(skin:.lava,size:256,pose:simd_quatf(angle:0,axis:SIMD3(0,1,0)),rgba:maps.rgba,normals:maps.normals,permitsGPU:{true}))
    }
}
