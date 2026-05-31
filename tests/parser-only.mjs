/**
 * Offline tests for the validator. No worker / no API key needed.
 *
 *   node tests/parser-only.mjs
 *
 * Exercises:
 *   - JSON parsing with and without ```json fences
 *   - Missing-field detection
 *   - checkKarpathyRules: forbidden words, diff_review finding cap,
 *     vague_build_me VERIFY BY requirement, error_first_cause single-check
 *     rule.
 */

import {
  parseCoachResponse,
  checkKarpathyRules,
} from "../worker/src/validators.ts";

let pass = 0;
let fail = 0;

function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

console.log("\n--- parser: clean JSON ---");
{
  const raw = JSON.stringify({
    mode: "prompt_coach",
    nudge: "looks tight, ship it.",
    rewrite: null,
    checks: ["pnpm test"],
    point: null,
    assumptions: [],
  });
  const r = parseCoachResponse(raw);
  check("ok", r.ok === true);
  check("mode", r.value?.mode === "prompt_coach");
}

console.log("\n--- parser: ```json fenced ---");
{
  const inner = JSON.stringify({
    mode: "none",
    nudge: "",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  const r = parseCoachResponse("```json\n" + inner + "\n```");
  check("ok despite fences", r.ok === true);
}

console.log("\n--- parser: leading prose ---");
{
  const inner = JSON.stringify({
    mode: "none",
    nudge: "",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  const r = parseCoachResponse("Sure! Here you go:\n" + inner);
  check("ok despite preamble", r.ok === true);
}

console.log("\n--- parser: missing fields ---");
{
  const r = parseCoachResponse(JSON.stringify({ mode: "prompt_coach" }));
  check("not ok", r.ok === false);
  check("missing reports nudge", (r.missing ?? []).includes("nudge"));
  check("missing reports checks", (r.missing ?? []).includes("checks"));
}

console.log("\n--- parser: bad mode ---");
{
  const r = parseCoachResponse(
    JSON.stringify({
      mode: "wat",
      nudge: "",
      rewrite: null,
      checks: [],
      point: null,
      assumptions: [],
    }),
  );
  check("not ok", r.ok === false);
  check("missing reports mode", (r.missing ?? []).includes("mode"));
}

console.log("\n--- parser: proactive empty-context mode ---");
{
  const r = parseCoachResponse(
    JSON.stringify({
      mode: "empty_context_next_step",
      nudge: "The editor is open with no prompt yet; start with this next question.",
      rewrite: "Review the visible file and suggest the smallest next implementation step.",
      checks: ["AI response names the visible file and one next action"],
      point: null,
      assumptions: [],
    }),
  );
  check("ok", r.ok === true);
  check("mode", r.value?.mode === "empty_context_next_step");
}

console.log("\n--- karpathy: forbidden words ---");
{
  const warnings = checkKarpathyRules({
    mode: "prompt_coach",
    nudge: "you can simply add it",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  check("flags 'simply'", warnings.some((w) => w.includes("simply")));
}

console.log("\n--- karpathy: vague_build_me missing VERIFY BY ---");
{
  const warnings = checkKarpathyRules({
    mode: "vague_build_me",
    nudge: "spec it",
    rewrite: "GOAL: add button\nTOUCH: Header.tsx\nDONE WHEN: button visible",
    checks: [],
    point: null,
    assumptions: [],
  });
  check("flags missing VERIFY BY", warnings.some((w) => w.includes("VERIFY BY")));
  check("does not flag DONE WHEN", !warnings.some((w) => w.includes("DONE WHEN")));
}

console.log("\n--- karpathy: error_first_cause check count ---");
{
  const tooMany = checkKarpathyRules({
    mode: "error_first_cause",
    nudge: "x",
    rewrite: null,
    checks: ["a", "b"],
    point: null,
    assumptions: [],
  });
  check("flags >1 check", tooMany.some((w) => w.includes("exactly 1")));

  const zero = checkKarpathyRules({
    mode: "error_first_cause",
    nudge: "x",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  check("flags 0 checks", zero.some((w) => w.includes("exactly 1")));
}

console.log("\n--- karpathy: empty_context_next_step requires rewrite ---");
{
  const warnings = checkKarpathyRules({
    mode: "empty_context_next_step",
    nudge: "start here",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  check("flags missing rewrite", warnings.some((w) => w.includes("paste-ready rewrite")));
  check("flags missing checks", warnings.some((w) => w.includes("at least 1 check")));
}

console.log("\n--- karpathy: diff_review finding cap ---");
{
  const ok = checkKarpathyRules({
    mode: "diff_review",
    nudge: "(1) one (2) two (3) three",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  check("3 findings ok", !ok.some((w) => w.includes("max 3")));

  const tooMany = checkKarpathyRules({
    mode: "diff_review",
    nudge: "(1) one (2) two (3) three (4) four",
    rewrite: null,
    checks: [],
    point: null,
    assumptions: [],
  });
  check("4 findings flagged", tooMany.some((w) => w.includes("max 3")));
}

console.log(`\n=== ${pass} passed, ${fail} failed ===\n`);
if (fail > 0) process.exit(1);
