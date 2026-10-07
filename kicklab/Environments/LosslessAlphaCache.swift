import Compression
import CoreVideo
import Foundation

/// Numeric alpha is independent of the video codec and indexed by the exact
/// color-frame timestamp. LZFSE changes storage size, never coverage values.
nonisolated enum LosslessAlphaCache {
    private struct Frame: Codable {let time: Double;let offset: Int;let length: Int;let compressed: Bool}
    private struct Index: Codable {let version: Int;let width: Int;let height: Int;let frames: [Frame]}
    private static func failure() -> NSError {
        NSError(domain:"KickLab.AlphaCache",code:1,userInfo:[NSLocalizedDescriptionKey:"The saved cutout mask is missing or damaged. Prepare this clip again."])
    }

    final class Writer {
        private let folder: URL
        private let handle: FileHandle
        private let width: Int,height: Int
        private var frames: [Frame]=[]
        private var offset=0
        init(folder: URL,width: Int,height: Int) throws {
            guard width>0,height>0,width<=4096,height<=4096 else {throw failure()}
            self.folder=folder;self.width=width;self.height=height
            let url=folder.appendingPathComponent("alpha.lzfse")
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else {throw failure()}
            handle=try FileHandle(forWritingTo:url)
        }
        deinit {try? handle.close()}
        func append(_ pixels: CVPixelBuffer,at time: Double) throws {
            let format=CVPixelBufferGetPixelFormatType(pixels)
            guard CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,
                  format==kCVPixelFormatType_32BGRA || format==kCVPixelFormatType_OneComponent8,
                  time.isFinite,time>=0,frames.last.map({time>$0.time}) ?? true else {throw failure()}
            var raw=[UInt8](repeating:0,count:width*height)
            CVPixelBufferLockBaseAddress(pixels,.readOnly)
            let src=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels),step=format==kCVPixelFormatType_OneComponent8 ? 1:4
            for y in 0..<height {for x in 0..<width {raw[y*width+x]=src[y*row+x*step]}}
            CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
            var encoded=[UInt8](repeating:0,count:raw.count+65536)
            let count=encoded.withUnsafeMutableBufferPointer {dst in raw.withUnsafeBufferPointer {src in
                compression_encode_buffer(dst.baseAddress!,dst.count,src.baseAddress!,src.count,nil,COMPRESSION_LZFSE)
            }}
            let compressed=count>0 && count<raw.count
            let data=compressed ? Data(encoded.prefix(count)):Data(raw)
            try handle.write(contentsOf:data)
            frames.append(Frame(time:time,offset:offset,length:data.count,compressed:compressed));offset+=data.count
        }
        func finish() throws {
            guard !frames.isEmpty else {throw failure()}
            try handle.synchronize()
            try JSONEncoder().encode(Index(version:1,width:width,height:height,frames:frames))
                .write(to:folder.appendingPathComponent("alpha-index.json"),options:.atomic)
        }
    }

    final class Reader {
        private let index: Index
        private let data: Data
        private var last: (Int,CVPixelBuffer)?
        var frameCount: Int {index.frames.count}
        init(folder: URL) throws {
            index=try JSONDecoder().decode(Index.self,from:Data(contentsOf:folder.appendingPathComponent("alpha-index.json")))
            data=try Data(contentsOf:folder.appendingPathComponent("alpha.lzfse"),options:.mappedIfSafe)
            guard index.version==1,index.width>0,index.height>0,index.width<=4096,index.height<=4096,!index.frames.isEmpty else {throw failure()}
            var end=0,previous = -Double.infinity
            for frame in index.frames {
                guard frame.time.isFinite,frame.time>=0,frame.time>previous,frame.offset==end,
                      frame.length>0,frame.offset<=data.count,frame.length<=data.count-frame.offset,
                      frame.compressed || frame.length==index.width*index.height else {throw failure()}
                previous=frame.time;end=frame.offset+frame.length
            }
            guard end==data.count else {throw failure()}
        }
        func frame(at time: Double) throws -> CVPixelBuffer {
            guard time.isFinite else {throw failure()}
            var lo=0,hi=index.frames.count
            while lo<hi {let mid=(lo+hi)/2;if index.frames[mid].time<time {lo=mid+1}else {hi=mid}}
            var selected=min(index.frames.count-1,lo)
            if selected>0,abs(index.frames[selected-1].time-time)<abs(index.frames[selected].time-time) {selected-=1}
            // Callers use decoded color PTS, not an independent wall clock.
            guard abs(index.frames[selected].time-time)<0.003 else {throw failure()}
            if let last,last.0==selected {return last.1}
            let entry=index.frames[selected],count=index.width*index.height
            var bytes=[UInt8](repeating:0,count:count)
            if entry.compressed {
                let decoded=bytes.withUnsafeMutableBufferPointer {dst in data.withUnsafeBytes {src in
                    compression_decode_buffer(dst.baseAddress!,dst.count,src.baseAddress!.assumingMemoryBound(to:UInt8.self).advanced(by:entry.offset),entry.length,nil,COMPRESSION_LZFSE)
                }}
                guard decoded==count else {throw failure()}
            } else {data.copyBytes(to:&bytes,from:entry.offset..<entry.offset+entry.length)}
            let pixels=try ForegroundMaskProcessor.buffer(width:index.width,height:index.height,format:kCVPixelFormatType_OneComponent8)
            CVPixelBufferLockBaseAddress(pixels,[])
            let dst=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels)
            bytes.withUnsafeBufferPointer {src in for y in 0..<index.height {dst.advanced(by:y*row).update(from:src.baseAddress!.advanced(by:y*index.width),count:index.width)}}
            CVPixelBufferUnlockBaseAddress(pixels,[])
            last=(selected,pixels);return pixels
        }
    }
}
