# Where-to-vibe for macOS

> **Install in one Terminal command — see [Install (macOS)](#install-macos) below.**

Where-to-vibe is a native macOS menu bar MVP for onboarding people into
the AI coding agent era. It helps users learn how to think with AI:
turning vague ideas into MVPs, specs, architecture prompts, debugging
prompts, and eventually agent workflows.

It does not claim that one AI can solve everything. It coaches users
honestly about scope, context windows, multi-file reasoning, debugging
limits, and when tools like Claude Code, Cursor, OpenCode, or OpenAgent
are a better fit than a chat-only workflow.

The first surface is a quiet real-time co-builder: when the current draft
is too broad, a small suggestion panel appears near the caret or mouse
and offers a more executable rewrite. Press Tab to accept it directly into
the focused input.

## MVP behavior

- Watches the currently focused Accessibility text element.
- Reads the current input text after the user pauses.
- Detects vague prompts with a fast local heuristic.
- Generates local suggestions in well under 300 ms after debounce.
- Shows a small non-activating floating panel near the caret or mouse.
- Accepts the selected suggestion with Tab.
- Dismisses with Esc.
- Leaves arrow keys alone so they keep controlling the app the user is typing in.
- Shows `EN` or `KR` in the macOS menu bar and forces recognition/output
  to that language.
- Supports learning levels: `Beginner`, `Intermediate`, and `Advanced`.
- Supports prompt evolution stages: `Idea`, `MVP`, `Spec`,
  `Architecture`, `Debug`, and `Agent`.
- Auto-detects the active learning level and prompt evolution stage from
  the current input, with a manual override in settings.
- Uses a local gbrain-style memory adapter for accepted prompt history.
- Uses a local gstack-style guidance adapter for engineering thinking,
  debugging shape, architecture boundaries, and agent transition warnings.
- Supports optional OpenAI-powered screen-aware suggestions in `Fast AI`
  and `High Quality AI` modes.
- Runs as a menu bar app with a compact settings panel.

Example:

```text
make an app
```

Suggestion:

```text
Build a macOS AI coach that helps users turn vague prompts into executable specs.
Focus on the core workflow first: detect focused text, suggest a concrete rewrite,
and let the user accept it with Tab.
```

## Install (macOS)

No Xcode, no build. Paste this into **Terminal** — it installs and launches
the app in one go:

```bash
curl -fsSL -o /tmp/Where-to-vibe.zip "https://github.com/Comingtoyouliv2/where-to-vibe/releases/latest/download/Where-to-vibe.zip" && \
mkdir -p ~/Applications && \
unzip -oq /tmp/Where-to-vibe.zip -d ~/Applications && \
xattr -dr com.apple.quarantine ~/Applications/Where-to-vibe.app && \
open ~/Applications/Where-to-vibe.app
```

What it does: downloads the latest build, unzips it to `~/Applications`, clears
the macOS download quarantine, and launches it. The quarantine step is needed
because this is a **demo build that isn't notarized by Apple yet** — running it
from Terminal this way replaces the Gatekeeper "cannot be opened" prompt.

After it launches:

1. The app lives in the **menu bar** (no Dock icon). A short tutorial walks you
   through granting **Accessibility** permission — when System Settings opens,
   just flip the `Where-to-vibe` switch on.
2. Open the menu-bar panel (✨) → **Settings** → paste your own **OpenAI API
   key** to turn on the AI suggestions (`Fast AI` / `High Quality AI`).

Requirements: macOS 14.2+ (Apple Silicon or Intel).

To uninstall: `rm -rf ~/Applications/Where-to-vibe.app`

## Build from source (developers)

Requirements:

- macOS 14.2+
- Xcode 15+
- Accessibility permission for the built app
- Optional OpenAI API key for screen-aware `Fast AI` and `High Quality AI`
  suggestions

Open the app project:

```bash
cp macos-app/where-to-vibe/Info.plist.example \
   macos-app/where-to-vibe/Info.plist
open macos-app/where-to-vibe.xcodeproj
```

In Xcode:

1. Select the `where-to-vibe` scheme.
2. Set your signing team under Signing & Capabilities.
3. Run the app with Cmd+R.
4. Grant Accessibility when prompted.

The app is `LSUIElement=true`, so it appears in the menu bar instead of
the Dock. Click the sparkle icon to open settings.

## Accessibility permission

The MVP depends on macOS Accessibility APIs for three things:

- Finding the focused UI element.
- Reading text from inputs, textareas, contenteditable surfaces, and
  native text views when exposed by the target app.
- Intercepting Tab only while a suggestion is visible, then inserting the
  rewrite into the focused input.

`Fast AI` and `High Quality AI` also use ScreenCaptureKit to send a small
snapshot of the screen under the cursor to OpenAI when an API key is set.
If those modes keep falling back to local suggestions, enable Screen
Recording for the built app:

System Settings -> Privacy & Security -> Screen & System Audio Recording

If the prompt does not appear, open:

System Settings -> Privacy & Security -> Accessibility

Enable the built app, then relaunch it. The menu bar settings panel also
has buttons to request permission and open the correct settings page.

## Architecture

```text
Focused input
  -> AccessibilityTextReader
  -> PromptCoachController
  -> VaguePromptDetector
  -> SuggestionEngine
       - Local heuristic mode
       - Fast AI OpenAI provider
       - High quality OpenAI provider
       - GBrainMemoryStore
       - GStackGuidanceEngine
  -> FloatingSuggestionPanel
  -> SuggestionAcceptController
  -> focused input replacement or clipboard paste fallback
```

Main modules:

- `AppState`: shared observable state and user preferences.
- `AccessibilityTextReader`: focused element lookup, text reads, caret
  bounds, direct insertion, clipboard fallback.
- `MouseTracker`: current mouse location for panel fallback placement.
- `VaguePromptDetector`: fast local vagueness scoring.
- `LearningModel`: user levels, prompt evolution stages, gbrain-style
  memory, and gstack-style guidance types.
- `SuggestionEngine`: local rewrites plus OpenAI provider abstraction,
  adapted by user level and prompt evolution stage.
- `OpenAIScreenSuggestionProvider`: Responses API client that combines
  current input, language setting, frontmost app, optional screen image,
  learning level, stage, gbrain memory, and gstack guidance.
- `FloatingSuggestionPanel`: non-activating AppKit panel with SwiftUI UI.
- `SuggestionAcceptController`: global Tab accept and Esc dismiss handling.
- `MenuBarController`: status item and settings popover.
- `SettingsView`: minimal controls and permission affordances.

## Learning model

Where-to-vibe uses three levels:

- `Beginner`: reduce vague ideas into a first AI conversation and a small
  MVP.
- `Intermediate`: teach feature decomposition, architecture prompts,
  debugging prompts, and refactor boundaries.
- `Advanced`: explain AI limitations and transition complex work into
  filesystem-aware agent workflows.

Prompt evolution stages:

```text
Idea -> MVP -> Feature Spec -> Architecture Prompt -> Debugging Prompt -> Agent Workflow
```

The real-time coach can use the selected level and stage to shape the
same raw input differently. For example, `make a workout app` becomes a
small MVP for a Beginner, a feature spec for an Intermediate user, and an
agent workflow prompt if it involves multi-file architecture or deployment
concerns.

By default, the app runs in auto-detect mode:

- Short idea prompts become `Beginner + MVP`.
- Requirements, user stories, and roadmap language become
  `Intermediate + Spec`.
- Schema, API, Supabase, backend, and folder-structure language becomes
  `Intermediate + Architecture`.
- Bug, error, logs, and crash language becomes `Intermediate + Debug`.
- Deployment, websocket, realtime, Docker, Kubernetes, migrations,
  production, or multi-file language becomes `Advanced + Agent`.

## gbrain / gstack strategy

The MVP includes local adapter surfaces rather than pulling external
complexity into the Beginner UX:

- `GBrainMemoryStore`: remembers accepted prompt count and the latest
  accepted prompt, level, and stage. This is the seed for project memory,
  user preferences, prompt history, and long-term context.
- `GStackGuidanceEngine`: detects debugging, architecture, infrastructure,
  multi-file, and deployment complexity. This is the seed for senior
  engineering thinking and honest limitation warnings.

Future integration with MIT-licensed `gbrain` and `gstack` should happen
behind these adapters, so the UI remains calm and beginner-friendly.

## Performance model

- Poll focused text every 250 ms while enabled.
- Debounce input changes by 650 ms.
- Cancel stale debounce and suggestion tasks when the user keeps typing.
- Local mode stays entirely on-device.
- Fast AI and High Quality AI run only after debounce, only when the local
  detector or guidance layer says coaching is useful, and only when an
  OpenAI key is present.
- Stale debounce and request tasks are cancelled when the user keeps typing.
- Do not call an LLM on every keystroke.

Without an OpenAI key, `fastAI` and `highQualityAI` gracefully fall back to
local suggestions.

## How to plug in real LLM providers later

Implement `AIRefinementProvider` in `SuggestionEngine.swift`:

```swift
protocol AIRefinementProvider {
    func refine(
        text: String,
        signal: VaguePromptSignal,
        mode: SuggestionMode,
        language: PromptLanguage,
        apiKey: String
    ) async throws -> [PromptSuggestion]
}
```

Recommended behavior:

- Only call the provider when the local signal is vague enough.
- Cancel stale requests when the focused text changes.
- Use a 2-3 second timeout for Fast AI mode.
- Use High Quality AI only for longer pauses or explicit settings.
- For production, avoid storing raw keys in `UserDefaults`; use Keychain or
  route through a local or hosted proxy.

## Limitations

- Some apps expose focused text poorly through Accessibility. The
  clipboard paste fallback helps insertion, but reading still depends on
  what the target app exposes.
- Secure text fields are ignored by macOS and should not be coached.
- Contenteditable support varies by browser and site.
- Caret placement falls back to the mouse when the app does not expose
  `AXBoundsForRange`.
- The local detector is intentionally simple; it catches common vague
  prompts but does not understand full project context yet.
- API keys are stored in `UserDefaults` for MVP speed, not production-grade
  secret storage.

## Future improvements

- Per-app allowlist and denylist.
- Better contenteditable traversal for complex web editors.
- Inline ghost-text rendering where the target app exposes enough caret
  geometry.
- Provider-backed refinement with streaming updates.
- Expand gbrain memory into prompt history, project preferences, and
  repeated-mistake detection.
- Expand gstack guidance into architecture review, debugging playbooks,
  refactor strategy, and agent workflow recommendations.
- Optional project-context snippets for Cursor, Codex, and local repos.
- A small onboarding checklist that stays out of the main writing flow.
