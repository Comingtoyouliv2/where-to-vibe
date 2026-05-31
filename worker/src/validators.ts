/**
 * Post-processing for Claude responses on the /coach route.
 *
 * The system prompt asks Claude to return a strict JSON object. Models
 * occasionally wrap it in ```json fences, prepend a sentence, or omit a
 * required key. This module is the last line of defence: parse, repair what
 * we can, reject what we can't.
 */

export type CoachMode =
  | "prompt_coach"
  | "vague_build_me"
  | "empty_context_next_step"
  | "error_first_cause"
  | "diff_review"
  | "none";

export interface CoachResponse {
  mode: CoachMode;
  nudge: string;
  rewrite: string | null;
  checks: string[];
  point: [number, number, string] | null;
  assumptions: string[];
}

const VALID_MODES: ReadonlySet<CoachMode> = new Set([
  "prompt_coach",
  "vague_build_me",
  "empty_context_next_step",
  "error_first_cause",
  "diff_review",
  "none",
]);

/**
 * Strip a leading/trailing ```json fence if present, and trim whitespace.
 * Models will sometimes return ```json\n{...}\n``` despite the system prompt
 * saying not to.
 */
function stripFences(raw: string): string {
  let s = raw.trim();
  if (s.startsWith("```")) {
    s = s.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "");
  }
  return s.trim();
}

/**
 * Try to extract the first JSON object from arbitrary text. Used as a fallback
 * when the model prepends a sentence like "Sure! Here you go:".
 */
function extractFirstJsonObject(s: string): string | null {
  const start = s.indexOf("{");
  if (start === -1) return null;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < s.length; i++) {
    const ch = s[i];
    if (esc) {
      esc = false;
      continue;
    }
    if (ch === "\\") {
      esc = true;
      continue;
    }
    if (ch === '"') {
      inStr = !inStr;
      continue;
    }
    if (inStr) continue;
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }
  return null;
}

export interface ParseResult {
  ok: boolean;
  value?: CoachResponse;
  /** Names of fields that were missing or malformed. */
  missing?: string[];
  /** Raw text we couldn't parse at all. */
  rawError?: string;
}

export function parseCoachResponse(raw: string): ParseResult {
  const stripped = stripFences(raw);
  const candidate = extractFirstJsonObject(stripped) ?? stripped;

  let obj: unknown;
  try {
    obj = JSON.parse(candidate);
  } catch (err) {
    return { ok: false, rawError: `JSON parse failed: ${String(err)}` };
  }

  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) {
    return { ok: false, rawError: "top-level value is not an object" };
  }

  const r = obj as Record<string, unknown>;
  const missing: string[] = [];

  const mode = r.mode;
  if (typeof mode !== "string" || !VALID_MODES.has(mode as CoachMode)) {
    missing.push("mode");
  }

  const nudge = r.nudge;
  if (typeof nudge !== "string") missing.push("nudge");

  const rewrite = r.rewrite;
  if (rewrite !== null && typeof rewrite !== "string") missing.push("rewrite");

  const checks = r.checks;
  if (!Array.isArray(checks) || !checks.every((c) => typeof c === "string")) {
    missing.push("checks");
  }

  const assumptions = r.assumptions;
  if (
    !Array.isArray(assumptions) ||
    !assumptions.every((a) => typeof a === "string")
  ) {
    missing.push("assumptions");
  }

  const point = r.point;
  const pointValid =
    point === null ||
    (Array.isArray(point) &&
      point.length === 3 &&
      typeof point[0] === "number" &&
      typeof point[1] === "number" &&
      typeof point[2] === "string");
  if (!pointValid) missing.push("point");

  if (missing.length > 0) return { ok: false, missing };

  return {
    ok: true,
    value: {
      mode: mode as CoachMode,
      nudge: nudge as string,
      rewrite: rewrite as string | null,
      checks: checks as string[],
      point: point as [number, number, string] | null,
      assumptions: assumptions as string[],
    },
  };
}

/**
 * Karpathy-rule enforcement on a parsed response. Returns a list of violations
 * (empty = pass). The worker doesn't auto-reject on violations; it logs them
 * and returns them as a `warnings` field, so we can tune the prompt with real
 * data instead of guessing.
 */
export function checkKarpathyRules(r: CoachResponse): string[] {
  const warnings: string[] = [];

  // Rule: error_first_cause must have exactly one check (the verify command).
  if (r.mode === "error_first_cause" && r.checks.length !== 1) {
    warnings.push(
      `error_first_cause should have exactly 1 check, got ${r.checks.length}`,
    );
  }

  // Rule: vague_build_me rewrite must contain VERIFY BY and DONE WHEN.
  if (r.mode === "vague_build_me" && r.rewrite) {
    if (!/VERIFY BY:/i.test(r.rewrite)) warnings.push("rewrite missing 'VERIFY BY:'");
    if (!/DONE WHEN:/i.test(r.rewrite)) warnings.push("rewrite missing 'DONE WHEN:'");
  }

  // Rule: proactive empty-context coaching is useful only if it gives the
  // user a paste-ready next prompt.
  if (r.mode === "empty_context_next_step") {
    if (!r.rewrite || r.rewrite.trim().length === 0) {
      warnings.push("empty_context_next_step should include a paste-ready rewrite");
    }
    if (r.checks.length === 0) {
      warnings.push("empty_context_next_step should include at least 1 check");
    }
  }

  // Rule: diff_review must have <= 3 findings (we measure by sentences in nudge).
  if (r.mode === "diff_review") {
    const findings = r.nudge.split(/\(\d\)/).filter((x) => x.trim().length > 0);
    if (findings.length > 3) {
      warnings.push(`diff_review nudge has ${findings.length} findings, max 3`);
    }
  }

  // Rule: forbidden words.
  const forbidden = ["simply", "just ", "easy"];
  const allText = [r.nudge, r.rewrite ?? ""].join(" ").toLowerCase();
  for (const word of forbidden) {
    if (allText.includes(word)) warnings.push(`uses forbidden word "${word.trim()}"`);
  }

  return warnings;
}
