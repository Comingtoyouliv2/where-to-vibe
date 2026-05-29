/**
 * Live-runs the scenarios in prompt-scenarios.md against a deployed worker.
 *
 *   export WORKER_URL=https://your-worker.workers.dev
 *   export SCENARIO_FIXTURES_DIR=tests/fixtures
 *   node tests/run-scenarios.mjs
 *
 * Each fixture in $SCENARIO_FIXTURES_DIR is a directory:
 *
 *   tests/fixtures/S1/
 *     ├── input.json         { userText, hints }
 *     ├── screen-primary.jpg
 *     └── expectations.json  { mustHaveFields, modeMustBe, ... }
 *
 * No fixtures? Run `node tests/parser-only.mjs` instead — that covers the
 * structural / Karpathy-rule surface without needing screenshots.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

const WORKER_URL = process.env.WORKER_URL;
const FIXTURES_DIR = process.env.SCENARIO_FIXTURES_DIR ?? "tests/fixtures";

if (!WORKER_URL) {
  console.error("set WORKER_URL=https://your-worker.workers.dev");
  process.exit(2);
}

let pass = 0;
let fail = 0;

async function loadFixture(dir) {
  const path = join(FIXTURES_DIR, dir);
  const input = JSON.parse(await readFile(join(path, "input.json"), "utf8"));
  const expectations = JSON.parse(
    await readFile(join(path, "expectations.json"), "utf8"),
  );
  const files = await readdir(path);
  const shots = await Promise.all(
    files
      .filter((f) => f.startsWith("screen-") && f.endsWith(".jpg"))
      .sort()
      .map(async (f) => ({
        base64: (await readFile(join(path, f))).toString("base64"),
        label: f.replace(/^screen-|\.jpg$/g, ""),
      })),
  );
  return { input, expectations, shots, name: dir };
}

function checkScenario(name, got, expectations) {
  const failures = [];

  if (expectations.modeMustBe && got.mode !== expectations.modeMustBe) {
    failures.push(`mode = ${got.mode}, expected ${expectations.modeMustBe}`);
  }

  for (const field of expectations.mustHaveNonNullFields ?? []) {
    if (got[field] === null || got[field] === undefined) {
      failures.push(`${field} is null/undefined`);
    }
  }

  for (const substr of expectations.nudgeMustInclude ?? []) {
    if (!got.nudge.toLowerCase().includes(substr.toLowerCase())) {
      failures.push(`nudge missing substring "${substr}"`);
    }
  }

  for (const substr of expectations.rewriteMustInclude ?? []) {
    if (!got.rewrite || !got.rewrite.includes(substr)) {
      failures.push(`rewrite missing substring "${substr}"`);
    }
  }

  for (const word of expectations.forbiddenWords ?? ["simply", "just ", "easy"]) {
    const blob = [got.nudge, got.rewrite ?? ""].join(" ").toLowerCase();
    if (blob.includes(word)) failures.push(`forbidden word "${word.trim()}" present`);
  }

  if (typeof expectations.maxChecks === "number" && got.checks.length > expectations.maxChecks) {
    failures.push(`checks=${got.checks.length}, max ${expectations.maxChecks}`);
  }
  if (typeof expectations.exactChecks === "number" && got.checks.length !== expectations.exactChecks) {
    failures.push(`checks=${got.checks.length}, expected exactly ${expectations.exactChecks}`);
  }

  if (failures.length === 0) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}`);
    for (const f of failures) console.log(`      - ${f}`);
  }
}

async function main() {
  let dirs;
  try {
    const entries = await readdir(FIXTURES_DIR);
    dirs = (
      await Promise.all(
        entries.map(async (e) => ((await stat(join(FIXTURES_DIR, e))).isDirectory() ? e : null)),
      )
    ).filter((x) => x !== null);
  } catch (err) {
    console.error(`no fixtures dir at ${FIXTURES_DIR} (${err.message})`);
    console.error("tip: run `node tests/parser-only.mjs` for parser-only checks");
    process.exit(2);
  }

  for (const dir of dirs) {
    const fx = await loadFixture(dir);
    const body = {
      screenshots: fx.shots,
      userText: fx.input.userText ?? null,
      hints: fx.input.hints ?? null,
      includeFewShots: true,
    };
    let got;
    try {
      const res = await fetch(`${WORKER_URL}/coach`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(`worker ${res.status}: ${await res.text()}`);
      got = await res.json();
    } catch (err) {
      fail++;
      console.log(`  ✗ ${fx.name} — network/worker error: ${err.message}`);
      continue;
    }
    checkScenario(fx.name, got, fx.expectations);
  }

  console.log(`\n=== ${pass} passed, ${fail} failed ===\n`);
  if (fail > 0) process.exit(1);
}

main();
