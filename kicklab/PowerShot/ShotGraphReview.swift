#if DEBUG
import SwiftUI

/// Debug review: one graph style on a real shot at four moments. Launch with
/// --session-design shot-graphs --shot-graph <style> --shot-track-cache <plist> [--shot-style <trail>]
struct ShotGraphReview: View {
    let style: ShotGraphStyle
    let trackPath: String?
    let trail: ShotTrailStyle

    var body: some View {
        let flight = trackPath.flatMap { Self.flight(from: $0) } ?? .sample
        // The sample roll runs from 0.5 s to 2.15 s.
        let moments: [(String, Double)] = style == .tape
            ? [("Before the roll", 0.3), ("Rolling", 1.0), ("Slowing", 1.6), ("Finished", 2.5)]
            : [("Before the kick", flight.launch - 0.3),
               ("In flight", flight.launch + flight.airTime * 0.55),
               ("Just landed", flight.end + 0.12),
               ("After", flight.end + 1.6)]
        VStack(alignment: .leading, spacing: 14) {
            Text(style.title.uppercased()).font(.system(size: 13, weight: .heavy)).tracking(1.4)
                .foregroundStyle(TrainingHomeStyle.lime)
            ForEach(moments, id: \.0) { moment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    ShotGraph(style: style, flight: flight, time: moment.1, palette: trail.palette,
                              distance: style == .tape ? .sampleRoll : nil)
                        .frame(height: 112)
                        .background(Color(red: 0.04, green: 0.05, blue: 0.06), in: .rect(cornerRadius: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    static func flight(from path: String) -> ShotFlight? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let stored = try? PropertyListDecoder().decode([StoredFrame].self, from: data) else { return nil }
        return ShotFlight.find(in: BallEffectTrack(frames: stored.map(\.frame)), aspect: 9.0 / 16)
    }
}
#endif
