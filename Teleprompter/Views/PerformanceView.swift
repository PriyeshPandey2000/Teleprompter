import SwiftUI
import TeleprompterCore

/// Live PRD Gate 1 readout: the app's own ASR → matcher → position → UI
/// round trip, refreshed every 0.5s while the settings window is open. Speech
/// recognition itself is excluded — its partial cadence is Apple's — so this
/// isolates the part of the latency budget our code actually owns.
struct PerformanceView: View {
    @Environment(AppState.self) private var appState
    @State private var summary: LatencySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            gateBanner
            statsTable
            Text("Measures the app's own asr → UI pipeline every 0.5s while this window is open. ASR partial cadence is how often the Speech framework delivers new transcript text — it paces how often the highlight can step, and it's owned by Apple, not the app. Gate 1 target: ≤ 200 ms perceived response.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                summary = await appState.latencySummary()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @ViewBuilder
    private var gateBanner: some View {
        let p95 = summary?.total?.p95
        let cadenceP95 = summary?.asrCadence?.p95
        HStack(spacing: 8) {
            Image(systemName: iconName(p95, cadenceP95))
                .foregroundStyle(tint(p95, cadenceP95))
            Text(gateText(p95, cadenceP95))
                .font(.headline)
                .foregroundStyle(tint(p95, cadenceP95))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint(p95, cadenceP95).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tint(_ p95: TimeInterval?, _ cadenceP95: TimeInterval?) -> Color {
        guard let p95 else { return .secondary }
        if p95 > 0.2 { return .orange }
        if let cadenceP95, cadenceP95 > 0.3 { return .yellow }
        return .green
    }

    private func iconName(_ p95: TimeInterval?, _ cadenceP95: TimeInterval?) -> String {
        guard let p95 else { return "waveform.slash" }
        if p95 > 0.2 { return "exclamationmark.triangle" }
        if let cadenceP95, cadenceP95 > 0.3 { return "hourglass" }
        return "checkmark.seal"
    }

    private func gateText(_ p95: TimeInterval?, _ cadenceP95: TimeInterval?) -> String {
        guard let p95 else { return "Gate 1: waiting for tracking data" }
        if p95 > 0.2 { return "Gate 1 EXCEEDED — total p95 \(ms(p95)) exceeds 200 ms" }
        if let cadenceP95, cadenceP95 > 0.3 {
            return "Pipeline insta — but ASR cadence \(ms(cadenceP95)) paces the highlight"
        }
        return "Gate 1 PASS — total p95 \(ms(p95)) (target ≤ 200 ms)"
    }

    private var statsTable: some View {
        VStack(spacing: 0) {
            if let summary, summary.completedCycles > 0 {
                headerRow
                Divider()
                row("Total (asr → UI)", summary.total, emphasized: true)
                Divider()
                row("ASR partial cadence", summary.asrCadence, emphasized: cadenceVisible(summary))
                Divider()
                row("ASR → Matcher", summary.asrToMatcher)
                Divider()
                row("Matcher", summary.matcherDuration)
                Divider()
                row("Matcher → Position", summary.matcherToEmit)
                Divider()
                row("Position → UI", summary.emitToUI)
            } else {
                Text("No completed cycles yet. Record a take and speak the script to populate live latency.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Segment")
            Spacer()
            Text("Cycles")
                .frame(width: 60, alignment: .trailing)
            Text("Mean")
                .frame(width: 80, alignment: .trailing)
            Text("p95")
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func row(
        _ name: String,
        _ stats: DistributionStats?,
        emphasized: Bool = false
    ) -> some View {
        HStack {
            Text(name)
                .fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            Text(stats.map { "\($0.count)" } ?? "—")
                .frame(width: 60, alignment: .trailing)
            Text(ms(stats?.mean))
                .frame(width: 80, alignment: .trailing)
            Text(ms(stats?.p95))
                .fontWeight(emphasized ? .semibold : .regular)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.body)
        .monospacedDigit()
        .padding(.vertical, 6)
    }

    private func ms(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        return String(format: "%.1f ms", interval * 1000)
    }

    /// True when the cadence (not the pipeline) is what paces the highlight.
    private func cadenceVisible(_ summary: LatencySummary) -> Bool {
        guard let cadence = summary.asrCadence?.p95 else { return false }
        return cadence > 0.3
    }
}