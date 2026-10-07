import SwiftUI

struct TouchesChartView: View {
    let series: [Double]
    var peakLabel: String
    var duration: Double = 0

    private var ceiling: Double { max(30, ceil((series.max() ?? 0) / 30) * 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Touches Over Time").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 8) {
                VStack {
                    ForEach((0...3).reversed(), id: \.self) { tick in
                        Text("\(Int(ceiling * Double(tick) / 3))")
                            .font(.system(size: 10)).foregroundStyle(SessionStyle.secondary)
                        if tick > 0 { Spacer(minLength: 0) }
                    }
                }.frame(width: 25, height: 161)
                VStack(spacing: 8) {
                    chart.frame(height: 160)
                    HStack {
                        ForEach(0...4, id: \.self) { tick in
                            Text(duration > 0 ? "\(Int(duration * Double(tick) / 4))s" : "\(tick * 25)%")
                                .font(.system(size: 9)).foregroundStyle(SessionStyle.secondary)
                            if tick < 4 { Spacer(minLength: 0) }
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touches over time. \(peakLabel). Duration \(Int(duration)) seconds.")
    }

    private var chart: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                Canvas { context, size in
                    for row in 0...3 {
                        let y = size.height * CGFloat(row) / 3
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(line, with: .color(.white.opacity(0.11)), lineWidth: 0.6)
                    }
                    for column in 0...6 {
                        let x = size.width * CGFloat(column) / 6
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
                    }
                }
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: last.x, y: geometry.size.height)); path.closeSubpath()
                }
                .fill(LinearGradient(colors: [SessionStyle.mint.opacity(0.24), SessionStyle.mint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(SessionStyle.mint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .shadow(color: SessionStyle.mint.opacity(0.45), radius: 5)
                if let peak = points.min(by: { $0.y < $1.y }) {
                    Circle().fill(SessionStyle.mint).frame(width: 6, height: 6).position(peak)
                    Text(peakLabel + " touches")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(SessionStyle.panel, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SessionStyle.mint.opacity(0.65), lineWidth: 0.6))
                        .position(x: min(max(peak.x, 54), max(54, geometry.size.width - 54)), y: max(-12, peak.y - 23))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard series.count > 1 else { return [] }
        return series.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(series.count - 1),
                    y: size.height * (1 - CGFloat(max(0, value) / ceiling)))
        }
    }
}

struct ConsistencyRingView: View {
    let percent: Int
    let blurb: String
    @State private var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(SessionStyle.mint.opacity(0.13), lineWidth: 7)
                Circle().trim(from: 0, to: animated ? CGFloat(min(100, max(0, percent))) / 100 : 0)
                    .stroke(SessionStyle.mint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: SessionStyle.mint.opacity(0.4), radius: 8)
                Text("\(percent)%").font(.system(size: 25, weight: .bold)).monospacedDigit()
            }
            .frame(width: 82, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text("Consistency").font(.system(size: 14, weight: .semibold))
                if let split = blurb.firstIndex(of: "!") {
                    Text(String(blurb[...split])).font(.system(size: 12, weight: .semibold)).foregroundStyle(SessionStyle.mint)
                    Text(String(blurb[blurb.index(after: split)...]).trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                } else {
                    Text(blurb).font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        .modifier(SessionPanel(tint: SessionStyle.mint.opacity(0.3)))
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { animated = true }
        }
        .accessibilityElement(children: .combine)
    }
}
