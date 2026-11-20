#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

struct PenaltyResultOverlay: View {
    let result: ShotOutcome
    let replay: Bool
    var compact=false
    @State private var arrived=false
    private var title: String {
        if replay { return "REPLAY" }
        switch result {
        case .goal: return "GOAL"
        case .caught,.parried: return "SAVED"
        case .blocked: return "BLOCKED"
        case .over: return "OVER"
        case .wide: return "WIDE"
        case .woodwork: return "OFF THE FRAME"
        case .pending: return ""
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let yellow=Color(red:1,green:0.84,blue:0.13)
            VStack(spacing:4) {
                Text(title)
                    .font(.system(size:geometry.size.height*(replay || compact ? 0.048:0.10),weight:.black,design:.rounded).italic())
                    .tracking(replay ? 5:8)
                    .foregroundStyle(replay ? .white:result == .goal ? yellow:.white)
                    .shadow(color:.black.opacity(0.9),radius:3,y:3)
                    .shadow(color:result == .goal && !replay ? yellow.opacity(0.9):.clear,radius:14)
                    .shadow(color:result == .goal && !replay ? .orange.opacity(0.6):.clear,radius:32)
                    .scaleEffect(arrived ? 1:0.82)
                if replay {
                    Text("0.25×  •  NEXT SHOT WHEN YOU’RE READY")
                        .font(.system(size:geometry.size.height*0.018,weight:.bold,design:.monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color:.black,radius:3)
                }
            }
            .frame(maxWidth:.infinity)
            .padding(.top,geometry.size.height*0.035)
            .animation(.easeInOut(duration:0.25),value:compact)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.spring(response:0.28,dampingFraction:0.65)) { arrived=true } }
    }
}
#endif
