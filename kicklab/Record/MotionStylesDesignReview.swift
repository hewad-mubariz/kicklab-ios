#if DEBUG
import SwiftUI

/// Screenshot review of the actual vector renderers, using explicitly illustrative data.
struct MotionStylesDesignReview: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Juggle Dude / MOTION STYLES").font(.system(size: 19, weight: .bold))
                        Text("Native renderers · Sample motion").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }.padding(.bottom, 4)
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 14) {
                        ForEach(MotionStyle.allCases) { style in
                            MotionStyleOption(style: style, selected: style == .ballMotion,
                                              width: max(130, (geometry.size.width - 54) / 2))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bounce Run").font(.system(size: 13, weight: .semibold))
                        MotionStyleGraph(style: .bounceRun, snapshot: MotionStyleSample.timeline.snapshot(
                            at: MotionStyleSample.time, duration: MotionStyleSample.duration)).frame(height: 80)
                        HStack {
                            phase("SQUASH", age: 0)
                            Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4))
                            phase("LIFT", age: 0.16)
                            Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4))
                            phase("ROUND", age: 0.4)
                        }
                    }.padding(14).background(.white.opacity(0.04), in: .rect(cornerRadius: 18))
                }.padding(20)
            }
        }.background(Color(red: 0.035, green: 0.05, blue: 0.05)).foregroundStyle(.white)
    }

    private func phase(_ title: String, age: Double) -> some View {
        let scale = MotionStyleSnapshot.Bounce.scale(age: age)
        return VStack(spacing: 10) {
            Circle().fill(Color(red: 0.99, green: 0.98, blue: 0.88)).frame(width: 22, height: 22)
                .scaleEffect(x: scale.width, y: scale.height).frame(height: 30)
            Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }.frame(maxWidth: .infinity)
    }
}
#endif
