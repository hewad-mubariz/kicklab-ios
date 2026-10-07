#if DEBUG
import SwiftUI

/// Visual test of the shipping HUD. The count here is scripted, not detector output.
struct CounterDesignReview: View {
    @State private var touches = 24
    private var age: Float? { SessionDesignReview.argument("--counter-age").flatMap(Float.init) }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let path = SessionDesignReview.argument("--counter-image"), let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else { LinearGradient(colors: [Color(red: 0.02, green: 0.15, blue: 0.19), .black], startPoint: .top, endPoint: .bottom) }
                LinearGradient(colors: [.black.opacity(0.2), .clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                VStack {
                    HStack {
                        Image(systemName: "xmark").font(.system(size: 20)).frame(width: 42, height: 42)
                            .background(.black.opacity(0.5), in: Circle()).overlay(Circle().stroke(.white.opacity(0.7)))
                        Spacer()
                        HStack(spacing: 7) {
                            Circle().fill(.red).frame(width: 9, height: 9)
                            Text("REC").foregroundStyle(.red).bold()
                            Text("00:42").monospacedDigit()
                        }.font(.system(size: 13)).padding(12).background(.black.opacity(0.55), in: Capsule())
                    }.padding(.horizontal, 22)
                    VStack(spacing: 2) {
                        LiveTouchCounter(value: touches, reviewAge: age)
                        Text("Touches in a row").font(.system(size: 15, weight: .medium))
                        LiveMilestonePill(next: 50).padding(.top, 8)
                    }.padding(.top, -12)
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            LiveStatCard(symbol: "shoe", value: "24", label: "Touches")
                            LiveStatCard(symbol: "arrow.up.and.down", value: "0.8 m", label: "Height")
                            LiveStatCard(symbol: "bolt.fill", value: "12", label: "Combo")
                        }
                    }.padding(.trailing, 20)
                    Spacer()
                    Image(systemName: "stop.fill").font(.system(size: 30)).frame(width: 76, height: 76)
                        .background(.red.opacity(0.82), in: Circle()).overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .red.opacity(0.65), radius: 16)
                    Text("Stop Recording").font(.system(size: 15, weight: .medium)).padding(.top, 5)
                    Text("Counter graphic review · scripted touches").font(.system(size: 10)).opacity(0.65).padding(.top, 16)
                }.padding(.top, 70).padding(.bottom, 35)
            }.foregroundStyle(.white).ignoresSafeArea()
        }
        .task {
            guard age == nil else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
                touches = touches == 29 ? 24 : touches + 1
            }
        }
    }
}
#endif
