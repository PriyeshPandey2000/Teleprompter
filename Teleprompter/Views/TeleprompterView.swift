import SwiftUI
import TeleprompterCore

struct TeleprompterView: View {
    let formattedScript: FormattedScript
    @Environment(AppState.self) private var appState
    @State private var scrollProxy: ScrollViewProxy?

    @AppStorage("fontSize") private var fontSize: Double = 36
    @AppStorage("mirrorMode") private var mirrorMode = false
    @AppStorage("flipVertical") private var flipVertical = false
    @AppStorage("countdownDuration") private var countdownDuration = 3

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            scriptContent
        }
        .scaleEffect(x: mirrorMode ? -1 : 1, y: flipVertical ? -1 : 1)
        .overlay(alignment: .leading) {
            trackingIndicator
        }
        .overlay {
            if let remaining = appState.countdownRemaining, remaining > 0 {
                CountdownOverlay(remaining: remaining)
            }
        }
        .overlay(alignment: .topTrailing) {
            if appState.isRecording {
                RecordingBadge()
            }
        }
        .onKeyDown { event in
            handleKeyPress(event)
        }
    }

    // MARK: - Script Content

    private var scriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(Array(formattedScript.blocks.enumerated()), id: \.element.id) { index, block in
                        blockView(block, at: index)
                            .id("block-\(index)")
                    }
                }
                .padding(.horizontal, 120)
                .padding(.vertical, 80)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: appState.trackingPosition.blockIndex) { _, newIndex in
                scrollTo(block: newIndex, using: proxy)
            }
        }
    }

    private func scrollTo(block index: Int, using proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo("block-\(index)", anchor: .center)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ScriptBlock, at index: Int) -> some View {
        let isCurrentBlock = index == appState.trackingPosition.blockIndex

        Group {
            switch block {
            case .heading(_, let text):
                Text(text)
                    .font(.system(size: fontSize + 6, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

            case .paragraph(_, let text):
                Text(text)
                    .font(.system(size: fontSize, weight: .regular, design: .serif))
                    .foregroundStyle(.white.opacity(isCurrentBlock ? 1.0 : 0.6))
                    .lineSpacing(12)

            case .bullet(_, let text):
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .offset(y: 10)
                    Text(text)
                        .font(.system(size: fontSize, weight: .regular, design: .serif))
                        .foregroundStyle(.white.opacity(isCurrentBlock ? 1.0 : 0.6))
                        .lineSpacing(12)
                }

            case .numberedItem(_, let number, let text):
                HStack(alignment: .top, spacing: 12) {
                    Text("\(number).")
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(text)
                        .font(.system(size: fontSize, weight: .regular, design: .serif))
                        .foregroundStyle(.white.opacity(isCurrentBlock ? 1.0 : 0.6))
                        .lineSpacing(12)
                }
            }
        }
        .onTapGesture {
            Task {
                let position = TrackingPosition(blockIndex: index, wordIndex: 0, confidence: 1.0)
                await appState.jumpTo(position: position)
            }
        }
    }

    // MARK: - Tracking Indicator

    private var trackingIndicator: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(statusColor.opacity(0.8))
                .frame(width: 3)
        }
        .frame(width: 3)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: appState.trackingStatus)
    }

    private var statusColor: Color {
        switch appState.trackingStatus {
        case .tracking: return .green
        case .paused: return .gray
        case .manual: return .blue
        case .uncertain, .recovering: return .yellow
        case .degraded: return .red
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // Up arrow
            Task { await appState.adjustPosition(delta: -1) }
            return true
        case 125: // Down arrow
            Task { await appState.adjustPosition(delta: 1) }
            return true
        case 49: // Space — pause/resume
            Task {
                if appState.isRecording {
                    await appState.stopRecording()
                } else {
                    await appState.beginRecording(withCountdown: countdownDuration)
                }
            }
            return true
        case 15: // R — recenter
            Task { await appState.recenter() }
            return true
        default:
            return false
        }
    }
}

// MARK: - Countdown Overlay

struct CountdownOverlay: View {
    let remaining: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            Text(remaining.description)
                .font(.system(size: 180, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .transition(.opacity)
    }
}

// MARK: - Recording Badge

struct RecordingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("REC")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(16)
    }
}