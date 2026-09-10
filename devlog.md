# Devlog

Running log of implementation progress and the reasoning behind non-obvious decisions. Newest entry on top.

---

## 2026-09-10 (later) — Start-point selection sticks; recording telemetry is finally live

Two of the "known gaps" flagged earlier, done properly (asked to think from first principles so this doesn't need revisiting).

### 1. Start-point selection

**Root cause, once traced properly:** it wasn't just "`beginRecording` defaults to block 0" — `TrackingEngine`'s callbacks (`onStatusChange`/`onPositionUpdate`) were only ever registered inside `startRecording()`. A pre-recording tap called `trackingEngine.jumpTo(position:)` directly, which updated the engine's *internal* position fine, but with no callbacks wired yet, `AppState.trackingPosition` never got the update — so the tap didn't even move the highlight, let alone carry into the recording.

**Fix, as an invariant rather than a one-off patch:**
- `registerTrackingCallbacksIfNeeded()` — a real idempotency guard (`Bool` flag), not just "happens to be harmless to call twice" — is now called from every `AppState` entry point that can produce an engine callback: `jumpTo`, `adjustPosition`, `recenter`, `startRecording`. Any future method that touches the engine should do the same; that's the one line to remember, not "remember to register callbacks somewhere before this runs."
- `beginRecording`/`startRecording` now default their `position` parameter to `nil`, meaning "wherever `trackingPosition` currently sits" — resolved once, inside `startRecording`. No caller needs to know or care about the anchor; it's just always current.
- **The status indicator needed its own fix**, or a pre-recording tap would flip the green "tracking" dot on before any recording exists (since `jumpTo` unconditionally sets the engine's internal status to `.tracking` — correct for its real job of resuming after a mid-recording correction, wrong to surface visually pre-recording). Fixed at the `onStatusChange` callback itself: `self.trackingStatus = self.isRecording ? status : .paused`. This required flipping the order in `startRecording` — `isRecording = true` now happens *before* `trackingEngine.start(from:)`, not after — otherwise the very first real `.tracking` status from the engine starting would get caught by the same guard and swallowed.
- Net effect: `jumpTo` (the same method, same tap gesture, zero new UI code) now correctly serves both "select a start point before recording" and "correct position mid-recording," because the only thing that differs between those two cases — the app-level `isRecording` flag — is exactly what the status guard checks.

### 2. Recording telemetry

**Was dead code.** `RecordingTelemetry` had a complete, reasonable API (`startSession`/`recordEvent`/`endSession`/`getSummary`) that `AppState` declared but never called even once.

**Bigger problem underneath:** even wiring the obvious lifecycle calls wouldn't have captured anything meaningful, because `TrackingEngine` never exposed individual events — `history` (its internal event log) was a private, capped ring buffer nothing could read, and more importantly **most of the event types `TrackingEvent.EventType` already defines were never actually emitted anywhere**: `.degrade`, `.recover`, `.skip`, and `.backtrack` all existed in the enum (and `RecordingSession` already had `degradeCount`/`correctionCount` computed properties expecting them) but zero code ever constructed one. PRD section 26 explicitly wants degraded events, skipped sections, and backward movements captured — the enum promised it, nothing delivered it.

**Fixed in the engine, not papered over in the app layer:**
- Added `TrackingEngine.onEvent: (@Sendable (TrackingEvent) -> Void)?`, fired for every event alongside the existing `recordEvent` history-append (added to `setCallbacks` as an optional third parameter, default `nil`, so the two existing call sites didn't need updating).
- `handleHighConfidenceMatch` now classifies its own event type instead of hardcoding `.positionUpdate`: a **reanchored** match (the matcher had to globally re-search rather than advance within its lookahead window) is `.skip` if it moved forward, `.backtrack` if it moved backward — reusing `outcome.reanchored`, a signal the matcher already computes, rather than inventing a new distance-threshold heuristic that would need separate tuning.
- `handleNoMatch` now emits `.degrade` on every step that lands on `.degraded` or `.manualFallback` — including the escalation step from one to the other, since both are worsening transitions worth a data point.
- `handleHighConfidenceMatch` emits `.recover` specifically when the status *was* `.degraded`/`.manualFallback` at the moment the ASR result arrived — captured in `processASRResult` *before* the `.recovering` intermediate status overwrites it, otherwise that information is gone by the time the match handler runs. Deliberately does **not** fire `.recover` for routine `.uncertain` blips self-correcting — that's the expected, constant background noise of natural pauses, not a notable event; only actually-degraded recoveries are telemetry-worthy. (Covered by a dedicated test — `routineUncertainRecoveryDoesNotEmitRecover` — specifically to keep this boundary from drifting later.)
- `AppState` wires `onEvent` straight into `telemetry.recordEvent`, and calls `telemetry.startSession`/`endSession` around the actual recording lifecycle. Take numbering is derived from `telemetry.getSessions(for: scriptID).count + 1` — no separate counter to keep in sync, single source of truth.

**Known limitation, noted rather than solved:** `Script.id` is a fresh `UUID` every time `loadScript` runs, so take numbering resets if the user reloads/reformats the same script text. Not fixing script-identity-persistence-across-reloads now — that's a real feature (recognizing "this is the same script as last time") that deserves its own design, not a side effect of a telemetry pass.

**No UI added.** Per the PRD's own layering (V1 telemetry is infrastructure for V3, not a V3 feature yet), nothing surfaces this data — just correct capture.

### Tests

- `TeleprompterCoreTests`: new `Telemetry Events` suite (6 tests) — pause/resume, manual-jump correction, forward reanchor → skip, backward reanchor → backtrack, degrade-then-recover, and the routine-uncertain-doesn't-recover boundary. All passed on first run, which is a good sign the reasoning (especially reusing `outcome.reanchored` instead of a new heuristic) was right rather than lucky.
- `AppStateTests`: `startPointSelectionSticks` (tap before recording → status stays paused, position carries into the actual recording) and `telemetryCapturesSession` (full session lifecycle, take numbering, events non-empty).
- Full suite: 51 core + 9 app tests, all green.

---

## 2026-09-10 — Word-highlight direction was inverted

Previous entry implemented "already-spoken words dim, upcoming stays bright" as the standard prompter convention. User feedback: wrong direction — they want the opposite, a growing bright highlight starting at word 1 and extending through the most recently confirmed word, with not-yet-spoken words dimmed instead. Flipped `wordFlow`'s opacity mapping in `TeleprompterView.swift` accordingly: spoken (`consumedTokens <= spokenThrough + 1`) → full opacity, unspoken → `dimOpacity`.

Also fixed a double-dim bug the naive flip would've introduced: for non-current blocks (`spokenThrough == nil`), `wordFlow` must render every word at full inner opacity regardless of the new direction, since the caller already applies `dimOpacity` once at the container level for the whole block — otherwise non-current blocks would dim twice (0.6 × 0.6). Made that explicit with an `if let spokenThrough` branch instead of the previous `.map { ... } ?? false` one-liner, which implicitly baked the "spoken" default into the wrong path once the mapping flipped.

Build verified, not yet re-confirmed in-app by the user.

---

## 2026-09-09 (evening) — Word-level highlight instead of whole-line flip

### Symptom / feedback

Tracking finally worked end to end, but the highlight only operated at block (paragraph) granularity: the instant any word in the current paragraph matched, the *entire* paragraph snapped from dim to full-bright. Combined with any perceived lag, the user couldn't tell which word to say next — the whole line was already "lit."

### Fix

Word-level progressive highlight, current-block only:
- Already-spoken words in the current block dim to the same `dimOpacity` (0.6) already used for non-current blocks — consistent visual language, one constant, no new magic numbers.
- Unspoken words (including the one currently being said) stay full-bright, so the bright region is always unambiguously "what to read next."
- Wrapped in `.animation(.easeInOut(duration: 0.12), value: appState.trackingPosition)` so both the per-word dim and the coarse block-level dim/undim (which previously snapped instantly, unanimated) now crossfade — directly addresses the "lag felt jarring" complaint, since a late-arriving match now eases into place instead of popping.

### Implementation notes (so this doesn't need revisiting)

- **Single source of truth for word boundaries.** Exposed `ScriptTokens.rawWords(in:)` (extracted from `ScriptTokens.make`'s existing private tokenization rule — same maximal-alphanumeric-run split, zero behavior change, `make` now just calls it). The view's word list and the matcher's word list can never drift apart because they're the same function.
- **Display words vs. matcher tokens aren't 1:1.** A display "word" (whitespace-delimited, e.g. `"don't"` or `"well-known"`) can decompose into *multiple* matcher tokens (`"don"`, `"t"`), since the matcher splits on any non-alphanumeric character, not just whitespace. `wordFlow(_:spokenThrough:...)` walks display words while accumulating the matcher-token count each one contributes (`ScriptTokens.rawWords(in: word).count`), and compares that running total against `spokenThrough` (the engine's per-block `wordIndex`) — so contractions/hyphenates don't throw off the highlight boundary.
- **Numbered items needed an offset.** `ScriptBlock.numberedItem.plainText` (which the matcher actually tokenizes) is `"N. content"` — the leading numeral is itself a matcher token. The view renders the "N." badge separately from the flowing content text, so `numberedItemSpokenThrough` subtracts the prefix's own token count (`ScriptTokens.rawWords(in: "\(number).").count`) before comparing against the content-only word list.
- **Dropped reliance on `ScriptFormatter.rewrapText`'s manual line breaks for the current block's rendering.** `wordFlow` rebuilds the paragraph via `Text` concatenation (`+`), joining words with a plain space — SwiftUI's natural text-flow wrapping takes over based on actual view width, rather than the formatter's fixed ~60-char/8-word pre-wrap (which doesn't know the real rendered width or live font-size changes). Didn't touch `ScriptFormatter` itself — it's untouched, still used for paragraph detection/heading/bullet parsing; its pre-wrap newlines just get treated as ordinary whitespace by `wordFlow`'s split, so they don't force incorrect hard breaks inside the reflowed text.
- **Only the current block pays the per-word cost.** Non-current blocks keep rendering through the same `wordFlow` function (for wrapping consistency) but with `spokenThrough: nil`, which short-circuits every word to "not spoken" — the existing container-level `.opacity(dimOpacity)` handles the uniform dim exactly as before. No behavior change for blocks that aren't being actively read.

### Verified

`swift test` (45/45) and `xcodebuild test` (7/7) both green — no test touched this rendering path, so this is confirmed by build success + manual verification pending from the user, not automated coverage (SwiftUI view output isn't unit-tested in this repo).

---

## 2026-09-09 (later still) — Highlight never moves: ASR failures were invisible

### Symptom

Recording starts fine (no crash), but the white highlight never moves to follow speech, and no degraded/uncertain banner appears either — indicator just stays green and static.

### Root cause

`SFSpeechRecognizerService.handleRecognition` only calls `onResult?(asr)` for the `.transcript` outcome. Every other outcome (`.failed`, `.assetNotReady`, `.noSpeechDetected`, `.cancelled`, `.empty`) just mutates an internal `_state` that nothing observed — no callback existed for it. And critically, `TrackingEngine` only re-evaluates its tracking → uncertain → degraded ladder *from within* `processASRResult` — there's no independent timer driving it. So if ASR keeps failing (most likely: on-device speech model not downloaded for the selected locale, since `requiresOnDeviceRecognition` defaults to `true` per the PRD's "local processing by default" requirement), `onResult` never fires, `processASRResult` never runs, and status simply sits frozen at whatever `start()` last set (`.tracking`, green) — forever, silently. No error, no banner, nothing to look at except a script that isn't moving.

### Fix

Added `onStateChange: ((ASRState) -> Void)?` to `SpeechRecognizerProtocol` / `SFSpeechRecognizerService`, fired via `didSet` on `_state`. `AppState.startRecording()` now registers it and maps `.unavailable` straight to `trackingStatus = .degraded(reason: .asrUnreliable)`, so an ASR-level failure is now visible (red banner, "Tracking lost") instead of a silent no-op. Self-heals the same way manual/auto recovery already does if a later ASR result does succeed.

Didn't change `requiresOnDeviceRecognition`'s default — PRD explicitly wants local processing by default. If the banner now shows up, the actual next step is checking whether the on-device English model is downloaded (System Settings → General → Language & Region → dictation/offline model, or just System Settings → Keyboard → Dictation) rather than code — that's outside what the app can fix for the user.

### Still unverified

Haven't confirmed this was *the* cause vs. just making a pre-existing silent failure visible — waiting on the user to retest and report whether the banner now appears (confirms ASR-level failure) or tracking now actually works (would mean something else was transiently wrong and this fix is defense-in-depth regardless).

---

## 2026-09-09 (later) — Fixed repeated `_dispatch_assert_queue_fail` crash on recording start

### Symptom

Manual testing in Xcode: app crashed with `libdispatch.dylib`_dispatch_assert_queue_fail` every time recording started, across three different-looking incidents. Same generic disassembly each time (unhelpful on its own — it's boilerplate common to any wrong-queue assertion).

### Root cause (found via actual `bt`, not the disassembly)

`SFSpeechRecognizerService` is `@MainActor`. In Swift, a closure literal written directly inside a `@MainActor`-isolated method **inherits that isolation by default** unless the closure is `@Sendable` or the enclosing declaration is `nonisolated`. Three separate closures in `SpeechRecognizer.swift` were written this way, and each one is actually invoked by a system framework on its own background queue — never the main actor:

1. `SFSpeechRecognizer.requestAuthorization { ... }` completion — called by TCC on its own queue.
2. `AVCaptureDevice.requestAccess(for:) { ... }` completion — same.
3. `inputNode.installTap(...) { buffer, _ in request.append(buffer) }` — called by AVAudioEngine on its real-time `RealtimeMessenger` audio thread.

Because the closures were inferred `@MainActor`-isolated, Swift inserted a runtime check (`_swift_task_checkIsolatedSwift` → `swift_task_isCurrentExecutorWithFlagsImpl` → `dispatch_assert_queue`) asserting the calling thread was the main actor's executor. It never was — hence three separate crashes at three different call sites, all with the identical libdispatch disassembly (which is why the disassembly alone was useless for diagnosis; needed the actual `bt` frame naming the app-code closure each time).

### Fix

Extracted all three closures into `nonisolated private static` factory functions on `SFSpeechRecognizerService`. A closure's isolation is inherited from its *immediately enclosing* declaration, so a closure literal written inside a `nonisolated static func` carries no actor affinity — no isolation check gets synthesized, and the callback can safely run on whatever thread the system framework chooses.

Fixing the tap-block crash surfaced a second, real bug the compiler caught: the `recognitionTask` result handler was hopping into a `Task { @MainActor in ... }` while still holding the raw `SFSpeechRecognitionResult?`/`Error?` — neither is `Sendable`, so sending them across the actor boundary is a genuine data race, not just a false positive. Fixed by translating the callback into a small `Sendable` enum (`RecognitionOutcome`) synchronously, inside the nonisolated closure, *before* the `Task` hop — only the translated Sendable payload crosses into `@MainActor` code.

### Lesson for the rest of the app

Any other `@MainActor` type in this codebase that wraps a callback-based system API (delegate methods, completion handlers, C function pointers) is a candidate for the same bug if the callback closure is written inline. The tell is a crash with `_dispatch_assert_queue_fail` and a `_swift_task_checkIsolatedSwift` frame in the backtrace — always get the real `bt`, the top-frame disassembly of a libdispatch/libsystem_pthread trampoline is generic boilerplate and won't identify which call site is wrong.

---

## 2026-09-09 — RecoveryManager escalation: sticky DEGRADED → MANUAL_FALLBACK

### What shipped

Wired `RecoveryManager` into `TrackingEngine` so degraded tracking is no longer
open-ended — it now has a finite number of automatic-recovery attempts before
escalating to a sticky manual-fallback state.

**New ladder:**

```
TRACKING → UNCERTAIN → DEGRADED → (up to 3 failed recovery attempts) → MANUAL_FALLBACK
                           ↑                                                 │
                           └──────────── automatic recovery ─────────────────┘
                                     (only while still DEGRADED)

MANUAL_FALLBACK → (user taps a position) → TRACKING
```

### Key decisions

- **New `TrackingStatus.manualFallback` case**, not a reuse of `.degraded` or
  `.manual`. `.degraded` still means "ASR is unreliable, but still trying
  automatically" (banner: "Tracking lost — tap to re-sync", tap optional).
  `.manualFallback` means "automatic recovery gave up" (banner: "Tracking
  paused — tap where you are in the script", no auto-recover offered). Kept
  `.manual` reserved for the future user-selected manual `TrackingMode` — it's
  a different concept (user chose no ASR at all) from the engine giving up on
  ASR it can't trust.
- **Sticky by construction, not by extra state.** `processASRResult` now
  early-returns while `status == .manualFallback` — the engine simply stops
  feeding ASR into `PositionEngine` until a manual `jumpTo`. This guarantees
  "no automatic jumps after escalation" and "position doesn't move" without
  needing a separate freeze flag that could drift out of sync with `status`.
  Cost: the matcher snapshot's `consumedSpokenCount` stalls at whatever it was
  when fallback began — resolved by `jumpTo`'s existing `resetMatcher`, which
  rebases the matcher cursor and discards the stale backlog (this already
  existed for the plain manual-jump path; escalation reuses it for free).
- **`RecoveryManager` counts attempts, not clock time.** `TrackingEngine`'s
  existing elapsed-time envelope (`uncertainGrace` / `degradedAfter`) still
  owns the `tracking → uncertain → degraded` transitions — that logic was
  already tested and correct. `RecoveryManager.recordFailure()` is only
  invoked once the engine is *already* candidate-degraded, so its 3-attempt
  threshold measures "how many more ASR cycles failed while degraded," not
  wall-clock time. Keeps the two ladders from fighting over the same signal.
- **Counters reset on every recovery path**, not just success. Added
  `recoveryManager.reset()` to `jumpTo` (previously only called on a
  confirmed high-confidence match and on `start`). Otherwise a manual
  correction wouldn't clear stale failure counts, and the very next ASR hiccup
  could jump straight back to `manualFallback` instead of starting the ladder
  over — confirmed by a dedicated regression test.

### Tests added (`RecoveryEscalationTests`)

1. **Full escalation E2E** — tracking → degraded → 3 more failed recovery
   attempts → `manualFallback` → confirms position/status frozen even when a
   clean match arrives post-escalation → manual `jumpTo` re-arms → next ASR
   batch resumes matching from the manually selected token (not the discarded
   backlog) → confirms recovery counters actually reset (one fresh failure
   afterward lands on `.degraded`, not straight back to `.manualFallback`).
2. **Recovery success before escalation** — a single degraded episode that
   self-corrects before hitting the attempt threshold must not leave
   `RecoveryManager` in a partially-failed state that makes the *next*
   degraded episode over-eager to escalate.

All 45 `TeleprompterCore` tests + 7 `TeleprompterTests` (app-level) pass.
`xcodebuild -scheme Teleprompter build` and `test` both green.

### UI wiring

`TeleprompterView`'s bottom banner now has three mutually exclusive states
(recovering / manualFallback / degraded, checked in that order since they're
now distinct enum cases). `ContentView`'s diagnostic status label/color
switches updated for exhaustiveness (`manualFallback` → "Paused — tap to
resume", red).

### Not done yet (per the agreed order)

- Haven't eyeballed the actual banner/flow in the running app yet (Hyperframes
  preview or manual run) — next step.
- Velocity/scroll smoothing — after the above.
- Semantic matching — explicitly deferred; the lexical matcher is already
  sophisticated enough that its real-world behavior should be observed before
  adding another layer.

---

## Earlier work (undated, pre-devlog)

Established before this log started, reconstructed from code/git state:

- Core tracking engine (`TrackingEngine`, `PositionEngine`, `ScriptMatcher`)
  with forward-greedy cursor, near/far/bigram-confirmed matching, fuzzy
  edit-distance for longer words, homophone normalization, and a
  locality-blind global re-anchor after a miss streak.
- Explicit `TrackingStatus` state machine: tracking / paused / uncertain /
  recovering / manual / degraded(reason).
- Time-based envelope (`TrackingEnvelopeConfig`) driving tracking → uncertain
  → degraded escalation.
- Latency instrumentation (`LatencyRecorder`) marking asrReceived →
  matcherStarted → matcherFinished → positionEmitted → uiReceived per cycle.
- Recovery UX: tap-to-jump on any script block, arrow-key position
  adjustment, recenter, degraded/recovering banners.
- Sequence/repeated-context hardening: tests proving a single stray word from
  a repeated phrase doesn't leap the cursor into the next occurrence, and that
  leaps stay monotonic without oscillation afterward — this is where a real
  ambiguity bug was found and fixed (see `RepeatedContextStressTests`).
