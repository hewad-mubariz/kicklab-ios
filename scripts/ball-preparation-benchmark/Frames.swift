import Foundation
import CoreGraphics

enum SavedAppearanceFrames {
    static func frames(_ url: URL) throws -> [RecordedFrame] {
        let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let rows = raw as? [[String:Any]] ?? (raw as! [String:Any])["frames"] as! [[String:Any]]
        return rows.map { row in
            let v = row["values"] as! [Double]
            var mask: BallMask?
            if let r=row["maskRect"] as? [Double], let w=row["maskWidth"] as? Int, let h=row["maskHeight"] as? Int {
                var alpha=[UInt8]()
                if let data=row["alpha"] as? Data { alpha=Array(data) }
                else if let data=row["packedAlpha"] as? Data {
                    let bytes=Array(data)
                    for i in stride(from:0,to:bytes.count,by:3) { alpha += Array(repeating:bytes[i],count:Int(bytes[i+1])+Int(bytes[i+2])*256) }
                }
                precondition(alpha.count == w*h)
                let step = (row["maskDecoderPixelSize"] as? [Double]).map { CGSize(width: $0[0], height: $0[1]) }
                mask=BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:w,height:h,alpha:alpha,decoderPixelSize:step)
            }
            return RecordedFrame(time:v[0],x:v[1],y:v[2],width:v[3],height:v[4],score:v[5],smoothedX:v[6],smoothedY:v[7],vy:v[8],motion:.unknown,detected:row["detected"] as! Bool,person:nil,ballMask:mask,usesBallMasks:row["usesMasks"] as? Bool ?? false,isVisualMaskRepair:row["repair"] as? Bool ?? false,isVisualRecovery:row["visualRecovery"] as? Bool ?? false)
        }
    }
}
