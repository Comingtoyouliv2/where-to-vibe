# Prompt validation scenarios

Run these after any change to `PROMPTS.md` / `worker/src/prompts.ts`. Each
scenario is paired with the **must-have** signals in the response — if any of
those are missing, the prompt needs work.

The runner is `tests/run-scenarios.mjs` (Node 18+, no deps). It POSTs each
scenario to your deployed worker's `/coach` and checks the structural
signals. You set:

```
export WORKER_URL=https://your-worker.workers.dev
export SCENARIO_FIXTURES_DIR=tests/fixtures   # directory of .jpg screenshots
node tests/run-scenarios.mjs
```

If you don't have screenshots yet, you can run `tests/parser-only.mjs` which
exercises just the validator + Karpathy-rules checker on synthetic responses
— catches half the failure surface without any model calls.

## Scenarios

### S1 — Korean "make a button"

**Screen:** Cursor with `components/Header.tsx` open. Chat input contains
`버튼 만들어줘`.

**Expect:**
- `mode == "vague_build_me"`
- `rewrite` contains all of: `GOAL:`, `TOUCH:`, `DONE WHEN:`, `VERIFY BY:`
- `rewrite` mentions `Header.tsx` (taken from screen, not invented)
- `nudge` is in Korean
- `point` is non-null and labels the Cursor chat input

### S2 — English tight prompt

**Screen:** Cursor with `src/auth/session.ts`. Chat input contains:
`In src/auth/session.ts, replace the in-memory session store with a
Redis-backed one using the existing ioredis client from src/lib/redis.ts.
Keep the SessionStore interface unchanged. Done when all tests in
src/auth/__tests__ pass.`

**Expect:**
- `mode == "prompt_coach"`
- `rewrite == null` (it's already tight)
- `nudge` is one short sentence approving the prompt (some variant of "looks
  tight, ship it")
- `checks` contains the test command

### S3 — Python traceback

**Screen:** Terminal showing a `TypeError: 'NoneType' object is not
subscriptable` traceback. Top frame: `tests/test_api.py:22 test_login`.
Bottom frame: `api/client.py:84 parse_response`.

**Expect:**
- `mode == "error_first_cause"`
- `nudge` names `test_login` or `parse_response` (the *first cause*, not
  just the last line)
- `checks` has exactly **one** item that's a runnable command
- `rewrite == null`
- `point` targets the first useful line in the trace

### S4 — Mismatched PR

**Screen:** GitHub PR titled "fix: handle empty cart" but diff shows changes
in `checkout.ts`, `cart.ts`, and `user-profile.tsx`. The user-profile.tsx
change removes a `try/catch`.

**Expect:**
- `mode == "diff_review"`
- `nudge` mentions **scope creep** (user-profile.tsx vs PR title)
- `nudge` mentions the removed error handling
- ≤ 3 findings total
- No stylistic comments ("consider renaming", "extract", "could be
  cleaner" — all forbidden)
- `rewrite == null`

### S5 — Idle screen

**Screen:** User reading a long markdown doc, no prompt input visible.

**Expect:**
- `mode == "none"`
- `nudge` is the empty string
- All other fields are empty / null

### S6 — Refactor temptation

**Screen:** Error in test runner. Chat input contains: `the test is failing,
can you also refactor the whole module while you fix it?`

**Expect:**
- `mode == "prompt_coach"` (the message is a prompt)
- `rewrite` strips the refactor ask, or `nudge` pushes back: "fix first
  with the smallest possible change; refactor in a separate pass"
- `checks` contains the test command

### S7 — Forbidden words

Run any scenario, then grep the response for `simply|just |easy`. **Must be
zero hits.** This is in the Karpathy rule list — surface as a warning in
the parser if hit.

### S8 — Mid-typing should not interrupt

**Screen:** User is mid-typing a clearly thought-out prompt (the text shows
multiple file references, a constraint, and a verify step) but the cursor
is still in the input.

**Expect:**
- `mode == "prompt_coach"`
- `nudge` either approves it or, if still mid-sentence, returns `mode ==
  "none"` with empty nudge. The model has discretion here; what we're
  watching for is that it does **not** invent extra criteria the user
  didn't ask about.

## How to record a regression

When the model gives a bad output for one of these, save:

```
tests/fixtures/<scenario>-<date>.json
{
  "scenario": "S4",
  "input": { "screenshots": [...], "userText": "..." },
  "got": { "mode": "...", ... },
  "problem": "named all 6 findings instead of capping at 3"
}
```

Then add a tightening rule to `PROMPTS.md` and re-run. The validator's
`warnings` field already catches some of these; expand it when you find
new patterns.
