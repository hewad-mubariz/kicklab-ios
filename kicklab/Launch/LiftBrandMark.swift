import SwiftUI

/// Vector rendering of the approved Lift mark and small Panel football.
/// A transparent native drawing avoids bitmap matte edges over the halo.
struct LiftBrandMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 640, size.height / 582)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -176, y: -236)

            let charcoal = Color(red: 0.06, green: 0.075, blue: 0.075)
            let bootColor = scheme == .dark ? Color.white : charcoal
            context.fill(boot, with: .color(bootColor))
            context.fill(sole, with: .color(bootColor))

            let ball = Path(ellipseIn: CGRect(x: 565, y: 236, width: 250, height: 250))
            context.fill(ball, with: .linearGradient(
                Gradient(colors: [.white, Color(red: 0.90, green: 0.92, blue: 0.88)]),
                startPoint: CGPoint(x: 628, y: 256), endPoint: CGPoint(x: 786, y: 485)
            ))
            context.clip(to: ball)
            context.fill(upperSeam, with: .color(charcoal))
            context.fill(lowerSeam, with: .color(charcoal))
            context.fill(limeSeam, with: .color(Color(red: 0.80, green: 0.98, blue: 0.345)))
        }
        .accessibilityHidden(true)
    }

    private var boot: Path {
        Path { p in
            p.move(to: CGPoint(x: 180, y: 584))
            p.addCurve(to: CGPoint(x: 253, y: 418), control1: CGPoint(x: 177, y: 559), control2: CGPoint(x: 230, y: 444))
            p.addCurve(to: CGPoint(x: 271, y: 407), control1: CGPoint(x: 261, y: 407), control2: CGPoint(x: 268, y: 402))
            p.addCurve(to: CGPoint(x: 346, y: 493), control1: CGPoint(x: 292, y: 450), control2: CGPoint(x: 305, y: 479))
            p.addCurve(to: CGPoint(x: 516, y: 505), control1: CGPoint(x: 387, y: 528), control2: CGPoint(x: 460, y: 516))
            p.addCurve(to: CGPoint(x: 543, y: 521), control1: CGPoint(x: 527, y: 501), control2: CGPoint(x: 533, y: 507))
            p.addCurve(to: CGPoint(x: 729, y: 709), control1: CGPoint(x: 607, y: 600), control2: CGPoint(x: 654, y: 658))
            p.addCurve(to: CGPoint(x: 770, y: 766), control1: CGPoint(x: 752, y: 725), control2: CGPoint(x: 768, y: 746))
            p.addCurve(to: CGPoint(x: 528, y: 723), control1: CGPoint(x: 711, y: 763), control2: CGPoint(x: 625, y: 746))
            p.addLine(to: CGPoint(x: 220, y: 630))
            p.addCurve(to: CGPoint(x: 180, y: 584), control1: CGPoint(x: 188, y: 621), control2: CGPoint(x: 178, y: 609))
            p.closeSubpath()
        }
    }

    private var sole: Path {
        Path { p in
            p.move(to: CGPoint(x: 528, y: 752))
            p.addCurve(to: CGPoint(x: 765, y: 791), control1: CGPoint(x: 616, y: 777), control2: CGPoint(x: 705, y: 790))
            p.addCurve(to: CGPoint(x: 739, y: 815), control1: CGPoint(x: 759, y: 809), control2: CGPoint(x: 752, y: 817))
            p.addLine(to: CGPoint(x: 605, y: 816))
            p.addCurve(to: CGPoint(x: 562, y: 791), control1: CGPoint(x: 585, y: 816), control2: CGPoint(x: 575, y: 807))
            p.addLine(to: CGPoint(x: 528, y: 752))
            p.closeSubpath()
        }
    }

    private var upperSeam: Path {
        Path { p in
            p.move(to: CGPoint(x: 695, y: 236))
            p.addCurve(to: CGPoint(x: 641, y: 350), control1: CGPoint(x: 666, y: 257), control2: CGPoint(x: 674, y: 312))
            p.addCurve(to: CGPoint(x: 559, y: 386), control1: CGPoint(x: 620, y: 372), control2: CGPoint(x: 588, y: 384))
            p.addLine(to: CGPoint(x: 561, y: 415))
            p.addCurve(to: CGPoint(x: 673, y: 338), control1: CGPoint(x: 625, y: 405), control2: CGPoint(x: 666, y: 380))
            p.addCurve(to: CGPoint(x: 695, y: 236), control1: CGPoint(x: 680, y: 302), control2: CGPoint(x: 682, y: 261))
            p.closeSubpath()
        }
    }

    private var lowerSeam: Path {
        Path { p in
            p.move(to: CGPoint(x: 599, y: 459))
            p.addCurve(to: CGPoint(x: 727, y: 388), control1: CGPoint(x: 645, y: 415), control2: CGPoint(x: 685, y: 387))
            p.addCurve(to: CGPoint(x: 803, y: 447), control1: CGPoint(x: 764, y: 389), control2: CGPoint(x: 790, y: 419))
            p.addLine(to: CGPoint(x: 792, y: 465))
            p.addCurve(to: CGPoint(x: 725, y: 403), control1: CGPoint(x: 770, y: 423), control2: CGPoint(x: 747, y: 407))
            p.addCurve(to: CGPoint(x: 610, y: 470), control1: CGPoint(x: 683, y: 398), control2: CGPoint(x: 645, y: 442))
            p.closeSubpath()
        }
    }

    private var limeSeam: Path {
        Path { p in
            p.move(to: CGPoint(x: 702, y: 234))
            p.addCurve(to: CGPoint(x: 702, y: 349), control1: CGPoint(x: 665, y: 276), control2: CGPoint(x: 666, y: 329))
            p.addCurve(to: CGPoint(x: 795, y: 428), control1: CGPoint(x: 742, y: 372), control2: CGPoint(x: 785, y: 389))
            p.addLine(to: CGPoint(x: 792, y: 400))
            p.addCurve(to: CGPoint(x: 718, y: 320), control1: CGPoint(x: 777, y: 371), control2: CGPoint(x: 736, y: 345))
            p.addCurve(to: CGPoint(x: 708, y: 234), control1: CGPoint(x: 690, y: 293), control2: CGPoint(x: 680, y: 270))
            p.closeSubpath()
        }
    }
}
