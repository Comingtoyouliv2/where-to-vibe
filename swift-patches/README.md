# Swift patches

> **STATUS: applied in `macos-app/`.** If you cloned this repo and
> ran nothing, the changes below are *already present* in the working
> tree under `macos-app/where-to-vibe/CompanionManager.swift`. You
> do not need to re-apply anything.
>
> This folder is kept as **reference** — so anyone forking upstream
> Where-to-vibe from scratch (a different commit, a different machine, a
> different fork point) can reproduce the same edits.

## What this patch changes

Exactly **one file**: `where-to-vibe/CompanionManager.swift`.

- Replace the body of the existing `companionVoiceResponseSystemPrompt`
  constant (around line 544) with the new coaching prompt.
- Add one new constant (`whereToVibeCoachUserPrefix`) directly below it.
- Change one argument in one call inside
  `sendTranscriptToClaudeWithScreenshot` (around line 679 in the modified
  file) so the prefix is prepended to the transcript before it goes to
  Claude.

No new files. No new dependencies. No Xcode target changes.

## Scope of this patch

This patch **only** swaps the system prompt — the running app still uses
upstream Where-to-vibe's existing overlay (blue-cursor point-and-fly + TTS) and
the push-to-talk flow. The new UI behaviour described in
`ARCHITECTURE.md` §4 — mouse-side speech bubble, 3–4 s idle auto-trigger,
7 s dismiss, nudge dedupe — is **not** in this patch. That's a separate
larger change (new Swift files for the bubble window, idle observer,
dedupe ring buffer, and a `/coach`-JSON client) and lives in its own
follow-up work.

## Reproducing the patch on a fresh upstream clone

You only need this if you're starting from scratch on a different upstream
checkout. To redo the same edits on our `macos-app/` tree, just run
`git restore` and start over.

1. Clone upstream:
   ```bash
   git clone https://github.com/Comingtoyouliv2/where-to-vibe.git
   cd where-to-vibe
   ```
2. Open `CompanionManager.systemPrompt.patch` in this folder for the
   exact text of §1, §2, §3.
3. Apply §1, §2, §3 in `where-to-vibe/CompanionManager.swift`. The patch
   file is a copy-paste guide, not a `git apply`-ready unified diff (see
   below for why).
4. Confirm with `swift -frontend -parse where-to-vibe/CompanionManager.swift`
   — no output means the syntax is clean.
5. Open `where-to-vibe.xcodeproj` in Xcode, set your signing team,
   Cmd+R.

## Why not a `git apply`-ready unified diff

Swift triple-quoted strings are whitespace-sensitive in ways that confuse
`patch` and `git apply` (a single tab→space conversion in transit will
make the diff fail to apply). A guided copy-paste form is safer for a
one-off fork-and-tweak. If upstream stops changing this file we may
freeze a real unified diff later.

## Verifying the patch is in effect

In `macos-app/where-to-vibe/CompanionManager.swift`:

```bash
grep -n 'coding coach for a developer\|whereToVibeCoachUserPrefix' \
  macos-app/where-to-vibe/CompanionManager.swift
```

You should see at least 3 matches — one inside the system prompt body,
two for the new constant (declaration + use site in
`sendTranscriptToClaudeWithScreenshot`).
