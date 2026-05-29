/**
 * Tiny heuristics that the client (Swift app or future browser/Electron
 * client) sends along with the screenshot. The classifier model gets the
 * final say; these hints just lower latency by pre-narrowing the choice.
 *
 * Everything here is best-effort — when in doubt, return null and let
 * Claude decide.
 */

export interface ClientHints {
  /** Front-most application bundle id, e.g. "com.todesktop.cursor". */
  frontAppBundleId?: string | null;
  /** Front-most application human name, e.g. "Cursor". */
  frontAppName?: string | null;
  /** URL host if front app is a browser and a URL is visible. */
  browserHost?: string | null;
  /** The text currently visible in the AI prompt input (if extractable). */
  draftPromptText?: string | null;
  /** "user pressed coach-me hotkey" vs "idle observer fired". */
  triggerSource?: "hotkey" | "idle" | "manual" | null;
}

const AI_CHAT_APP_NAMES = new Set([
  "Cursor",
  "Claude",
  "ChatGPT",
  "Codex",
  "Windsurf",
  "Zed",
  "Continue",
]);

const AI_CHAT_BROWSER_HOSTS = new Set([
  "claude.ai",
  "chatgpt.com",
  "chat.openai.com",
  "cursor.sh",
  "codex.openai.com",
]);

const TERMINAL_APP_NAMES = new Set([
  "Terminal",
  "iTerm2",
  "Warp",
  "Ghostty",
  "Alacritty",
  "Hyper",
  "Kitty",
  "WezTerm",
]);

const EDITOR_APP_NAMES = new Set([
  "Visual Studio Code",
  "VS Code",
  "Code",
  "Xcode",
  "Sublime Text",
  "Neovim",
  "MacVim",
  "Vim",
]);

const VAGUE_IMPERATIVE_PATTERNS: RegExp[] = [
  // English
  /^\s*(make|build|create|add|fix|refactor|clean|improve|update|change)\s+(it|this|that|something)?\s*[.!?]?\s*$/i,
  /^\s*(do|finish|implement)\s+(it|this|that)\s*[.!?]?\s*$/i,
  // Korean
  /^\s*만들어줘\s*[.!?]?\s*$/,
  /^\s*고쳐줘\s*[.!?]?\s*$/,
  /^\s*(다시\s*)?리팩터(링)?\s*해줘\s*[.!?]?\s*$/,
  /^\s*해줘\s*[.!?]?\s*$/,
];

/**
 * A "vague build me" looks like an imperative with no concrete nouns. We're
 * intentionally conservative — false negatives are fine (Claude will catch
 * them), false positives ("make a button that does X with Y") would annoy
 * the user.
 */
export function looksVague(text: string | null | undefined): boolean {
  if (!text) return false;
  const t = text.trim();
  if (t.length === 0) return false;
  if (t.length > 60) return false; // long prompts are almost never "vague"
  return VAGUE_IMPERATIVE_PATTERNS.some((re) => re.test(t));
}

export type Mode =
  | "prompt_coach"
  | "vague_build_me"
  | "error_first_cause"
  | "diff_review"
  | "none";

/**
 * Best-effort mode prediction from client hints alone, no model needed. Returns
 * null when we can't decide cheaply — caller should invoke /classify.
 */
export function predictModeFromHints(h: ClientHints): Mode | null {
  const app = h.frontAppName ?? "";
  const host = h.browserHost ?? "";

  const inAiChat =
    AI_CHAT_APP_NAMES.has(app) || AI_CHAT_BROWSER_HOSTS.has(host);

  if (inAiChat && h.draftPromptText !== undefined && h.draftPromptText !== null) {
    return looksVague(h.draftPromptText) ? "vague_build_me" : "prompt_coach";
  }

  // We can't reliably tell error vs diff vs editor from app name alone — a
  // terminal might be showing git log, a build log, or nothing. Defer to the
  // classifier model.
  if (TERMINAL_APP_NAMES.has(app)) return null;
  if (EDITOR_APP_NAMES.has(app)) return null;

  return null;
}
