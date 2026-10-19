#if DEBUG && BALL_DETECTION_DEBUG
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

/// Live view of a wall-targets session for a browser on the Mac (same Wi-Fi):
/// the camera at a few frames a second with the board outline and ball, and
/// every shot as a strip of frames around the moment it reached the wall.
/// `/shots.json` and `/shot/<n>.jpg` let tools on the Mac review shots as they
/// happen. Debug build only, no authentication, and only while switched on.
nonisolated final class WallTargetsLiveFeed: @unchecked Sendable {
    static let port: UInt16 = 8765

    private struct Shot {
        let id: Int
        let t: Double
        let box: Int?
        let u, v: Double
        let jpeg: Data
    }

    private let lock = NSLock()
    private let context = CIContext()
    private let serverQueue = DispatchQueue(label: "com.juggledude.wall-targets.live")
    private var listener: NWListener?
    // Guarded by lock.
    private var frames: [(t: Double, image: CGImage)] = []
    private var latestJPEG = Data()
    private var lastJPEGTime = -Double.infinity
    private var state: [String: Any] = [:]
    private var shots: [Shot] = []

    // MARK: Server

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.service = NWListener.Service(name: "Wall targets", type: "_wallTargets._tcp")
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: serverQueue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else { connection.cancel(); return }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "/") : "/"
            let (status, type, body) = self.response(for: path)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for path: String) -> (String, String, Data) {
        lock.lock(); defer { lock.unlock() }
        switch path {
        case "/":
            return ("200 OK", "text/html; charset=utf-8", Data(Self.page.utf8))
        case "/frame.jpg":
            return ("200 OK", "image/jpeg", latestJPEG)
        case "/state.json":
            return ("200 OK", "application/json", json(state))
        case "/shots.json":
            return ("200 OK", "application/json", json(shots.map { shot -> [String: Any] in
                ["id": shot.id, "t": shot.t, "box": shot.box.map { $0 as Any } ?? NSNull(),
                 "u": shot.u, "v": shot.v, "image": "/shot/\(shot.id).jpg"]
            }))
        default:
            if path.hasPrefix("/shot/"), path.hasSuffix(".jpg"),
               let id = Int(path.dropFirst(6).dropLast(4)), let shot = shots.first(where: { $0.id == id }) {
                return ("200 OK", "image/jpeg", shot.jpeg)
            }
            return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    // MARK: Camera side (called on the camera queue)

    /// Retain the latest JPEG and shot history for review, but release decoded
    /// camera images while idle or while optional preview work is heat-limited.
    func clearFrameCache() {
        lock.withLock { frames.removeAll(keepingCapacity: false) }
    }

    /// Keeps a downscaled copy of the last second for shot strips, and a JPEG
    /// of the newest frame for the browser at about eight per second.
    func addFrame(_ pixels: CVPixelBuffer, at t: Double) {
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = 640 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let frame = context.createCGImage(small, from: small.extent) else { return }
        let wantsJPEG = lock.withLock { t - lastJPEGTime >= 0.12 }
        let jpeg = wantsJPEG ? Self.encode(frame) : nil
        lock.withLock {
            frames.append((t, frame))
            frames.removeAll { t - $0.t > 1.0 }
            if let jpeg { latestJPEG = jpeg; lastJPEGTime = t }
        }
    }

    func setState(_ newState: [String: Any]) {
        lock.withLock { state = newState }
    }

    /// Six frames from 0.25 s before to 0.25 s after contact, the contact
    /// frame marked where the ball touched. `frameSize` is the camera buffer size.
    func addShot(_ impact: WallImpactDetector.Impact, frameSize: CGSize) {
        let window = lock.withLock { frames.filter { abs($0.t - impact.t) <= 0.25 } }
        guard !window.isEmpty else { return }
        let picks = (0..<min(6, window.count)).map { window[$0 * (window.count - 1) / max(1, min(6, window.count) - 1)] }
        let tileW = 426, tileH = 240
        guard let ctx = CGContext(data: nil, width: tileW * 3, height: tileH * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tileW * 3, height: tileH * 2))
        let contactIndex = picks.indices.min { abs(picks[$0].t - impact.t) < abs(picks[$1].t - impact.t) } ?? 0
        for (i, pick) in picks.enumerated() {
            // Core Graphics has a bottom-left origin: the first tile goes top-left.
            let tile = CGRect(x: (i % 3) * tileW, y: (1 - i / 3) * tileH, width: tileW, height: tileH)
            ctx.draw(pick.image, in: tile)
            if i == contactIndex {
                let x = tile.minX + impact.x / frameSize.width * CGFloat(tileW)
                let y = tile.maxY - impact.y / frameSize.height * CGFloat(tileH)
                let r = max(10, impact.d / frameSize.width * CGFloat(tileW) / 2 + 4)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.25, alpha: 1))
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            Self.label(ctx, String(format: "%+.2f s%@", pick.t - impact.t, i == contactIndex ? "  contact" : ""),
                       at: CGPoint(x: tile.minX + 8, y: tile.maxY - 22))
        }
        guard let strip = ctx.makeImage(), let jpeg = Self.encode(strip) else { return }
        lock.withLock {
            shots.append(Shot(id: (shots.last?.id ?? 0) + 1, t: impact.t, box: impact.box, u: impact.u, v: impact.v, jpeg: jpeg))
            if shots.count > 60 { shots.removeFirst(shots.count - 60) }
        }
    }

    // MARK: Helpers

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func label(_ ctx: CGContext, _ text: String, at point: CGPoint) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 16, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fill(CGRect(x: point.x - 4, y: point.y - 5, width: width + 8, height: 22))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// The browser page: live camera with the board outline and ball, and shots as they happen.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Wall targets live</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    body{margin:0;background:#0b0d10;color:#e8eef5;font:14px -apple-system,system-ui,sans-serif;display:flex;gap:16px;padding:16px;box-sizing:border-box}
    #live{position:relative;flex:1;min-width:0} #live img,#live canvas{width:100%;display:block;border-radius:10px}
    #live canvas{position:absolute;top:0;left:0} #stat{margin-top:8px;color:#9aa7b4}
    #side{width:380px;flex:none;max-height:calc(100vh - 32px);overflow:auto} h3{margin:0 0 10px}
    .shot{margin-bottom:12px;background:#151a20;border-radius:10px;padding:8px} .shot img{width:100%;border-radius:6px;margin-top:6px}
    .hit{color:#22d36a;font-weight:700} .miss{color:#ff9a2e;font-weight:700}
    @media (max-width:800px){body{flex-direction:column}#side{width:auto;max-height:none}}
    </style></head><body>
    <div id="live"><img id="frame" alt="Live camera"><canvas id="over"></canvas><div id="stat">Connecting…</div></div>
    <div id="side"><h3>Shots</h3><div id="shots"></div></div>
    <script>
    const img=document.getElementById('frame'),cv=document.getElementById('over'),ctx=cv.getContext('2d');let state={};
    function tick(){const n=new Image();n.onload=()=>{img.src=n.src;draw();setTimeout(tick,120)};n.onerror=()=>setTimeout(tick,600);n.src='/frame.jpg?'+Date.now()}
    async function poll(){try{state=await(await fetch('/state.json')).json()}catch(e){}setTimeout(poll,200)}
    function draw(){cv.width=img.clientWidth;cv.height=img.clientHeight;const W=cv.width,H=cv.height;ctx.clearRect(0,0,W,H);
    const c=state.corners||[];if(c.length==4){ctx.strokeStyle='#4dd9ff';ctx.lineWidth=2;ctx.beginPath();c.forEach((p,i)=>{const x=p[0]*W,y=p[1]*H;i?ctx.lineTo(x,y):ctx.moveTo(x,y)});ctx.closePath();ctx.stroke()}
    const b=state.ball;if(b){ctx.strokeStyle=b.atWall?'#22d36a':'#ffd21a';ctx.lineWidth=3;ctx.beginPath();ctx.arc(b.x*W,b.y*H,b.w*W/2,0,7);ctx.stroke()}
    document.getElementById('stat').textContent=(state.status||'')+' · detect '+Math.round(state.fps||0)+' fps · '+(state.detectMS||0).toFixed(0)+' ms'+(state.cornersNotSet?' · corners not set':'')}
    let seen=0;async function shots(){try{const list=await(await fetch('/shots.json')).json();const box=document.getElementById('shots');
    for(const s of list.filter(s=>s.id>seen)){const d=document.createElement('div');d.className='shot';
    d.innerHTML='<div>Shot '+s.id+' · '+s.t.toFixed(1)+' s · <span class="'+(s.box?'hit':'miss')+'">'+(s.box?'BOX '+s.box:'outside the grid')+'</span></div><img src="'+s.image+'">';
    box.prepend(d);seen=s.id}}catch(e){}setTimeout(shots,1000)}
    tick();poll();shots();
    </script></body></html>
    """
}

/// The phone's Wi-Fi IPv4 address, for the "open on your Mac" link.
nonisolated func wallTargetsWiFiAddress() -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let start = first else { return nil }
    defer { freeifaddrs(first) }
    for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        guard String(cString: interface.ifa_name) == "en0", let address = interface.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}
#endif
