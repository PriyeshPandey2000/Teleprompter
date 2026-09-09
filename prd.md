# PRD — Native AI Teleprompter

## Product vision

> **Read naturally. Stay on track. Never fight the teleprompter.**

The product is a native Mac/iPhone/iPad teleprompter for people recording themselves on camera.

The central UX principle is:

> **The user should adapt to the teleprompter as little as possible.**

That means:

* the text responds quickly;
* the system tolerates natural speech;
* mistakes don't derail the recording;
* corrections are instant and discreet;
* setup is almost zero;
* the user doesn't have to monitor the AI.

---

# 1. Product hierarchy

Every feature belongs to one of these layers:

```text
LAYER 1
Readability + setup
        ↓
LAYER 2
Real-time tracking
        ↓
LAYER 3
Recovery when tracking is wrong
        ↓
LAYER 4
Recording workflow
        ↓
LAYER 5
Practice + delivery intelligence
```

**Layer 3 is just as important as Layer 2.**

A teleprompter that is 98% accurate but takes 5 seconds to recover is worse than one that is 95% accurate and lets you instantly recover.

---

# 2. V0 — Tracking Engine Prototype

V0 exists to answer:

> **Can we make real-time tracking feel instantaneous and reliable?**

No polished product UI yet.

## 2.1 Tracking states

The engine must explicitly support:

### `TRACKING`

Normal operation.

Speech matches script.

### `PAUSED`

User stopped talking.

The script stops moving.

### `UNCERTAIN`

ASR/tracking isn't sure where the user is.

**Do not aggressively move the script.**

Maintain the current position until confidence improves.

### `RECOVERING`

The system believes the user has resumed somewhere else in the script.

Search nearby text and reposition.

### `MANUAL`

User explicitly selected a position.

Tracking resumes from that position.

### `DEGRADED`

Speech recognition is temporarily unavailable or unreliable.

The UI switches to a predefined fallback behavior.

This state machine should exist **before V1**, not be improvised later.

---

# 3. V0 performance requirements

## P0 — Perceived latency

This is a launch gate.

### Target

**≤200 ms**

from:

```text
spoken word
     ↓
ASR result
     ↓
position update
     ↓
visible script movement
```

### Stretch goal

**≤100 ms perceived response**

The exact internal ASR latency can vary, but the user's perception is what matters.

### Failure condition

If tracking consistently feels delayed enough that the user has to wait for the text:

**V1 does not ship.**

Accuracy doesn't compensate for noticeable lag.

---

# 4. V0 tracking test matrix

The benchmark must include:

| Scenario                   | Expected behavior               |
| -------------------------- | ------------------------------- |
| Normal reading             | Follow continuously             |
| Fast speech                | Keep up                         |
| Slow speech                | Don't run ahead                 |
| Long pause                 | Freeze                          |
| Repeat sentence            | Don't jump backward incorrectly |
| Skip paragraph             | Recover                         |
| Go backward                | Follow new position             |
| Improvisation              | Wait rather than panic          |
| Paraphrasing               | Maintain approximate position   |
| Background noise           | Gracefully degrade              |
| Names                      | Avoid large jumps               |
| Numbers                    | Avoid false matches             |
| Technical terms            | Maintain position               |
| Accent                     | Maintain position               |
| Indian English             | Maintain position               |
| Hindi-English              | Maintain position               |
| Poor microphone            | Degrade gracefully              |
| Multiple failures together | Recover                         |

---

# 5. Indian-English / code-switching benchmark

This becomes a first-class V0 requirement.

Test:

### Indian English

Different:

* pronunciation
* rhythm
* pacing
* vowel sounds
* consonant pronunciation

### Hindi-English

Example:

> "Basically hum is product ke through..."

Then:

> "So what we're trying to solve..."

Then English again.

The system shouldn't interpret code-switching as a catastrophic ASR failure.

### Important

Don't market this initially as:

> "The Indian teleprompter."

Unless testing proves you have a meaningful advantage.

Instead:

**Build the capability first.**

It becomes an important competitive advantage if your benchmark shows substantially better results.

---

# 6. V1 — The usable Mac teleprompter

The V1 objective is **not maximum features**.

It is:

> **Paste/import a script → position camera → record.**

---

# 7. V1 first-run experience

The first launch should look roughly like:

```text
        Your script

   Paste your script here

   ─────────────────────

        [Start]
```

That's it.

After the script is inserted:

```text
Camera detected ✓
Microphone detected ✓
Display configured ✓

              [Start]
```

The application automatically chooses sensible defaults.

---

# 8. Smart defaults

Instead of exposing 15 settings immediately:

### Automatically determine

* font size
* line width
* line spacing
* scroll region
* window position
* text contrast
* reasonable margins
* initial scroll behavior

Font size should be based primarily on:

> **available display size + teleprompter viewport**

rather than asking the user to configure it manually.

---

# 9. Advanced settings

Put everything else behind:

> **Appearance & controls**

Include:

* font
* font size
* line spacing
* margins
* opacity
* text color
* background
* mirror
* flip
* manual scroll speed
* keyboard shortcuts

### Principle

**Default path = one decision.**

**Advanced path = complete control.**

---

# 10. Script preparation

This moves into V1.

The user will rarely provide beautiful scripts.

They will paste:

```text
today i want to talk about our product
which helps companies automate sales
and save time...
```

The application should automatically make it readable.

### Automatic formatting

* sensible line wrapping
* paragraph detection
* spacing
* readable line length
* sentence boundaries
* bullet rendering
* headings
* whitespace cleanup

Do **not** modify the user's actual script text without permission.

Create a:

> **Presentation view**

while preserving the original content.

---

# 11. Script import

V1 supports:

### Required

* paste
* TXT
* DOCX
* PDF

### Planned

* Google Docs

Import should preserve where possible:

* headings
* bold
* bullets
* paragraphs
* basic formatting

This is **compatibility**, not the product moat.

But it is a launch requirement.

---

# 12. Start-point selection

Before recording:

The user can click any point in the script.

Then:

> **Start here**

This becomes the tracking anchor.

Useful for:

* retakes
* recording one section
* continuing yesterday's recording
* fixing one paragraph
* creating multiple clips from one script

---

# 13. Countdown

Every recording starts with:

```text
3

2

1

GO
```

Allow:

* 3 sec
* 5 sec
* 10 sec
* disabled

The countdown should be configurable but default to **3 seconds**.

---

# 14. V1 tracking UX

The screen should not scream:

> AI confidence: 72%

Instead:

### During recording

Almost nothing.

The user's attention belongs on the camera.

---

# 15. Tracking indicator

Use a **very subtle peripheral indicator**.

For example:

```text
│
│
│  SCRIPT
│
│
```

A thin edge indicator can represent:

* normal
* uncertain
* degraded

But it should never demand attention when everything is working.

### No numerical confidence during recording.

Confidence information belongs in:

**Practice mode / diagnostics.**

---

# 16. The most important V1 feature: recovery

This becomes a P0 requirement.

The system **will eventually be wrong.**

The product must make that irrelevant.

---

# 17. Recovery interaction #1 — Tap to jump

The user can tap/click anywhere in the script.

That immediately becomes:

> **Current position**

Tracking resumes from there.

No modal.

No confirmation.

No restart.

---

# 18. Recovery interaction #2 — Keyboard shortcuts

Example:

```text
↑ / ↓
small position adjustment

Shift + ↑ / ↓
larger adjustment

R
recenter tracking

Space
pause/resume
```

Exact bindings can change, but manual correction must be instantaneous.

---

# 19. Recovery interaction #3 — Remote correction

The iPhone remote should eventually have:

```text
      ↑

←    RECENTER    →

      ↓
```

**RECENTER** tells the engine:

> "Trust this position and continue tracking from here."

This is particularly useful when the computer is physically mounted away from the user.

---

# 20. Recovery interaction #4 — Voice commands

Don't make this V1 launch-critical if reliable voice-command detection isn't ready.

But architect for:

> "skip"

> "back"

> "repeat"

> "pause"

> "continue"

These commands should eventually become part of the tracking layer.

Importantly, commands must not accidentally become part of the spoken script.

---

# 21. Recovery design principle

Never punish the user for an AI mistake.

Bad:

```text
TRACKING ERROR

[Restart tracking]
```

Good:

```text
User taps correct line

↓

Tracking immediately resumes
```

The user shouldn't even think about the underlying failure.

---

# 22. Degraded mode

This must be explicitly specified.

If ASR becomes unreliable:

### Stage 1

Continue using the last known position.

Don't move aggressively.

### Stage 2

If uncertainty persists:

**Freeze the script.**

Don't guess.

### Stage 3

Show subtle peripheral indication:

> tracking unavailable

### Stage 4

User can manually reposition.

### Optional fallback

If the user explicitly enables it:

> **Fallback to fixed-speed scrolling**

The app can transition into fixed-speed scrolling after prolonged ASR failure.

But I would **not automatically switch immediately**.

Why?

Because:

> wrong movement is more damaging than no movement.

---

# 23. Recovery state machine

```text
             ┌──────────────┐
             │   TRACKING   │
             └──────┬───────┘
                    │
              uncertainty
                    ↓
             ┌──────────────┐
             │  UNCERTAIN   │
             └──────┬───────┘
                    │
          ┌─────────┴─────────┐
          ↓                   ↓
      recovered           timeout
          ↓                   ↓
      TRACKING            DEGRADED
                              │
                         user correction
                              ↓
                          MANUAL
                              │
                              ↓
                          TRACKING
```

This is much more important than simply adding another model.

---

# 24. V1 hardware workflow

Must support:

### MacBook camera

### External webcam

### External monitor

### Hardware teleprompter

### Beam-splitter glass

Therefore:

* horizontal mirror
* configurable display
* external display selection
* window sizing
* camera positioning

are all V1 requirements.

---

# 25. V1 manual mode

Voice tracking shouldn't be mandatory.

Provide:

### Voice mode

Text follows speech.

### Manual mode

User controls scrolling.

### Hybrid mode

User can manually correct while tracking remains active.

This gives the user a safety net.

---

# 26. V1 recording telemetry

This is invisible to the user.

Every recording should capture structured data required for future analysis.

For every session:

```text
Recording
 ├── startTime
 ├── endTime
 ├── scriptID
 ├── scriptVersion
 ├── audio timestamps
 ├── recognized words
 ├── word timestamps
 ├── detected pauses
 ├── tracking position
 ├── tracking corrections
 ├── skipped sections
 ├── backward movements
 ├── confidence events
 └── degraded events
```

This is **V1 infrastructure for V3**, not a V3 feature.

---

# 27. Privacy

Because this data may contain recordings and speech:

Default:

> **Local processing.**

If data ever leaves the device:

* clearly tell the user
* obtain permission
* explain why

No silent uploading.

---

# 28. V1.1 — iPhone Remote

Now add the physical-control workflow.

Mac:

> Teleprompter

iPhone:

> Remote

Controls:

* play/pause
* start
* stop
* previous
* next
* speed
* position adjustment
* recenter

---

# 29. V1.2 — iPhone companion

iPhone can additionally:

* display script
* show current position
* act as microphone
* control Mac
* provide recording controls

But don't turn the iPhone into a completely separate product yet.

---

# 30. V2 — Natural Speech Tracking

Only now do we aggressively improve semantic tracking.

Capabilities:

### Repetition

Don't jump backwards accidentally.

### Paraphrase

Understand approximate meaning.

### Skipping

Detect large position jumps.

### Backtracking

Follow the new position.

### Improvisation

Don't chase unrelated speech.

### Long pauses

Don't interpret silence as failure.

---

# 31. V2 confidence model

Confidence is primarily an **internal control mechanism**, not a user-facing feature.

The engine should maintain:

```text
current position
+
candidate positions
+
confidence
+
velocity
+
recent history
```

Instead of:

> "The latest ASR phrase matched line 472, jump there."

Use:

> "Given the last 10 seconds of movement, line 472 is probably the current position."

This prevents wild jumps.

---

# 32. V2 recovery improvements

Recovery becomes increasingly automatic.

Example:

```text
User:
"Actually, let me explain that another way..."

             ↓

Engine:
uncertain

             ↓

Don't move

             ↓

User returns to script

             ↓

Engine recognizes section

             ↓

Resume
```

The user's recording never needs to stop.

---

# 33. V3 — Practice & Delivery

Now expose the telemetry collected from V1.

### Practice mode

Show:

* script coverage
* pacing
* pauses
* filler words
* repeated phrases
* skipped sections
* delivery consistency

This is where confidence visualization belongs.

---

# 34. V3 recording analysis

Example:

```text
YOUR TAKE

Duration       2:43
Pace           148 WPM
Coverage       94%

Filler words
"um"            3
"like"          2

Long pauses      2

Repeated lines   1
```

Then:

> **Suggestion**

> Your introduction was 18% slower than the rest of the video.

---

# 35. V3.1 — Bullet / idea tracking

Now introduce the bigger concept:

### Speak from ideas, not sentences.

Instead of:

```text
Our platform helps sales teams
automate their outbound workflow...
```

Show:

```text
WHY SALES TEAMS USE US

• Automate outbound
• Save time
• Reduce manual work
• Improve response rates
```

The engine tracks the **conceptual section** rather than exact wording.

This is a major evolution of the product.

---

# 36. V4 — Recording workflow

The teleprompter becomes a recording workspace.

### Takes

```text
Script

Take 1
Take 2
Take 3
Take 4
```

Every take has:

* video
* transcript
* tracking data
* pacing
* coverage
* filler count

---

# 37. V4.1 — Best Take

Compare takes automatically.

Example:

> **Take 4 — Recommended**

Because:

* strongest script coverage
* consistent pacing
* fewer fillers
* fewer corrections
* fewer long pauses

---

# 38. V5 — Personalized Video Workflow

Only after the core product is proven.

Scripts can contain:

```text
{{firstName}}
{{company}}
{{painPoint}}
```

The user can create multiple personalized recordings efficiently.

This is where the product can evolve into a broader video workflow rather than remaining purely a teleprompter.

---

# 39. Platform architecture

Use:

**Xcode + Swift + SwiftUI**

with a shared core.

```text
                    Shared Swift Package
                           │
          ┌────────────────┼────────────────┐
          │                │                │
       macOS             iOS            iPadOS
          │                │                │
    Mac-specific       Camera/remote    Large display
    windows            controls         teleprompter
    external           microphone
    displays
```

### Shared

```text
Core/
├── Script/
├── ScriptFormatting/
├── Speech/
├── Tracking/
├── PositionEngine/
├── Recovery/
├── Recording/
├── Telemetry/
└── Models/
```

### macOS

```text
MacApp/
├── TeleprompterWindow/
├── FloatingWindow/
├── ExternalDisplay/
├── KeyboardControls/
└── MenuBar/
```

### iOS

```text
iOSApp/
├── Remote/
├── Camera/
├── Microphone/
└── TouchControls/
```

The **tracking engine and recovery system should be shared**.

---

# 40. V1 priority matrix

This is the corrected priority.

| Feature                   | Priority |
| ------------------------- | -------: |
| ≤200ms perceived response |   **P0** |
| Tracking state machine    |   **P0** |
| Manual recovery           |   **P0** |
| Tap-to-jump               |   **P0** |
| Recenter                  |   **P0** |
| Degraded mode             |   **P0** |
| Smart defaults            |   **P0** |
| Basic script formatting   |   **P0** |
| Start-point selection     |   **P0** |
| Countdown                 |   **P0** |
| Word-level tracking       |   **P0** |
| Manual scrolling          |   **P0** |
| Mirror mode               |   **P0** |
| External display          |   **P0** |
| DOCX/PDF import           |   **P0** |
| Recording telemetry       |   **P0** |
| Advanced appearance       |       P1 |
| iPhone remote             |       P1 |
| Voice commands            |       P1 |
| Semantic tracking         |       V2 |
| Practice analytics        |       V3 |
| Bullet/idea tracking      |       V3 |
| Best-take analysis        |       V4 |
| Personalized videos       |       V5 |
| Team workflows            |       V6 |

---

# 41. V1 definition of done

V1 isn't:

> "We implemented speech tracking."

V1 is done when a real person can:

```text
Paste messy script
       ↓
App formats it
       ↓
Choose camera/display
       ↓
Click starting point
       ↓
3-second countdown
       ↓
Start recording
       ↓
Speak naturally
       ↓
Pause
       ↓
Continue
       ↓
Make a mistake
       ↓
Tap correct position
       ↓
Continue
       ↓
Finish recording
```

**without feeling like they're operating software.**

---

# 42. The five V1 product gates

Before calling V1 finished:

### Gate 1 — Latency

> **≤200ms perceived response**

### Gate 2 — Recovery

A tracking error can be corrected in:

> **≤1 second**

without stopping the recording.

### Gate 3 — Setup

From fresh install to first recording:

> **≤60 seconds**

for a normal user.

### Gate 4 — Readability

A messy pasted script must become comfortably readable **without manual formatting**.

### Gate 5 — Failure

When ASR fails:

> **the app must fail gracefully rather than move the user to the wrong place.**

These five gates are more important than adding another ten features.

---

# 43. The most important product philosophy

I would actually change one line from the original PRD.

Don't make the goal:

> **"Build the most accurate teleprompter."**

Make it:

> **"Make tracking failures invisible."**

Because you cannot promise perfect speech recognition.

You **can** design the product so that:

```text
ASR correct
       ↓
beautiful experience

ASR uncertain
       ↓
nothing scary happens

ASR wrong
       ↓
one tap

ASR unavailable
       ↓
graceful fallback

user improvises
       ↓
app waits

user goes backward
       ↓
app follows
```

That is what makes the product feel **premium**.

And importantly, this architecture means V2 doesn't have to "fix" V1's fundamental UX. **V2 makes the existing recovery system trigger less often; V1 already knows what to do when it does.**
