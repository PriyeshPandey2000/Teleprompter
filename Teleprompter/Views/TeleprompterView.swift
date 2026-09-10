import SwiftUI
import TeleprompterCore

struct TeleprompterView: View {
    let formattedScript: FormattedScript
    @Environment(AppState.self) private var appState
    @State private var scrollState = ContinuousScrollState()
    @State private var blockFrames: [Int: CGRect] = [:]
    @State private var isAnimating = false

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

    /// Continuous word-pixel panning: the viewport doesn't jump block to
    /// block, it chases the current confirmed position every frame at the
    /// reader's measured pace (`ScrollTiming.continuousRate`). This is what
    /// keeps the page visibly moving between ASR partials instead of
    /// freezing and then jumping — the freeze-then-glide cadence that reads
    /// as "laggy" even though the asr → UI pipeline itself is far under
    /// budget (see `PerformanceView`).
    ///
    /// Only `scrollState.offset` (a display-only pixel value) is driven by
    /// this extrapolation. `appState.trackingPosition` — the word-highlight,
    /// recovery, and telemetry truth — is never written here; the target
    /// this view chases is always the *last confirmed* position, and it
    /// never chases past it. During a real pause, reading velocity decays to
    /// zero (`ReadingVelocityEstimator`) and the target simply stops
    /// changing, so the offset arrives and holds — PRD's "UNCERTAIN never
    /// moves the script" falls out of this structurally, not as a special
    /// case bolted on here.
    private var scriptContent: some View {
        GeometryReader { viewport in
            TimelineView(.animation(paused: !isAnimating)) { context in
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(Array(formattedScript.blocks.enumerated()), id: \.element.id) { index, block in
                        blockView(block, at: index)
                    }
                }
                .padding(.horizontal, 120)
                .padding(.vertical, 80)
                .coordinateSpace(name: "scriptContent")
                .offset(y: -scrollState.offset)
                .onChange(of: context.date) { _, date in
                    tick(now: date, viewportHeight: viewport.size.height)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            .clipped()
            .onPreferenceChange(BlockFramePreferenceKey.self) { frames in
                blockFrames = frames
            }
        }
        .onChange(of: appState.trackingPosition) { _, _ in
            isAnimating = true
        }
        .onAppear {
            isAnimating = true
        }
    }

    /// Advances `scrollState` one frame toward the current confirmed
    /// position, then decides whether another frame is needed. Idles (stops
    /// scheduling `.animation` ticks) once settled and not recording, so an
    /// open-but-inactive teleprompter window — the editor, a paused session,
    /// Settings open — doesn't pay for a perpetual 60fps redraw.
    private func tick(now: Date, viewportHeight: CGFloat) {
        guard let target = targetOffset(viewportHeight: viewportHeight) else { return }
        scrollState.tick(
            now: now,
            target: target,
            velocity: appState.trackingPosition.velocity,
            pointsPerToken: pointsPerToken(for: appState.trackingPosition.blockIndex)
        )
        isAnimating = scrollState.offset != target || appState.isRecording
    }

    /// Pixel offset that puts the current confirmed word at the reading
    /// line (viewport center, matching the previous `.center` block anchor).
    /// Interpolates within the current block by word fraction — block frames
    /// come from `blockFrames` (measured via `BlockFramePreferenceKey`);
    /// `nil` only while the target block's frame hasn't been measured yet
    /// (first frame or two after a script loads), in which case the offset
    /// holds until it resolves.
    private func targetOffset(viewportHeight: CGFloat) -> CGFloat? {
        let block = appState.trackingPosition.blockIndex
        guard let frame = blockFrames[block] else { return nil }
        let tokenCount = tokenCount(inBlock: block)
        guard tokenCount > 0 else { return frame.minY - viewportHeight * 0.5 }
        let fraction = min(1.0, Double(appState.trackingPosition.wordIndex) / Double(tokenCount))
        let y = frame.minY + CGFloat(fraction) * frame.height
        return y - viewportHeight * 0.5
    }

    /// Current block's pixel density — points per matcher token — recomputed
    /// every tick so it tracks font-size changes and per-block line-wrap
    /// differences automatically instead of needing its own invalidation.
    private func pointsPerToken(for block: Int) -> CGFloat {
        guard let frame = blockFrames[block] else { return 0 }
        let tokenCount = tokenCount(inBlock: block)
        guard tokenCount > 0 else { return 0 }
        return frame.height / CGFloat(tokenCount)
    }

    private func tokenCount(inBlock block: Int) -> Int {
        let blockStart = formattedScript.tokens.blockStart
        guard block >= 0, block + 1 < blockStart.count else { return 0 }
        return max(0, blockStart[block + 1] - blockStart[block])
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BlockFramePreferenceKey.self,
                    value: [index: proxy.frame(in: .named("scriptContent"))]
                )
            }
        }
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
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "=", "+":
                fontSize = min(72, fontSize + 2)
                return true
            case "-", "_":
                fontSize = max(20, fontSize - 2)
                return true
            case "0":
                fontSize = AppState.autoFontSize()
                return true
            default:
                break
            }
        }

        let largeStep = 5
        let isLarge = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126: // Up arrow
            Task { await appState.adjustPosition(delta: isLarge ? -largeStep : -1) }
            return true
        case 125: // Down arrow
            Task { await appState.adjustPosition(delta: isLarge ? largeStep : 1) }
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

// MARK: - Block Frame Measurement

/// Reports each script block's on-screen frame (in the `"scriptContent"`
/// named coordinate space) so `TeleprompterView` can compute a continuous
/// scroll target without a block-id-based `ScrollViewReader`. Merged rather
/// than overwritten so partial updates from individual blocks accumulate.
private struct BlockFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Continuous Scroll State

/// Drives the teleprompter's pixel scroll offset one frame at a time, always
/// chasing the last confirmed position rather than snapping to it. Reference
/// type so `TeleprompterView`'s `TimelineView` tick can mutate `offset`
/// every frame without re-evaluating the view's other `@State`.
///
/// This only ever produces a *display* value — it never feeds back into
/// `AppState.trackingPosition` or any tracking/recovery/telemetry logic. See
/// `TeleprompterView.scriptContent`'s doc comment for why that boundary is
/// what keeps this safe from the dead-reckoning risk a naive "extrapolate
/// the reader's position" approach would carry.
@Observable
final class ContinuousScrollState {
    private(set) var offset: CGFloat = 0
    private var lastTick: Date?

    /// Advances `offset` toward `target` by one frame's worth of motion at
    /// `velocity` (tokens/sec), converted to points/sec via `pointsPerToken`.
    func tick(now: Date, target: CGFloat, velocity: Double, pointsPerToken: CGFloat) {
        defer { lastTick = now }
        guard let last = lastTick else {
            offset = target
            return
        }
        let dt = now.timeIntervalSince(last)
        // A stale or backgrounded tick (window unfocused, app suspended)
        // would otherwise produce a huge `dt` and a single-frame teleport —
        // skip it and let the next real tick resume from where it left off.
        guard dt > 0, dt < 0.5 else { return }

        let distance = Double(target - offset)
        guard distance != 0 else { return }

        let rate = ScrollTiming.continuousRate(distance: distance, velocity: velocity, pointsPerToken: Double(pointsPerToken))
        let step = CGFloat(rate * dt)
        offset = abs(CGFloat(distance)) <= step ? target : offset + (distance > 0 ? step : -step)
    }
}