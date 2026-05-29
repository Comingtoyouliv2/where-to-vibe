# Security

## Reporting a vulnerability

If you find a security issue, please **do not** open a public GitHub
issue. Instead, email the maintainer (the address listed in the most
recent commit's `author`). Expect an acknowledgement within 72 hours.

## Threat model

This is a personal dev tool that runs on a single user's Mac and talks
to a single user's Cloudflare Worker. It does not authenticate users
(the worker is its own auth boundary — only you have the URL) and it
does not store anything persistently outside macOS UserDefaults.

The assets worth protecting are:

1. **Your Anthropic API key.** Anyone with this key can spend your
   API credits.
2. **The contents of your screen.** Every coaching round-trip uploads
   one JPEG of your active display to your worker → Anthropic. Treat
   the worker URL accordingly.

## How the codebase protects them

- API keys live **only** on the worker, as wrangler secrets, never in
  the macOS app binary. The app's `Info.plist` only contains the
  worker URL.
- `.gitignore` covers `Info.plist` and `worker/.dev.vars` (and their
  `.env*` siblings). Templates `Info.plist.example` and
  `.dev.vars.example` are committed instead so the repo is buildable
  by anyone with their own key.
- The cursor-overlay window is excluded from each screenshot via
  ScreenCaptureKit's `excludingWindows:` filter (matched by owning
  PID, not window title). The model never sees its own previous
  nudge.
- Screenshots are sent only when the frontmost app is on an explicit
  allow-list (Cursor / Claude / VS Code / terminals / known
  browsers — see `allowedAppBundleIDs` in `AutoCoachObserver.swift`).
  Outside that list, no capture happens.

## If you accidentally leak a key

1. Go to <https://console.anthropic.com/settings/keys> immediately.
2. Find the leaked key and click **Delete**.
3. Create a new key.
4. Update your local `.dev.vars` and, if the worker is deployed,
   `npx wrangler secret put ANTHROPIC_API_KEY` to push the new value.
5. If the leak was through a git commit, rewrite history with
   `git filter-repo` (or BFG) before pushing — but assume the key is
   already compromised and rotate first.

## Before pushing to GitHub

A pre-push checklist for this repo:

```bash
# Confirm no plaintext API keys anywhere tracked-or-untracked.
grep -rn "sk-ant-api" --include="*.swift" --include="*.plist" \
                     --include="*.ts" --include="*.toml" \
                     --include="*.json" --include="*.md" .

# Confirm Info.plist and .dev.vars are NOT staged.
git status --porcelain | grep -E '(Info\.plist$|\.dev\.vars$)' && \
  echo "STOP: secret file is staged" || echo "ok"

# Confirm the templates ARE present.
test -f macos-app/where-to-vibe/Info.plist.example && \
  test -f worker/.dev.vars.example && echo "ok"
```

All three should print `ok` (and no `sk-ant-api...` matches in tracked
files) before you `git push`.
</content>
