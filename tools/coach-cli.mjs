#!/usr/bin/env node
/**
 * where-to-vibe — local CLI.
 *
 * Takes a screenshot of your Mac, sends it to Claude with the where-to-vibe
 * coaching prompt, and prints the nudge. No Cloudflare Worker, no Swift app,
 * no Xcode — just Node 18+, the macOS `screencapture` tool, and an Anthropic
 * API key.
 *
 *   export ANTHROPIC_API_KEY=sk-ant-...
 *   node tools/coach-cli.mjs
 *
 * Options:
 *   --delay N         wait N seconds before capturing (default 0)
 *   --display N       capture only display N (default: main display)
 *   --text "...."     also pass a text prompt (e.g. what you'd type to Cursor)
 *   --model NAME      override model (default claude-sonnet-4-5-20250929)
 *   --keep            don't delete the screenshot after; print its path
 *   --json            print the raw JSON response instead of pretty output
 *
 * Typical flow:
 *   1. open Cursor / Claude / ChatGPT
 *   2. type a prompt (do NOT press send)
 *   3. switch to your terminal
 *   4. run:  node tools/coach-cli.mjs --delay 3
 *   5. switch back to Cursor in those 3 seconds so the screenshot has it
 *   6. read the nudge
 *
 * The system prompt is duplicated here from PROMPTS.md so this CLI is fully
 * standalone. If you edit PROMPTS.md, edit the constant below to match.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, unlink, mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

const exec = promisify(execFile);

// ─── WHERE_TO_VIBE_SYSTEM (mirror of PROMPTS.md §1) ─────────────────────────

const WHERE_TO_VIBE_SYSTEM = `
you are a coding coach for a developer who is using an AI coding tool (cursor,
claude code, codex, chatgpt, or similar) or working in an editor / terminal.
you live next to their cursor as a small companion. you can see their screen.

your job is not to do the work. your job is to make the *next thing they send to
the AI* sharper, smaller, and more verifiable. every reply you send is short.
the user did not stop their flow to read an essay.

# how to decide what to do

first, classify what's on screen into ONE of these modes. if you're not sure,
pick the leftmost match:

  prompt_coach    — user is composing a message in an AI chat input
                    (cursor, claude.ai, chatgpt.com, claude code TUI, etc.)
                    AND that message is not yet sent.
  vague_build_me  — same as prompt_coach, but the message is imperative with no
                    nouns / files / done-criteria. examples: "make a button",
                    "fix it", "refactor this", "add auth", "만들어줘".
  error_first_cause — a terminal, test runner, browser console, or build log
                      is showing an error / stack trace / panic / failed test.
  diff_review     — a diff, PR, or \`git status\`/\`git diff\` output is visible.

if none match, respond with mode = "none" and a single line nudge of at most
12 words pointing at what *would* help.

# response format

ALWAYS return a single JSON object. no prose, no markdown fences, no preamble.
schema:

  {
    "mode": "prompt_coach" | "vague_build_me" | "error_first_cause"
            | "diff_review" | "none",
    "nudge": string,              // <= 2 sentences, plain text, what to do next
    "rewrite": string | null,     // a better version of the user's prompt, or null
    "checks": string[],           // 0–3 short bullets: how to verify success
    "point": [number, number, string] | null,  // pixel x,y in primary screenshot + 1–3 word label
    "assumptions": string[]       // explicit assumptions you made (empty array if none)
  }

# global rules (apply in every mode)

- write in the user's language. korean text → korean reply. english → english.
- never say "simply", "just", or "easy".
- never propose a refactor that wasn't requested. surgical changes only.
- never invent file names, function names, or libraries you cannot see on
  screen. if you need one, put it in \`assumptions\` and proceed.
- when proposing code, mirror the indentation, quote style, and naming visible
  in the screenshot.
- if a single piece of information would change your answer entirely, ask ONE
  clarifying question in \`nudge\`. otherwise proceed with assumptions.
- if you'd have to add a new file/class/abstraction, justify in \`nudge\` why
  it can't be inlined.

# mode playbooks

## prompt_coach
score the prompt on: goal, constraints, done criteria, verification. if 3 of 4
are present, return nudge = "looks tight, ship it." and rewrite = null.
otherwise, set \`rewrite\` to a strengthened version using ONLY facts visible
on screen. set \`checks\` to 1–3 verifiable steps. set \`nudge\` to one sentence
naming the weakest axis.

## vague_build_me
do NOT rewrite as chatty prose. rewrite as a task spec:

  GOAL: <one sentence outcome>
  TOUCH: <files/functions allowed to change — read from screen>
  DO NOT TOUCH: <surface the user clearly doesn't want changed>
  CONSTRAINTS: <lang/runtime/style — pulled from screen>
  DONE WHEN: <observable success>
  VERIFY BY: <command or inspection>
  ASSUMPTIONS I MADE: <list, or "none">

\`nudge\` is one sentence: "this is what I think you actually want — tab to
replace." \`checks\` mirrors \`VERIFY BY\`.

## error_first_cause
- locate the FIRST failing frame, not the last printed line.
- name the minimal reproducer in \`nudge\`: one command, one input.
- \`rewrite\` is null. \`checks\` contains exactly one item (the verify command).
- \`point\` to the line that contains the first useful clue.

## diff_review
- skip stylistic comments entirely.
- look for: missing tests, removed error handling, scope creep, regressions in
  callers, swallowed exceptions, security regressions.
- \`nudge\` lists at most 3 findings ranked by blast radius. one line each.
- \`rewrite\` is null. \`checks\` lists commands that would catch each finding.

# silence is fine
if the user is mid-typing and clearly knows what they're doing, return:
  { "mode": "none", "nudge": "", "rewrite": null, "checks": [],
    "point": null, "assumptions": [] }
`.trim();

// ─── arg parsing ──────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const opts = {
  delay: 0,
  display: null,
  text: null,
  model: process.env.COACH_MODEL ?? "claude-sonnet-4-5-20250929",
  keep: false,
  json: false,
};
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  switch (a) {
    case "--delay":     opts.delay   = Number(args[++i] ?? 0);   break;
    case "--display":   opts.display = Number(args[++i] ?? 1);   break;
    case "--text":      opts.text    = args[++i] ?? null;        break;
    case "--model":     opts.model   = args[++i] ?? opts.model;  break;
    case "--keep":      opts.keep    = true;                     break;
    case "--json":      opts.json    = true;                     break;
    case "-h":
    case "--help":
      console.log("see comment at top of tools/coach-cli.mjs");
      process.exit(0);
    default:
      console.error(`unknown arg: ${a}`);
      process.exit(2);
  }
}

const API_KEY = process.env.ANTHROPIC_API_KEY;
if (!API_KEY) {
  console.error("error: set ANTHROPIC_API_KEY=sk-ant-...");
  console.error("       get one at https://console.anthropic.com");
  process.exit(2);
}

if (process.platform !== "darwin") {
  console.error("error: this CLI uses macOS `screencapture`. on linux/windows,");
  console.error("       deploy the worker and POST to /coach with your own");
  console.error("       screenshot bytes instead.");
  process.exit(2);
}

// ─── main ─────────────────────────────────────────────────────────────────

const dir = await mkdtemp(join(tmpdir(), "coach-"));
const shotPath = join(dir, "screen.jpg");

if (opts.delay > 0) {
  process.stderr.write(`waiting ${opts.delay}s before capturing… `);
  for (let s = opts.delay; s > 0; s--) {
    process.stderr.write(`${s} `);
    await new Promise((r) => setTimeout(r, 1000));
  }
  process.stderr.write("\n");
}

const captureArgs = ["-x", "-t", "jpg"];
if (opts.display !== null) captureArgs.push("-D", String(opts.display));
captureArgs.push(shotPath);

try {
  await exec("screencapture", captureArgs);
} catch (err) {
  console.error("error: screencapture failed.", err.message);
  console.error("       on first run you'll be asked to grant Screen Recording");
  console.error("       permission. open System Settings → Privacy & Security →");
  console.error("       Screen Recording, enable Terminal (or your terminal app),");
  console.error("       and re-run.");
  process.exit(1);
}

const bytes = await readFile(shotPath);
if (!opts.keep) await unlink(shotPath).catch(() => {});
const base64 = bytes.toString("base64");

const userBlock = {
  type: "text",
  text:
    `screen attached: image 1 (primary display, jpeg)\n\n` +
    `user said:\n${opts.text ?? "(nothing — coach proactively based on what you see)"}`,
};

const body = {
  model: opts.model,
  max_tokens: 1024,
  system: WHERE_TO_VIBE_SYSTEM,
  messages: [
    {
      role: "user",
      content: [
        {
          type: "image",
          source: { type: "base64", media_type: "image/jpeg", data: base64 },
        },
        userBlock,
      ],
    },
  ],
};

process.stderr.write(`coach (${opts.model})… `);
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
process.stderr.write(`${dt}ms\n\n`);

if (!res.ok) {
  console.error(`anthropic ${res.status}:`, await res.text());
  process.exit(1);
}

const data = await res.json();
const text = data.content
  .filter((b) => b.type === "text")
  .map((b) => b.text)
  .join("");

if (opts.json) {
  console.log(text);
  if (opts.keep) console.error(`screenshot: ${shotPath}`);
  process.exit(0);
}

// pretty print
let parsed;
try {
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "");
  parsed = JSON.parse(cleaned);
} catch {
  console.log(text);
  if (opts.keep) console.error(`screenshot: ${shotPath}`);
  process.exit(0);
}

const c = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  cyan: "\x1b[36m",
  yellow: "\x1b[33m",
  green: "\x1b[32m",
  magenta: "\x1b[35m",
};

console.log(`${c.dim}mode${c.reset}  ${c.cyan}${parsed.mode}${c.reset}`);
console.log(`${c.dim}nudge${c.reset} ${c.bold}${parsed.nudge || "(silent)"}${c.reset}`);
if (parsed.rewrite) {
  console.log(`\n${c.dim}rewrite${c.reset}`);
  for (const line of parsed.rewrite.split("\n")) console.log(`  ${c.green}${line}${c.reset}`);
}
if (Array.isArray(parsed.checks) && parsed.checks.length > 0) {
  console.log(`\n${c.dim}checks${c.reset}`);
  for (const ch of parsed.checks) console.log(`  ${c.yellow}•${c.reset} ${ch}`);
}
if (Array.isArray(parsed.assumptions) && parsed.assumptions.length > 0) {
  console.log(`\n${c.dim}assumptions${c.reset}`);
  for (const a of parsed.assumptions) console.log(`  ${c.magenta}·${c.reset} ${a}`);
}
if (Array.isArray(parsed.point) && parsed.point.length === 3) {
  console.log(`\n${c.dim}point${c.reset} (${parsed.point[0]}, ${parsed.point[1]}) ${c.dim}${parsed.point[2]}${c.reset}`);
}
if (opts.keep) console.log(`\n${c.dim}screenshot${c.reset} ${shotPath}`);
