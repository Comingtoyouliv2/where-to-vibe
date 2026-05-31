/**
 * where-to-vibe — Cloudflare Worker
 *
 * Inherits Where-to-vibe's /chat, /tts, /transcribe-token proxies. Adds three new
 * routes that hold the where-to-vibe intelligence server-side:
 *
 *   POST /coach     — main coaching round-trip. Returns JSON {mode, nudge, ...}.
 *   POST /classify  — fast Haiku pre-classifier. Returns one word.
 *   POST /spec      — vague request → task spec only. Returns plain text spec.
 *
 * Why server-side? So future clients (browser extension, Electron, CLI) get
 * the same brain without re-implementing the prompts. Swift app stays a thin
 * client too — it just renders {mode, nudge, rewrite, point}.
 */

import {
  CLASSIFIER_SYSTEM,
  FEW_SHOTS,
  WHERE_TO_VIBE_SYSTEM,
  SPEC_REWRITE_SYSTEM,
} from "./prompts";
import {
  checkKarpathyRules,
  parseCoachResponse,
  type CoachResponse,
} from "./validators";
import {
  predictModeFromHints,
  type ClientHints,
  type Mode,
} from "./triggers";

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  COACH_MODEL: string;
  CLASSIFIER_MODEL: string;
}

interface CoachRequest {
  /** JPEG bytes of one or more screenshots, base64-encoded. First = primary. */
  screenshots: Array<{ base64: string; label?: string }>;
  /** Free-form context the client wants Claude to consider. */
  userText?: string | null;
  /** Hints from the client to short-circuit classification. */
  hints?: ClientHints | null;
  /** Conversation memory: previous (userText, assistantJSON) pairs. */
  history?: Array<{ userText: string; assistantJSON: string }>;
  /** When true, prepend FEW_SHOTS to the system prompt. */
  includeFewShots?: boolean;
}

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      switch (url.pathname) {
        // --- new where-to-vibe routes ---
        case "/coach":
          return await handleCoach(request, env);
        case "/coach-stream":
          return await handleCoachStream(request, env);
        case "/classify":
          return await handleClassify(request, env);
        case "/spec":
          return await handleSpec(request, env);

        // --- upstream routes kept for backward compat ---
        case "/chat":
          return await handleChat(request, env);
        case "/tts":
          return await handleTTS(request, env);
        case "/transcribe-token":
          return await handleTranscribeToken(env);

        default:
          return new Response("Not found", { status: 404 });
      }
    } catch (err) {
      console.error(`[${url.pathname}] unhandled`, err);
      return jsonResponse(500, { error: String(err) });
    }
  },
};

// ---------------------------------------------------------------------------
// /coach — main round-trip
// ---------------------------------------------------------------------------

async function handleCoach(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as CoachRequest;

  if (!Array.isArray(body.screenshots) || body.screenshots.length === 0) {
    return jsonResponse(400, { error: "screenshots[] required" });
  }

  // Build the Anthropic-format messages array.
  const messages = buildCoachMessages(body);
  const system = buildSystem(WHERE_TO_VIBE_SYSTEM, body.includeFewShots === true);

  // First pass. 768 tokens fits even the long vague_build_me responses
  // (korean rewrite spec + checks array ~600 tokens worst case). 384
  // truncated mid-checks-array in the wild, producing unparseable JSON.
  const firstCallStartedAt = Date.now();
  const first = await callClaude(env, {
    model: env.COACH_MODEL,
    system,
    messages,
    max_tokens: 768,
  });
  console.log(`[coach] first-pass model latency: ${Date.now() - firstCallStartedAt}ms`);

  let parsed = parseCoachResponse(first.text);

  // One repair attempt: if the model returned malformed JSON or missed a key,
  // re-ask with the specific missing fields. We bound retries to 1 to keep
  // latency predictable.
  if (!parsed.ok) {
    const missing = parsed.missing ?? ["entire JSON object"];
    const repairMessages = [
      ...messages,
      { role: "assistant" as const, content: first.text },
      {
        role: "user" as const,
        content: `your last reply was not valid. fix these: ${missing.join(
          ", ",
        )}. return ONLY the corrected JSON object, nothing else.`,
      },
    ];
    const second = await callClaude(env, {
      model: env.COACH_MODEL,
      system,
      messages: repairMessages,
      max_tokens: 768,
    });
    parsed = parseCoachResponse(second.text);
  }

  if (!parsed.ok || !parsed.value) {
    return jsonResponse(502, {
      error: "model returned unparseable response after repair",
      detail: parsed.rawError ?? parsed.missing,
      raw: first.text.slice(0, 2000),
    });
  }

  const warnings = checkKarpathyRules(parsed.value);
  if (warnings.length > 0) {
    // Don't fail — log so we can iterate on the prompt with real data.
    console.warn("[coach] karpathy-rule warnings", warnings);
  }

  return jsonResponse(200, {
    ...parsed.value,
    warnings,
  } satisfies CoachResponse & { warnings: string[] });
}

// ---------------------------------------------------------------------------
// /coach-stream — streaming variant of /coach
// ---------------------------------------------------------------------------
//
// The non-streaming /coach above buffers Claude's whole reply, parses + repairs
// JSON, then returns one shot. That makes the user wait the full ~3s before
// they see any text on screen. /coach-stream proxies Anthropic's native SSE
// stream straight through, so the Swift client can start showing characters
// of the `nudge` field as soon as the first tokens arrive (typically ~600ms
// for Sonnet TTFT).
//
// We forward Anthropic's events verbatim. The client is responsible for:
//   - parsing SSE frames (`event:` + `data:` lines)
//   - pulling text deltas out of `content_block_delta` events
//   - incrementally parsing the JSON to extract the `nudge` field for
//     immediate display, and later the `rewrite`, `mode`, etc.
//
// This is a no-validation path. If the model emits malformed JSON, the
// client falls back to displaying whatever raw text it has. The
// non-streaming /coach is still available for clients that prefer the
// safer round-trip with worker-side JSON repair.

async function handleCoachStream(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as CoachRequest;

  if (!Array.isArray(body.screenshots) || body.screenshots.length === 0) {
    return jsonResponse(400, { error: "screenshots[] required" });
  }

  const messages = buildCoachMessages(body);
  const system = buildSystem(WHERE_TO_VIBE_SYSTEM, body.includeFewShots === true);

  // Anthropic accepts `stream: true` and replies with SSE. We just need to
  // pass that response body through to the client unchanged.
  // max_tokens=768 — empirically 384 truncated vague_build_me responses
  // mid-checks-array because the rewrite spec alone is ~250 tokens in
  // korean. 768 gives the model headroom to finish the JSON.
  const upstreamResponse = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": ANTHROPIC_VERSION,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: env.COACH_MODEL,
      max_tokens: 768,
      system,
      messages,
      stream: true,
    }),
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[coach-stream] anthropic ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Stream Anthropic's SSE body straight through with the right headers
  // so URLSession on the client treats it as a streaming response and
  // delivers bytes incrementally rather than buffering to completion.
  return new Response(upstreamResponse.body, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      // CORS is permissive because this worker is the user's own proxy,
      // not a public service. Browser-extension clients (future) need it.
      "access-control-allow-origin": "*",
    },
  });
}

function buildCoachMessages(body: CoachRequest): AnthropicMessage[] {
  const history: AnthropicMessage[] = (body.history ?? []).flatMap((h) => [
    { role: "user", content: h.userText || "(no text)" },
    { role: "assistant", content: h.assistantJSON },
  ]);

  // Images go as content blocks on the latest user turn. Anthropic wants:
  //   [{type:"image",source:{...}}, {type:"text",text:"..."}]
  const imageBlocks = body.screenshots.map((s, i) => ({
    type: "image" as const,
    source: {
      type: "base64" as const,
      media_type: "image/jpeg" as const,
      data: s.base64,
    },
    // The cache_control hint helps when the same screenshot is reused
    // across a turn; harmless if ignored.
    cache_control: i === 0 ? ({ type: "ephemeral" } as const) : undefined,
  }));

  const labelLines = body.screenshots
    .map((s, i) => `image ${i + 1}${s.label ? ` (${s.label})` : ""}`)
    .join("\n");

  const hintsBlob = body.hints
    ? `client hints:\n${JSON.stringify(body.hints, null, 2)}\n\n`
    : "";

  const textBlock = {
    type: "text" as const,
    text:
      `${hintsBlob}screens attached:\n${labelLines}\n\n` +
      `user said:\n${body.userText ?? "(no text — proactively coach based on what you see)"}`,
  };

  return [
    ...history,
    {
      role: "user",
      content: [...imageBlocks, textBlock],
    },
  ];
}

function buildSystem(base: string, includeFewShots: boolean): string {
  if (!includeFewShots) return base;
  const examples = FEW_SHOTS.map(
    (ex, i) =>
      `## example ${i + 1}\n\nuser context:\n${ex.user}\n\nassistant:\n${ex.assistant}`,
  ).join("\n\n");
  return `${base}\n\n# examples\n\n${examples}`;
}

// ---------------------------------------------------------------------------
// /classify — Haiku one-word pre-classifier
// ---------------------------------------------------------------------------

interface ClassifyRequest {
  screenshots: Array<{ base64: string }>;
  hints?: ClientHints | null;
}

async function handleClassify(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as ClassifyRequest;

  // Cheap path: if hints alone are decisive, skip the model.
  const hinted = body.hints ? predictModeFromHints(body.hints) : null;
  if (hinted !== null) {
    return jsonResponse(200, { mode: hinted, source: "hints" });
  }

  if (!Array.isArray(body.screenshots) || body.screenshots.length === 0) {
    return jsonResponse(400, { error: "screenshots[] required" });
  }

  const messages: AnthropicMessage[] = [
    {
      role: "user",
      content: [
        ...body.screenshots.map((s) => ({
          type: "image" as const,
          source: {
            type: "base64" as const,
            media_type: "image/jpeg" as const,
            data: s.base64,
          },
        })),
        { type: "text" as const, text: "classify the screen." },
      ],
    },
  ];

  const result = await callClaude(env, {
    model: env.CLASSIFIER_MODEL,
    system: CLASSIFIER_SYSTEM,
    messages,
    max_tokens: 8,
  });

  const word = result.text.trim().toLowerCase().split(/\s+/)[0] ?? "none";
  const valid: ReadonlySet<Mode> = new Set([
    "prompt_coach",
    "vague_build_me",
    "empty_context_next_step",
    "error_first_cause",
    "diff_review",
    "none",
  ]);
  const mode = (valid.has(word as Mode) ? word : "none") as Mode;

  return jsonResponse(200, { mode, source: "model", raw: result.text });
}

// ---------------------------------------------------------------------------
// /spec — vague request → task spec only (plain text)
// ---------------------------------------------------------------------------

async function handleSpec(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as CoachRequest;

  if (!Array.isArray(body.screenshots) || body.screenshots.length === 0) {
    return jsonResponse(400, { error: "screenshots[] required" });
  }

  const messages = buildCoachMessages(body);
  const result = await callClaude(env, {
    model: env.COACH_MODEL,
    system: SPEC_REWRITE_SYSTEM,
    messages,
    max_tokens: 768,
  });

  return new Response(result.text, {
    status: 200,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

// ---------------------------------------------------------------------------
// /chat, /tts, /transcribe-token — kept from upstream Where-to-vibe for backward
// compatibility. The Swift app still uses these for the voice mode.
// ---------------------------------------------------------------------------

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const response = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": ANTHROPIC_VERSION,
      "content-type": "application/json",
    },
    body,
  });
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] anthropic ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type":
        response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    { method: "GET", headers: { authorization: env.ASSEMBLYAI_API_KEY } },
  );
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] assemblyai ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response(await response.text(), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;
  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    },
  );
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] elevenlabs ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response(response.body, {
    status: 200,
    headers: { "content-type": "audio/mpeg" },
  });
}

// ---------------------------------------------------------------------------
// Anthropic helper
// ---------------------------------------------------------------------------

type AnthropicTextBlock = { type: "text"; text: string };
type AnthropicImageBlock = {
  type: "image";
  source: { type: "base64"; media_type: "image/jpeg"; data: string };
  cache_control?: { type: "ephemeral" };
};
type AnthropicContentBlock = AnthropicTextBlock | AnthropicImageBlock;
type AnthropicMessage = {
  role: "user" | "assistant";
  content: string | AnthropicContentBlock[];
};

interface ClaudeCallArgs {
  model: string;
  system: string;
  messages: AnthropicMessage[];
  max_tokens: number;
}

interface ClaudeCallResult {
  text: string;
  stopReason: string | null;
}

async function callClaude(env: Env, args: ClaudeCallArgs): Promise<ClaudeCallResult> {
  const response = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": ANTHROPIC_VERSION,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: args.model,
      max_tokens: args.max_tokens,
      system: args.system,
      messages: args.messages,
    }),
  });

  if (!response.ok) {
    const errBody = await response.text();
    throw new Error(`anthropic ${response.status}: ${errBody}`);
  }

  const data = (await response.json()) as {
    content: Array<{ type: string; text?: string }>;
    stop_reason: string | null;
  };

  const text = data.content
    .filter((b) => b.type === "text")
    .map((b) => b.text ?? "")
    .join("");

  return { text, stopReason: data.stop_reason };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
