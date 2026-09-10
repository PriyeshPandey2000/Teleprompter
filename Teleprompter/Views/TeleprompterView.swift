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
        .overlay(alignment: .bottom) {
            if appState.trackingStatus.isRecovering {
                TrackingStatusBanner(
                    label: "Resyncing…",
                    color: .yellow
                )
            } else if appState.trackingStatus.isManualFallback {
                TrackingStatusBanner(
                    label: "Tracking paused — tap where you are in the script",
                    color: .red
                )
            } else if appState.trackingStatus.isDegraded {
                TrackingStatusBanner(
                    label: "Tracking lost — tap to re-sync",
                    color: .red
                ) {
                    Task {
                        await appState.jumpTo(position: appState.trackingPosition)
                    }
                }
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

    /// Opacity for text that's behind the reader's current position — dimmed
    /// but still legible, never fully hidden.
    private let dimOpacity: Double = 0.6

    @ViewBuilder
    private func blockView(_ block: ScriptBlock, at index: Int) -> some View {
        let isCurrentBlock = index == appState.trackingPosition.blockIndex
        // Only the block being actively read gets word-level tracking; the
        // matcher's wordIndex is meaningless for any other block.
        let spokenThrough = isCurrentBlock ? appState.trackingPosition.wordIndex : nil

        Group {
            switch block {
            case .heading(_, let text):
                wordFlow(text, spokenThrough: spokenThrough, fontSize: fontSize + 6, weight: .bold, design: .rounded)

            case .paragraph(_, let text):
                wordFlow(text, spokenThrough: spokenThrough, fontSize: fontSize)
                    .opacity(isCurrentBlock ? 1.0 : dimOpacity)
                    .lineSpacing(12)

            case .bullet(_, let text):
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .offset(y: 10)
                    wordFlow(text, spokenThrough: spokenThrough, fontSize: fontSize)
                        .opacity(isCurrentBlock ? 1.0 : dimOpacity)
                        .lineSpacing(12)
                }

            case .numberedItem(_, let number, let text):
                HStack(alignment: .top, spacing: 12) {
                    Text("\(number).")
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    // `text` excludes the "N." prefix, but the matcher
                    // tokenized `plainText` (prefix included), so wordIndex
                    // needs the prefix's own token count subtracted back out
                    // before it lines up with `text`'s word positions.
                    wordFlow(text, spokenThrough: numberedItemSpokenThrough(spokenThrough, number: number), fontSize: fontSize)
                        .opacity(isCurrentBlock ? 1.0 : dimOpacity)
                        .lineSpacing(12)
                }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: appState.trackingPosition)
        .onTapGesture {
            Task {
                let position = TrackingPosition(blockIndex: index, wordIndex: 0, confidence: 1.0)
                await appState.jumpTo(position: position)
            }
        }
    }

    private func numberedItemSpokenThrough(_ spokenThrough: Int?, number: Int) -> Int? {
        guard let spokenThrough else { return nil }
        let prefixTokenCount = ScriptTokens.rawWords(in: "\(number).").count
        return spokenThrough - prefixTokenCount
    }

    /// Renders `text` as one naturally-wrapping `Text`, one styled run per
    /// word. A growing highlight starts at the first word and stays at full
    /// opacity through every word up to and including `spokenThrough` (the
    /// matcher's word index within this block — the most recently confirmed
    /// word); words beyond that, not yet spoken, dim. `spokenThrough == nil`
    /// means this block isn't the one being read — every word renders at
    /// full opacity here, and the caller dims the whole block uniformly
    /// instead (so the dim isn't applied twice).
    ///
    /// Word boundaries come from `ScriptTokens.rawWords`, the same rule the
    /// matcher tokenizes on, so a word here is only ever marked spoken once
    /// the matcher has actually confirmed it — never based on the block
    /// flipping "current" as a whole.
    private func wordFlow(
        _ text: String,
        spokenThrough: Int?,
        fontSize: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .serif
    ) -> Text {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return Text(text) }

        var result: Text?
        var consumedTokens = 0

        for word in words {
            consumedTokens += ScriptTokens.rawWords(in: String(word)).count
            let opacity: Double
            if let spokenThrough {
                opacity = consumedTokens <= spokenThrough + 1 ? 1.0 : dimOpacity
            } else {
                opacity = 1.0
            }

            let segment = Text(word)
                .font(.system(size: fontSize, weight: weight, design: design))
                .foregroundStyle(.white.opacity(opacity))

            result = result.map { $0 + Text(" ") + segment } ?? segment
        }

        return result ?? Text(text)
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
        case .degraded, .manualFallback: return .red
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

// MARK: - Tracking Status Banner

struct TrackingStatusBanner: View {
    let label: String
    let color: Color
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .padding(.bottom, 24)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule())
        .contentShape(Capsule())
    }
}