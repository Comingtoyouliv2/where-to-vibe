# Architecture — where-to-vibe

A fork-and-extend of [Where-to-vibe](https://github.com/Comingtoyouliv2/where-to-vibe.git) that turns the menu-bar
cursor companion into a **coding sub-agent** for developers using Cursor, Claude Code, Codex,
ChatGPT, or any other AI coding tool.

The product is *not* another chatbot. It watches what the developer is about to send to an
AI agent (or what the terminal/editor is showing) and nudges them toward:

1. **Better questions** — vague "build me X" → explicit task spec (goal, constraints,
   completion criteria, test plan).
2. **Smaller changes** — bias toward surgical edits, not sweeping refactors.
3. **Verifiable success** — every suggested change ships with a way to check it.

---

## 1. What we inherit from Where-to-vibe

| Capability | Where it lives in upstream | What we keep |
|---|---|---|
| Menu-bar-only app, no dock icon | `WhereToVibeApp.swift` + `MenuBarPanelManager.swift` | Yes, identical |
| Push-to-talk via `ctrl+option` | `GlobalPushToTalkShortcutMonitor.swift` | Yes, but also bound to a *new* "coach me" hotkey |
| Multi-monitor screenshot via ScreenCaptureKit | `CompanionScreenCaptureUtility.swift` | Yes — this is the eyes |
| Cursor overlay that can fly to `[POINT:x,y:label]` | `OverlayWindow.swift` | Yes — used to point at the prompt textarea / failing test |
| Cloudflare Worker proxy (TS) | `worker/src/index.ts` | **Heavily extended** — see §3 |
| Claude streaming chat with vision | `ClaudeAPI.swift` | Yes — model + transport unchanged |
| AssemblyAI STT + ElevenLabs TTS | Multiple providers | Optional — coding context usually wants text-only output |

## 2. What we change

The single highest-leverage change in the **Swift app** is one constant:
`CompanionManager.swift:544 companionVoiceResponseSystemPrompt` becomes
`whereToVibeSystemPrompt` and is rewritten end-to-end (see `PROMPTS.md`).

Everything else hangs off the **worker** — it gets new routes (`/coach`, `/classify`,
`/spec`) so the same intelligence is callable from any future client (browser extension,
VS Code extension, CLI), not just the Swift app.

## 3. Data flow

```
                     ┌───────────────────────────────────────────────┐
                     │                User's screen                  │
                     │  (Cursor / Claude Code / ChatGPT / terminal)  │
                     └───────────────────┬───────────────────────────┘
                                         │ screenshot + (optional)
                                         │ selected text or clipboard
                                         ▼
                   ┌──────────────────────────────────────────┐
                   │  Swift app — CompanionManager (trigger)  │
                   │                                          │
                   │  MANUAL                                  │
                   │  • ctrl+option → coach NOW on current    │
                   │    screen                                │
                   │                                          │
                   │  AUTO                                    │
                   │  • idle observer: user typed ≥12 chars   │
                   │    into an AI prompt box, then paused    │
                   │    3–4s                                  │
                   │  • strong signal: terminal shows a fresh │
                   │    error / diff / PR view appears        │
                   │  • dedupe: hash of last N nudges; drop   │
                   │    a new one if identical                │
                   └──────────────────┬───────────────────────┘
                                     │  POST /coach
                                     ▼
              ┌────────────────────────────────────────────────┐
              │  Cloudflare Worker  (worker/src/index.ts)      │
              │                                                │
              │  /coach    — main coaching round-trip          │
              │  /classify — what mode is the user in?         │
              │  /spec     — vague request → task spec         │
              │  /chat     — kept for backwards compat         │
              │  /tts, /transcribe-token — unchanged           │
              │                                                │
              │  Adds the where-to-vibe system prompt server-   │
              │  side so non-Swift clients get the same brain. │
              └──────────────────┬─────────────────────────────┘
                                 │  Claude Sonnet 4.6 (vision)
                                 ▼
            ┌─────────────────────────────────────────────┐
            │   Response shape (SSE stream):              │
            │   {                                         │
            │     "mode": "prompt_coach" | "error_first_ │
            │              cause" | "diff_review" | ...,  │
            │     "nudge": "<= 2 sentences, plain text",  │
            │     "rewrite": "optional better prompt",    │
            │     "checks": ["how to verify success"],    │
            │     "point": [x,y,"label"] | null           │
            │   }                                         │
            └─────────────────────────────────────────────┘
                                 │
                                 ▼
                   ┌──────────────────────────────────────────┐
                   │  Swift overlay  (read-only speech bubble)│
                   │  • bubble appears next to the mouse      │
                   │    cursor with the `nudge` text          │
                   │  • single-direction: no reply input, no  │
                   │    chat history, no follow-up turn       │
                   │  • if `rewrite` present: bubble shows    │
                   │    "press tab to replace your prompt"    │
                   │  • if `point` present: small arrow on    │
                   │    the bubble pointing at that pixel     │
                   │  • dismiss: 7s auto / ESC / replaced by  │
                   │    new context                           │
                   └──────────────────────────────────────────┘
```

## 4. UI behaviour — when and how the bubble appears

The companion is invisible by default. It only renders a small **read-only
speech bubble next to the mouse cursor** when one of the rules below fires.
The bubble shows the `nudge` text (and, if present, a "tab to replace"
affordance for `rewrite`). There is no reply input — the user reads it and
moves on.

### 4.1 Triggers

**Manual** — the user explicitly asked, so we honour it unconditionally:

- `ctrl+option` → take a screenshot of the current screen, POST `/coach`,
  render the bubble next to the cursor.
- **Manual trigger bypasses idle gating, cooldown, and dedupe.** If the
  user calls us back on the same screen with the same nudge, we show it
  again — they asked. It still *replaces* the current bubble rather than
  stacking one on top of another (see §4.3).

**Automatic** — fires without the user asking, but only when at least one
strong signal is present:

- *AI-prompt idle*: the front app is in the AI-chat allow-list (see
  `worker/src/triggers.ts`) and the visible input has ≥ 12 characters that
  have been stable for **3–4 seconds**. (We sample input text when possible;
  otherwise we sample the screenshot region known to contain the chat input
  and compare frame-to-frame.)
- *Fresh error*: the front app is a terminal/console and a new traceback /
  panic / failed-test banner has appeared since the last screenshot.
- *Diff just opened*: a PR view, `git diff` output, or a side-by-side diff
  becomes visible.

Auto triggers are **transition-based when OS/app signals are available**
(e.g. Accessibility `kAXValueChangedNotification` on the AI chat input,
front-app change notifications, focused-element changes). When those
signals aren't available for a given app, **low-frequency observation is
allowed as an implementation fallback** — sampling the screen every ~1s,
diffing the relevant region, and only firing on a change. The contract
the rest of the system relies on is "auto fires on transitions", not
"the client is event-driven everywhere".

Anything that doesn't match a strong signal stays **silent by default**.
The companion does not coach opportunistically.

### 4.2 Dedupe — "동일 조언 반복 금지"

The Swift client keeps a small ring buffer of the last *N* (default 5)
`nudge` strings it has rendered, hashed. When a new `/coach` response
arrives **from an auto trigger**:

1. Compute `hash(nudge + mode + rewrite)`.
2. If it matches any entry in the buffer, **drop the response silently** —
   do not render, do not animate.
3. Otherwise, render and push the hash onto the buffer (evicting the
   oldest).

**Manual triggers skip step 2** (see §4.1). They always render, and they
still push their hash onto the buffer so that a subsequent *auto* trigger
with the same nudge gets deduped.

This is intentionally client-side only: the worker stays stateless, and a
future second client (browser extension, etc.) gets to decide its own
dedupe window without coordinating.

### 4.3 Dismiss

A rendered bubble goes away when **any** of these happens:

- **7-second timeout** — measured from first render, not from when the user
  looks at it. Generous enough to read 2 sentences, short enough not to
  hover.
- **ESC** — instant dismiss.
- **Replacement** — a *new* `/coach` response is about to be rendered
  (passed dedupe for an auto trigger, or came from a manual one). The old
  bubble is removed and the new one rendered at the current cursor
  position, not the old anchor (see §4.4). No stacking, no queue.

The bubble does not have a close button. The whole UI surface is one
text element + (optional) one pointer arrow.

### 4.4 Positioning

The bubble's identity is "next to the mouse" — that's what makes it feel
like a companion instead of an overlay. So:

- **Appears near the cursor when triggered.** Anchor: top-left of bubble
  is offset `(+18, +18)` pixels from the mouse cursor position *at the
  moment the trigger fires*.
- **Does not continuously chase the cursor during a nudge.** Once
  rendered, the bubble is pinned to that anchor for its lifetime. The
  user can move the mouse away to read it, scroll, click — the text
  doesn't slide around with them.
- **A new trigger re-anchors.** If another trigger fires (manual hotkey,
  or an auto signal with a non-deduped nudge) while the old bubble is
  still on screen, the replacement bubble appears at the *current* cursor
  position, not the previous one (see §4.3 "Replacement").
- Clamping: if the anchor would put the bubble outside the screen bounds,
  mirror to `(-18 - bubbleWidth, +18)` (i.e. left of cursor). Then clamp
  Y to `[8, screenHeight - bubbleHeight - 8]`.
- If `point` is present in the response, a small arrow on the relevant
  edge of the bubble points toward `(point.x, point.y)` in screen-space.
  No cursor-flying animation (that was upstream Where-to-vibe's behaviour; we're
  deliberately quieter).

### 4.5 What is *not* in this UI

- No voice / TTS playback. (Upstream Where-to-vibe has it; we keep the proxy
  endpoint but don't invoke it from the bubble path. Coding context is
  text.)
- No chat history / conversation memory visible to the user. The worker
  may pass recent turns as `history` server-side, but the client doesn't
  expose them.
- No follow-up question turn. If the model returned a clarifying question
  in `nudge`, the user answers by editing their own prompt in their AI
  tool of choice, not by talking back to the bubble.

## 5. The four trigger modes (Karpathy → product rules)

The agent classifies every invocation into one of four modes and uses a different
playbook for each. This is enforced by the system prompt and a tiny pre-classifier.

### 5.1 `prompt_coach` — user is typing a prompt to an AI agent

**When this fires:** see §4.1 (AI-prompt idle trigger) and the app/host
allow-lists in `worker/src/triggers.ts`. Briefly: front app is an AI-chat
app or a browser on an AI-chat host, the visible input has ≥ 12 chars,
and the user paused for 3–4 seconds.

**What the agent does:**

Score the in-progress prompt against the four Karpathy axes:

1. **Goal** — does the prompt name a concrete outcome?
2. **Constraints** — language/framework/file/perf/security limits stated?
3. **Done criteria** — how will we know it worked?
4. **Test/verify** — what command / inspection proves it?

If 3 of 4 are missing, return a `rewrite` that fills the gaps using only what's
visible on screen. Never fabricate constraints. Ask one question if a constraint is
load-bearing and unknowable.

### 5.2 `vague_build_me` — "만들어줘" / "make it" with no spec

This is a subtype of `prompt_coach` but with stricter rules. If the prompt is
imperative + no nouns specific to a file/function/feature, the agent **refuses to
let it pass through**. It returns a `rewrite` shaped as a *task spec for an AI
agent*:

```
GOAL: <one sentence outcome>
TOUCH: <files/functions allowed to change>
DO NOT TOUCH: <surface the user clearly doesn't want changed>
CONSTRAINTS: <language/runtime/style — pulled from screen>
DONE WHEN: <observable success>
VERIFY BY: <command/inspection>
ASSUMPTIONS I MADE: <list>
```

Karpathy rule applied: "make assumptions explicit, ask if unsure."

### 5.3 `error_first_cause` — terminal or console is showing an error

**When this fires:** see §4.1 (*Fresh error* signal). Briefly: front app is
a terminal/console and a new traceback / panic / failed-test banner just
appeared. Visual cues: `Error`, `Traceback`, `panic`, `unexpected`, `Cannot
find`, or a red stack frame.

**What the agent does:**

- Identify the **first** failing frame, not the last (most-recent-call-last
  ordering trips users up).
- Name the *minimal* reproducer: one command, one input.
- Propose the smallest change that would plausibly fix it, with a `VERIFY BY`
  command.
- Never propose a refactor in this mode. Only "one-line / one-file" fixes.

### 5.4 `diff_review` — a PR/diff/git status is on screen

**When this fires:** see §4.1 (*Diff just opened* signal) or manual
`ctrl+option` while a diff is visible. Visual cues: `+++`/`---` markers,
GitHub PR URL, `git diff` output, or a Cursor side-by-side diff.

**What the agent does:**

- Skip stylistic comments entirely.
- Look for: missing tests, regressions in adjacent code paths, scope creep
  (changes outside what the PR title implies), removed error handling, swallowed
  exceptions.
- Output at most 3 nudges, ranked by blast radius.

## 6. Karpathy guideline → enforcement mechanism

| Guideline | How we enforce it |
|---|---|
| Make assumptions explicit | System prompt requires `ASSUMPTIONS I MADE:` block in any `rewrite` |
| Ask if unsure | Allow exactly *one* clarifying question per round; otherwise proceed |
| Minimal code changes | In `diff_review` and `error_first_cause`, the prompt explicitly forbids "refactor", "restructure", "while we're here" |
| No unnecessary abstraction | Suggestions that add new files/classes/interfaces require a "Why this can't be inlined" line |
| Keep existing style | Vision pass: when proposing code in the nudge, mirror the indentation/quote-style/naming visible in the screenshot |
| Verifiable success | Every `rewrite` and every `nudge` of mode ≠ `prompt_coach` must end with a `VERIFY BY:` line. Server-side validation rejects responses missing it. |

## 7. Server-side validation (response shaping)

`worker/src/index.ts` post-processes Claude's response before streaming back. If
the response is missing structural fields (e.g., `VERIFY BY:` in a non-coach mode,
or `ASSUMPTIONS I MADE:` in a coach rewrite), the worker re-asks Claude with a
short "you forgot X, retry with the missing field only" follow-up. This keeps the
client dumb and the contract crisp.

## 8. Why not pure Electron + TS

We considered a from-scratch Electron rewrite. Decision: **keep the Swift app for
the overlay** (ScreenCaptureKit + `NSPanel` cursor following + global hotkeys are
significantly less work in Swift than in Electron, and the overlay UX is Where-to-vibe's
moat). All *intelligence* lives in the TypeScript worker, so future Electron /
browser-extension / CLI clients can plug into the same `/coach` endpoint without
re-implementing the brain.

If a pure-Electron version is later needed, the worker contract is the
boundary — Electron just needs to (a) grab a screenshot, (b) POST to `/coach`,
(c) render the nudge near the cursor.

## 9. Repo layout

```
where-to-vibe/
├── README.md
├── ARCHITECTURE.md            ← this file
├── PROMPTS.md                 ← all system prompts (source of truth)
├── worker/                    ← extended Cloudflare Worker (TypeScript)
│   ├── src/
│   │   ├── index.ts           ← routes + response validation
│   │   ├── prompts.ts         ← system prompts as TS constants
│   │   ├── triggers.ts        ← mode classifier heuristics
│   │   └── validators.ts      ← post-process Claude's response
│   ├── package.json
│   ├── wrangler.toml
│   └── tsconfig.json
├── swift-patches/
│   ├── CompanionManager.systemPrompt.patch   ← unified diff
│   └── README.md              ← how to apply the patch
└── tests/
    └── prompt-scenarios.md    ← validation scenarios + expected outputs
```
