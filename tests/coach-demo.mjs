/**
 * Run the where-to-vibe coaching prompt directly against Anthropic, without
 * the Worker or the Swift app. Text-only scenarios — no screenshots needed.
 *
 *   export ANTHROPIC_API_KEY=sk-ant-...
 *   node tests/coach-demo.mjs            # runs all built-in scenarios
 *   node tests/coach-demo.mjs S1         # runs just one
 *   node tests/coach-demo.mjs --custom "user is typing 'fix it' in cursor with main.py open"
 *
 * What this proves:
 *   - the WHERE_TO_VIBE_SYSTEM prompt produces the JSON shape we expect
 *   - the validator parses and the Karpathy rules don't fire on good output
 *   - the model picks the right mode for each scenario
 *
 * What this does NOT prove:
 *   - vision pass works (no real screenshots; we pass text-only descriptions)
 *   - latency / streaming behaviour
 *   - end-to-end Swift overlay rendering
 *
 * Cost: each scenario is one Claude Sonnet call, ~1k input / ~300 output
 * tokens. Six scenarios = a few cents.
 */

import {
  WHERE_TO_VIBE_SYSTEM,
  FEW_SHOTS,
} from "../worker/src/prompts.ts";
import {
  parseCoachResponse,
  checkKarpathyRules,
} from "../worker/src/validators.ts";

const API_KEY = process.env.ANTHROPIC_API_KEY;
if (!API_KEY) {
  console.error("set ANTHROPIC_API_KEY=sk-ant-...");
  console.error("get one at https://console.anthropic.com");
  process.exit(2);
}

const MODEL = process.env.COACH_MODEL ?? "claude-sonnet-4-5-20250929";
// ^ if you have access to claude-sonnet-4-6 use that; sonnet-4-5 also works.

const SCENARIOS = {
  S1: {
    name: "Korean vague build-me",
    description: `the user is in Cursor. their chat input contains the text "버튼 만들어줘"
(nothing else, message unsent). the editor pane shows components/Header.tsx
which is a React + TypeScript file. it uses Tailwind utility classes, double
quotes for strings, and 2-space indentation. there's an existing Logo
component and a nav. no Button component exists yet.`,
    expect: {
      modeMustBe: "vague_build_me",
      rewriteMustInclude: ["GOAL:", "TOUCH:", "DONE WHEN:", "VERIFY BY:"],
    },
  },
  S2: {
    name: "Tight English prompt",
    description: `the user is in Cursor. their chat input contains:
"In src/auth/session.ts, replace the in-memory session store with a
Redis-backed one using the existing ioredis client from src/lib/redis.ts.
Keep the SessionStore interface unchanged. Done when all tests in
src/auth/__tests__ pass."
the editor shows src/auth/session.ts open.`,
    expect: {
      modeMustBe: "prompt_coach",
      rewriteShouldBeNull: true,
    },
  },
  S3: {
    name: "Python traceback",
    description: `the user is in iTerm2. the terminal shows this Python traceback:

  Traceback (most recent call last):
    File "tests/test_api.py", line 22, in test_login
      result = client.parse_response(response)
    File "api/client.py", line 84, in parse_response
      return raw[0]["user"]
  TypeError: 'NoneType' object is not subscriptable

no chat input visible. the user just ran pytest.`,
    expect: {
      modeMustBe: "error_first_cause",
      rewriteShouldBeNull: true,
      exactChecks: 1,
    },
  },
  S4: {
    name: "Mismatched PR scope",
    description: `the user has a GitHub PR open in their browser. PR title is
"fix: handle empty cart". the diff includes changes to three files:
- src/cart/checkout.ts (adds an empty-cart guard)
- src/cart/cart.ts (adds an isEmpty() helper)
- src/users/user-profile.tsx (REMOVES the try/catch around fetchProfile())
the user has not commented on the PR yet.`,
    expect: {
      modeMustBe: "diff_review",
      rewriteShouldBeNull: true,
      maxChecks: 3,
    },
  },
  S5: {
    name: "Idle reading",
    description: `the user is reading a long markdown design doc in their editor.
no chat input is open. no errors visible. just prose.`,
    expect: {
      modeMustBe: "none",
    },
  },
};

function buildSystem() {
  const examples = FEW_SHOTS.map(
    (ex, i) =>
      `## example ${i + 1}\n\nuser context:\n${ex.user}\n\nassistant:\n${ex.assistant}`,
  ).join("\n\n");
  return `${WHERE_TO_VIBE_SYSTEM}\n\n# examples\n\n${examples}`;
}

async function runScenario(key, sc) {
  const body = {
    model: MODEL,
    max_tokens: 1024,
    system: buildSystem(),
    messages: [
      {
        role: "user",
        content: [
          {
            type: "text",
            text: `[no real screenshot — described in text]\n\nscreen context:\n${sc.description}\n\nuser said:\n(nothing — coach proactively based on what's described above)`,
          },
        ],
      },
    ],
  };

  const t0 = Date.now();
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const dt = Date.now() - t0;

  if (!res.ok) {
    console.log(`✗ ${key} ${sc.name} — http ${res.status}`);
    console.log("  " + (await res.text()).slice(0, 400));
    return false;
  }

  const data = await res.json();
  const text = data.content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");

  const parsed = parseCoachResponse(text);
  if (!parsed.ok) {
    console.log(`✗ ${key} ${sc.name} — parse failed`);
    console.log("  missing:", parsed.missing ?? parsed.rawError);
    console.log("  raw:", text.slice(0, 400));
    return false;
  }

  const r = parsed.value;
  const warnings = checkKarpathyRules(r);
  const failures = [];

  if (sc.expect.modeMustBe && r.mode !== sc.expect.modeMustBe) {
    failures.push(`mode=${r.mode}, expected ${sc.expect.modeMustBe}`);
  }
  if (sc.expect.rewriteShouldBeNull && r.rewrite !== null) {
    failures.push(`rewrite should be null, got: ${(r.rewrite ?? "").slice(0, 80)}…`);
  }
  for (const sub of sc.expect.rewriteMustInclude ?? []) {
    if (!r.rewrite || !r.rewrite.includes(sub)) {
      failures.push(`rewrite missing "${sub}"`);
    }
  }
  if (typeof sc.expect.exactChecks === "number" && r.checks.length !== sc.expect.exactChecks) {
    failures.push(`checks=${r.checks.length}, expected ${sc.expect.exactChecks}`);
  }
  if (typeof sc.expect.maxChecks === "number" && r.checks.length > sc.expect.maxChecks) {
    failures.push(`checks=${r.checks.length}, max ${sc.expect.maxChecks}`);
  }

  const ok = failures.length === 0;
  console.log(`${ok ? "✓" : "✗"} ${key} ${sc.name}  (${dt}ms)`);
  console.log(`    mode: ${r.mode}`);
  console.log(`    nudge: ${r.nudge}`);
  if (r.rewrite) {
    console.log(`    rewrite:`);
    for (const line of r.rewrite.split("\n")) console.log(`      ${line}`);
  }
  if (r.checks.length > 0) {
    console.log(`    checks:`);
    for (const c of r.checks) console.log(`      - ${c}`);
  }
  if (r.assumptions.length > 0) {
    console.log(`    assumptions:`);
    for (const a of r.assumptions) console.log(`      - ${a}`);
  }
  if (warnings.length > 0) {
    console.log(`    ⚠ karpathy warnings: ${warnings.join("; ")}`);
  }
  for (const f of failures) console.log(`    ✗ ${f}`);
  console.log();
  return ok;
}

async function main() {
  const args = process.argv.slice(2);
  let scenariosToRun;

  if (args[0] === "--custom") {
    const desc = args.slice(1).join(" ");
    if (!desc) {
      console.error("usage: --custom 'describe what's on screen'");
      process.exit(2);
    }
    scenariosToRun = {
      custom: { name: "(custom)", description: desc, expect: {} },
    };
  } else if (args[0]) {
    if (!SCENARIOS[args[0]]) {
      console.error(`unknown scenario "${args[0]}". choose: ${Object.keys(SCENARIOS).join(", ")}`);
      process.exit(2);
    }
    scenariosToRun = { [args[0]]: SCENARIOS[args[0]] };
  } else {
    scenariosToRun = SCENARIOS;
  }

  console.log(`model: ${MODEL}\n`);
  let pass = 0;
  let fail = 0;
  for (const [key, sc] of Object.entries(scenariosToRun)) {
    const ok = await runScenario(key, sc);
    if (ok) pass++;
    else fail++;
  }
  console.log(`=== ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
