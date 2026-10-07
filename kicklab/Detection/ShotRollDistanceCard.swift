import SwiftUI

struct ShotRollDistanceCard: View {
    let state: ShotRollDisplay
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack {
                Text("Distance from start").font(.subheadline.weight(.semibold))
                Spacer()
                Text("EXPERIMENTAL").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(state.requiresCalibration ? "Recalibrate" : state.distanceM.map { String(format: "%.2f m", $0) } ?? "Start not set")
                    .font(.system(size: state.requiresCalibration || state.distanceM == nil ? 20 : compact ? 30 : 36,
                                  weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(state.requiresCalibration ? .orange : .primary)
                    .accessibilityIdentifier("roll-distance-value")
                if state.distanceM != nil, !state.isLive, !state.requiresCalibration {
                    Text("last estimate").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Rolling speed").font(.caption.weight(.semibold))
                    Text(state.speedKMH.map { String(format: "%.1f km/h", $0) } ?? "— km/h")
                        .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                        .monospacedDigit().accessibilityIdentifier("roll-speed-value")
                }
            }
            Text(state.speedStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityIdentifier("roll-speed-status")
            if let peak = state.peakRollingSpeedKMH, !state.requiresCalibration {
                Text(String(format: "Peak rolling speed: %.1f km/h", peak))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("roll-speed-peak")
            }
            Text(state.status).font(.caption)
                .foregroundStyle(state.requiresCalibration || state.outsideMappedFloor ? .orange : .secondary)
                .accessibilityIdentifier("roll-distance-status")
            Text(state.requiresCalibration ? "Distance paused • calibration required" : state.calibrated
                 ? "Measured-spacing calibration • rolling ball only • checks pending"
                 : "Estimated metres • rolling ball only • scale unverified")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(compact ? 8 : 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
