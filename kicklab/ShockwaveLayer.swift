//
//  ShockwaveLayer.swift
//  kicklab
//
//  Touch shockwaves, drawn by a Metal fragment shader.
//
//  A stroked circle cannot have a soft wavefront that fades with both distance
//  and age, so these are drawn procedurally instead: the shader is handed the
//  centre and how far through its life the wave is, and computes the rest per
//  pixel.
//

import SwiftUI

/// One expanding wave, with the time since it fired.
struct Shockwave: Identifiable {
    let id: Int
    let position: CGPoint
    let born: Date
}

struct ShockwaveLayer: View {
    let waves: [Shockwave]
    /// How long a wave lives. Long enough to read, short enough not to stack up
    /// during fast juggling.
    var life: Double = 0.8

    private let tint = Color(red: 1.0, green: 0.26, blue: 0.26)

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            GeometryReader { geo in
                ZStack {
                    ForEach(waves) { wave in
                        let age = now.timeIntervalSince(wave.born)
                        if age <= life {
                            let progress = max(0.0001, min(1, age / life))
                            Rectangle()
                                .fill(.clear)
                                .colorEffect(
                                    ShaderLibrary.touchShockwave(
                                        .float2(wave.position.x * geo.size.width,
                                                wave.position.y * geo.size.height),
                                        .float(Float(progress)),
                                        .float(Float(min(geo.size.width,
                                                         geo.size.height) * 0.55)),
                                        .color(tint)
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }
}
