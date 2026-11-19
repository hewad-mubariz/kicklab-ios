import CoreVideo
import Foundation
import SQLite3
import XCTest
@testable import kicklab

final class PosePredictionStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = .temporaryDirectory.appendingPathComponent("pose-store-test-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) } }
    private func store(source: String = "clip", runtime: String = "phone-os", limit: Int = 1024*1024) throws -> PosePredictionStore {
        try PosePredictionStore(root:root,source:source,runtime:runtime,byteLimit:limit)
    }
    private func key(_ n: Int, kind: String = "vision-r2") -> PosePredictionStore.Key {
        .init(kind:kind,pixels:PosePredictionStore.digest(Data(String(n).utf8)))
    }
    private func pixels(width: Int = 8, alignment: Int = 64, padding: UInt8 = 0) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,width,8,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey:alignment] as CFDictionary,&pixels),kCVReturnSuccess)
        let p = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(p,[]);defer { CVPixelBufferUnlockBaseAddress(p,[]) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(p)), stride = CVPixelBufferGetBytesPerRow(p)
        memset(base,Int32(padding),stride*8)
        for row in 0..<8 { memset(base.advanced(by:row*stride),31,width*4) }
        return p
    }
    func testAllLandmarksAndEmptyResultsSurviveReopen() throws {
        var p = BodyPose()
        let point = PoseLandmark(x:0.123456789012345,y:0.87654321098765,confidence:0.81234567890123)
        for joint in BodyJoint.allCases { p.joints[joint] = .init(x:point.x,y:point.y);p.landmarks[joint] = point }
        for side in [BodySide.left,.right] { p.ankles[side]=point;p.hips[side]=point;p.wrists[side]=point }
        var other = p
        other.landmarks[.nose] = .init(x:0.91,y:0.2,confidence:0.41)
        _ = try store().store([p,other],key:key(1)); _ = try store().store([BodyPose](),key:key(2))
        let result = try XCTUnwrap(store().lookup([BodyPose].self,key:key(1)))
        XCTAssertEqual(result.count,2);XCTAssertEqual(result[0].joints,p.joints)
        XCTAssertEqual(result[0].landmarks,p.landmarks);XCTAssertEqual(result[0].ankles,p.ankles)
        XCTAssertEqual(result[0].hips,p.hips);XCTAssertEqual(result[0].wrists,p.wrists)
        XCTAssertEqual(result[0].landmarks[.nose]?.confidence.bitPattern,point.confidence.bitPattern)
        XCTAssertEqual(result[1].landmarks,other.landmarks)
        XCTAssertEqual(try store().lookup([BodyPose].self,key:key(2))?.count,0)
        XCTAssertNil(try store().lookup([BodyPose].self,key:key(3)))
    }
    func testSourceRuntimeRevisionBackendAndPixelsRemainIsolated() throws {
        _ = try store().store([1.0],key:key(1,kind:"vision-r2|cpu=false"))
        XCTAssertNil(try store(source:"another").lookup([Double].self,key:key(1,kind:"vision-r2|cpu=false")))
        XCTAssertNil(try store(runtime:"new-os").lookup([Double].self,key:key(1,kind:"vision-r2|cpu=false")))
        for k in [key(2,kind:"vision-r2|cpu=false"),key(1,kind:"vision-r1|cpu=false"),key(1,kind:"vision-r2|cpu=true")] {
            XCTAssertNil(try store().lookup([Double].self,key:k))
        }
    }
    func testPixelIdentityIncludesContentGeometryAndColorButNotPadding() throws {
        let a = try pixels(padding:1), b = try pixels(alignment:128,padding:239)
        let first = try PosePredictionStore.key(pixels:a,kind:"vision-r2")
        XCTAssertEqual(first,try PosePredictionStore.key(pixels:b,kind:"vision-r2"))
        XCTAssertNotEqual(first,try PosePredictionStore.key(pixels:try pixels(width:9),kind:"vision-r2"))
        CVPixelBufferLockBaseAddress(b,[])
        CVPixelBufferGetBaseAddress(b)!.storeBytes(of:UInt8(19),as:UInt8.self)
        CVPixelBufferUnlockBaseAddress(b,[])
        XCTAssertNotEqual(first,try PosePredictionStore.key(pixels:b,kind:"vision-r2"))
        CVBufferSetAttachment(a,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        XCTAssertNotEqual(first,try PosePredictionStore.key(pixels:a,kind:"vision-r2"))
    }
    func testFirstCommittedValueWinsDuplicateWrite() throws {
        _ = try store().store([0.8],key:key(1))
        XCTAssertEqual(try store().store([0.9],key:key(1)),[0.8])
        XCTAssertEqual(try store().lookup([Double].self,key:key(1)),[0.8])
    }
    func testCorruptionIsAnErrorAndNotAnEmptyObservation() throws {
        let s = try store();_ = try s.store([0.8],key:key(1))
        XCTAssertThrowsError(try s.lookup([BodyPose].self,key:key(1))) { XCTAssertTrue($0 is PosePredictionStore.Failure) }
        var db: OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("poses.sqlite3").path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"UPDATE observations SET payload=x'010203'",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try s.lookup([Double].self,key:key(1))) { XCTAssertTrue($0 is PosePredictionStore.Failure) }
    }
    func testFullStoreKeepsCommittedDataAndRejectsOversizedPayload() throws {
        let s = try store(limit:64*1024), payload = Data((0..<45000).map { UInt8($0%251) })
        var committed = 0, failed = false
        for i in 0..<30 { do { _ = try s.store(payload,key:key(i));committed += 1 } catch { failed=true;break } }
        XCTAssertTrue(failed);XCTAssertGreaterThan(committed,0)
        for i in 0..<committed { XCTAssertEqual(try s.lookup(Data.self,key:key(i)),payload) }
        XCTAssertNil(try s.lookup(Data.self,key:key(committed)))
        XCTAssertThrowsError(try s.store(Data(repeating:1,count:PosePredictionStore.payloadLimit+1),key:key(999)))
    }
}
