import AppKit
import CoreGraphics
import Foundation

struct OpenAIScreenSuggestionProvider: AIRefinementProvider {
    private let responsesURL = URL(string: "https://api.openai.com/v1/responses")!

    func refine(
        text: String,
        signal: VaguePromptSignal,
        mode: SuggestionMode,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        guidance: GStackGuidance,
        memory: GBrainMemorySnapshot,
        apiKey: String
    ) async throws -> [PromptSuggestion] {
        try Task.checkCancellation()

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        let frontmostApp = await frontmostApplicationName()
        let screenDataURL = await captureCursorScreenDataURL()
        let prompt = requestPrompt(
            currentInput: text,
            signal: signal,
            mode: mode,
            language: language,
            userLevel: userLevel,
            stage: stage,
            guidance: guidance,
            memory: memory,
            frontmostApp: frontmostApp,
            hasScreenSnapshot: screenDataURL != nil
        )

        var content: [[String: Any]] = [
            [
                "type": "input_text",
                "text": prompt
            ]
        ]

        if let screenDataURL {
            content.append([
                "type": "input_image",
                "image_url": screenDataURL,
                "detail": mode == .fastAI ? "low" : "auto"
            ])
        }

        let body: [String: Any] = [
            "model": modelName(for: mode),
            "input": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
            "max_output_tokens": mode == .fastAI ? 260 : 420
        ]

        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = mode == .fastAI ? 8 : 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw NSError(
                domain: "OpenAIScreenSuggestionProvider",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let outputText = try extractOutputText(from: data)
        let payload = try parseSuggestionPayload(from: outputText)

        // The model is allowed to explicitly choose silence. Silence is a first-class
        // outcome of the onboarding philosophy: we don't want to train users that AI
        // always has something to say. Drop the suggestion entirely in that case.
        if payload.shouldSuggest == false || payload.intent == "stay_silent" {
            return []
        }

        let intent = parseSuggestionIntent(payload.intent)
        let mappedSuggestion = mapPayloadToSuggestion(
            payload: payload,
            intent: intent,
            language: language,
            userLevel: userLevel
        )

        guard let mappedSuggestion else { return [] }
        return [mappedSuggestion]
    }

    private func parseSuggestionIntent(_ raw: String?) -> SuggestionIntent {
        switch raw {
        case "tighten_draft": return .tightenDraft
        case "fill_missing_axis": return .fillMissingAxis
        case "ask_one_question": return .askOneQuestion
        case "point_at_wrong_tool": return .pointAtWrongTool
        case "graduate_to_agent": return .graduateToAgent
        case "stay_silent": return .staySilent
        default: return .tightenDraft
        }
    }

    // Map the model's intent-shaped payload to a PromptSuggestion the panel can render.
    // We intentionally keep the rendered text per intent narrow so it doesn't drift
    // back into a "fill the 4-field card" template — the whole point of the schema
    // change is that the *shape of the response itself* varies with the situation.
    private func mapPayloadToSuggestion(
        payload: OpenAISuggestionPayload,
        intent: SuggestionIntent,
        language: PromptLanguage,
        userLevel: UserLevel
    ) -> PromptSuggestion? {
        let isKorean = language == .korean
        // For Beginner only, attach a one-sentence "why this is a better prompt"
        // lesson if the model produced one. The intent here is to make the
        // learning loop visible without turning every card into a tutorial.
        let microLesson: String? = {
            guard userLevel == .beginner else { return nil }
            let trimmed = payload.microLesson?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
        let chips = payload.chips?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let reason = payload.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitleText = fallbackTitle(for: language)

        switch intent {
        case .staySilent:
            return nil

        case .tightenDraft, .fillMissingAxis:
            // Standard "here is a tighter prompt you can Tab-accept" path.
            // Accept either the new `rewrite` field or the legacy `suggestion` field
            // so an older prompt version still works during the transition.
            let rewriteSource = payload.rewrite ?? payload.suggestion
            guard let rewrite = rewriteSource?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rewrite.isEmpty else { return nil }
            return PromptSuggestion(
                title: title?.isEmpty == false ? title! : fallbackTitleText,
                text: rewrite,
                reason: reason,
                insertionMode: .replaceAll,
                chips: chips,
                intent: intent,
                microLesson: microLesson
            )

        case .askOneQuestion:
            // The model decided the cheapest next move is a single clarifying question.
            // We surface the question in `text` but do NOT make it a Tab-acceptable
            // rewrite — replacing the user's draft with a question would be hostile.
            guard let question = payload.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else { return nil }
            let renderedTitle = title?.isEmpty == false
                ? title!
                : (isKorean ? "하나만 물어볼게요" : "One quick question")
            return PromptSuggestion(
                title: renderedTitle,
                text: question,
                reason: reason,
                insertionMode: .replaceAll,
                chips: chips,
                intent: .askOneQuestion,
                microLesson: microLesson
            )

        case .pointAtWrongTool:
            // The user is in (say) ChatGPT but the task needs filesystem context.
            // We name the right tool and explain why, but we don't yet write the
            // graduation prompt for them — that's the `.graduateToAgent` intent.
            let tool = payload.tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let why = payload.why?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? reason
                ?? (isKorean ? "이 작업은 파일 맥락이 필요해요." : "This task needs filesystem context.")
            let renderedTitle = title?.isEmpty == false
                ? title!
                : (isKorean ? "도구를 바꾸는 게 좋아요" : "Try a different tool")
            let renderedText: String
            if tool.isEmpty {
                renderedText = why
            } else if isKorean {
                renderedText = "\(why)\n\n→ \(tool)에서 다시 시도해보세요."
            } else {
                renderedText = "\(why)\n\n→ Try this in \(tool) instead."
            }
            return PromptSuggestion(
                title: renderedTitle,
                text: renderedText,
                reason: reason,
                insertionMode: .replaceAll,
                chips: chips,
                intent: .pointAtWrongTool,
                microLesson: microLesson
            )

        case .graduateToAgent:
            // User is advanced enough that the right move is "stop using me, go use
            // OpenCode / Hermes / oh-my-openagent and here is the literal first
            // prompt to paste in there." This is the explicit graduation point of
            // the onboarding ladder.
            let tool = payload.tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let firstPrompt = payload.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let why = payload.why?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? reason
            let renderedTitle = title?.isEmpty == false
                ? title!
                : (isKorean ? "이제 agent로 넘어갈 때예요" : "Time to hand this to an agent")
            // If the model gave us a literal first prompt, surface it as the
            // Tab-acceptable text. Otherwise we just deliver the recommendation.
            let renderedText: String
            if !firstPrompt.isEmpty {
                renderedText = firstPrompt
            } else if !tool.isEmpty, let why, !why.isEmpty {
                renderedText = isKorean ? "\(why)\n\n→ \(tool)" : "\(why)\n\n→ \(tool)"
            } else if let why, !why.isEmpty {
                renderedText = why
            } else {
                return nil
            }
            return PromptSuggestion(
                title: renderedTitle,
                text: renderedText,
                reason: reason ?? why,
                insertionMode: .replaceAll,
                chips: chips,
                intent: .graduateToAgent,
                microLesson: microLesson
            )
        }
    }

    private func modelName(for mode: SuggestionMode) -> String {
        switch mode {
        case .localHeuristic:
            return "gpt-4.1-mini"
        case .fastAI:
            return "gpt-4.1-mini"
        case .highQualityAI:
            return "gpt-4.1"
        }
    }

    private func requestPrompt(
        currentInput: String,
        signal: VaguePromptSignal,
        mode: SuggestionMode,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        guidance: GStackGuidance,
        memory: GBrainMemorySnapshot,
        frontmostApp: String,
        hasScreenSnapshot: Bool
    ) -> String {
        let missingAxes = signal.missingAxes.joined(separator: ", ")
        let outputLanguage = language == .korean ? "Korean" : "English"
        let previousPrompt = memory.lastAcceptedPrompt ?? "none"
        let styleNote = language == .korean
            ? "한국어 형태소와 구어체를 잘 해석하라. '하고 싶어', '만들고 싶어', '고쳐줘', '뭘 해야 하지' 같은 표현을 의도 신호로 읽고, 한국어로 짧고 자연스럽게 말하라."
            : "Write in concise, natural English."
        let qualityNote: String
        if mode == .fastAI {
            qualityNote = "Prefer a fast, practical move over perfect completeness."
        } else if hasScreenSnapshot {
            qualityNote = "Use the visible screen carefully. Reuse concrete nouns from the screen so the move is unmistakably about THIS work, not a template."
        } else {
            qualityNote = "No screenshot is attached. Make the advice specific to the draft text and the current app instead of waiting for visual context."
        }
        let screenshotNote = hasScreenSnapshot
            ? "A screenshot is available. Use it for concrete nouns, but do not overfit to unrelated code or output."
            : "No screenshot is available. Do NOT require screen-specific nouns; coach from the draft, frontmost app, and local signals."

        // Level-specific hard constraints. The model is told what intents it is
        // allowed (and forbidden) to emit per level. This is what produces
        // qualitatively different shapes of advice as the user climbs the ladder.
        let levelPolicy = levelPolicyText(for: userLevel, language: language)

        return """
        You are Where-to-vibe. You sit beside the user's cursor inside \(frontmostApp) and
        help them write a slightly better next message to their AI coding tool.

        # Product philosophy (non-negotiable)
        - Your job is NOT to do the work for them. Your job is to teach them, over time,
          how to talk to AI coding agents.
        - Three rungs on the ladder: Beginner → Intermediate → Advanced. You graduate
          users off yourself. The right answer for an Advanced user is often "stop using
          me, go to OpenCode / Claude Code / Cursor / Hermes / oh-my-openagent, and here
          is the literal first prompt to paste."
        - Be honest about AI limits. Multi-file reasoning, deployment, infra, or repo
          context generally means chat-only AI will fail.
        - Silence is a valid answer only when the draft is already actionable.
          If the draft exists and local signals say it is vague or needs guidance, prefer
          one small coaching move over silence.

        # What you can see
        \(screenshotNote)
        User level: \(userLevel.displayName)
        Prompt evolution stage: \(stage.displayName)
        Prior accepted prompt count: \(memory.acceptedPromptCount)
        Last accepted prompt: \(previousPrompt)

        # The user's current draft (this is the thing to coach about)
        \(currentInput.isEmpty ? "(empty)" : currentInput)

        # Local signals (from a small on-device detector — may be wrong)
        Vagueness reason: \(signal.reason)
        Missing spec axes: \(missingAxes.isEmpty ? "unknown" : missingAxes)
        Guidance: \(guidance.reason ?? "none")
        Limitation note: \(guidance.limitationNote ?? "none")

        # Think before you respond (do NOT output this thinking)
        1) If a screenshot is attached, name up to 3 concrete nouns I could point at
           (a file name, a button label, an error string, a function name). If no
           screenshot is attached, skip this and use the draft text.
        2) What is the user's draft actually trying to do? Quote up to 10 words from
           it back to yourself.
        3) What is the SMALLEST move that would make their next AI message better?
           Possible moves:
             - tighten_draft     — they're close. Rewrite into a sharper version.
             - fill_missing_axis — one or two axes (goal / done-when / verify-by /
                                   constraints / target user) are missing. Add them.
             - ask_one_question  — you genuinely need one piece of info to coach well.
                                   Ask ONE question. Never a list.
             - point_at_wrong_tool — they're in the wrong app for this task (e.g.
                                   chat-only when they need filesystem context).
                                   Name the right tool.
             - graduate_to_agent — this user is ready to leave chat-only AI. Name
                                   OpenCode / Claude Code / Cursor / Hermes /
                                   oh-my-openagent and write the literal first prompt.
             - stay_silent       — use only when the draft is already concrete enough
                                   to send as-is AND local signals do not ask for coaching.
        4) Given the user level, is the chosen move ALLOWED by the level policy below?
           If not, pick a different move.

        # Level policy (HARD constraints — do not violate)
        \(levelPolicy)

        # Output contract
        Return ONLY one JSON object. No prose, no code fences.

        The JSON shape depends on the intent you chose. Always include `intent` and
        `shouldSuggest`. Include ONLY the payload fields listed for the chosen intent.

        Common envelope:
        {
          "shouldSuggest": true|false,
          "intent": "tighten_draft" | "fill_missing_axis" | "ask_one_question"
                  | "point_at_wrong_tool" | "graduate_to_agent" | "stay_silent",
          "confidence": 0.0-1.0,
          "title": "<=5 word label",
          "reason": "one short sentence naming the SPECIFIC weak axis or signal",
          "chips": ["concrete-axis", "concrete-axis"],
          "microLesson": "one sentence explaining WHY this is a better prompt"
        }

        Per-intent payload:
        - tighten_draft / fill_missing_axis →
            "rewrite": "the exact replacement prompt the user can Tab-accept"
        - ask_one_question →
            "question": "the single question to ask the user, in their language"
        - point_at_wrong_tool →
            "tool": "name of the better tool",
            "why":  "one sentence on why this tool fits this task"
        - graduate_to_agent →
            "tool": "OpenCode | Claude Code | Cursor | Hermes | oh-my-openagent",
            "why":  "one sentence on why chat-only AI will struggle here",
            "firstPrompt": "the LITERAL first prompt to paste into that tool"
        - stay_silent →
            (no extra fields; set shouldSuggest=false)

        # Style rules
        - Never produce more than one intent. Never include both `rewrite` and `question`.
        - Reuse at least 1 concrete noun/action from the draft or screenshot when available.
          If no concrete noun is available, ask one clarifying question. Do not choose
          stay_silent merely because no screenshot is attached.
        - Never invent file names, function names, or library names. Unknown → ask.
        - Do not say "simply", "just", "easy".
        - Keep it short enough for an inline panel beside the cursor.
        - \(styleNote)
        - \(qualityNote)

        Output language: \(outputLanguage)
        """
    }

    // Per-level hard constraints. We deliberately phrase these as ALLOWED / FORBIDDEN
    // intents (plus a couple of stylistic guardrails) rather than vague advice like
    // "reduce scope" — vague advice is what turned every previous answer into the
    // same shaped card.
    private func levelPolicyText(for level: UserLevel, language: PromptLanguage) -> String {
        let isKorean = language == .korean
        switch level {
        case .beginner:
            return isKorean
                ? """
                Beginner:
                - 허용 intents: tighten_draft, ask_one_question, stay_silent
                - 금지 intents: graduate_to_agent, point_at_wrong_tool
                - microLesson 반드시 포함. "이 한 줄을 추가하면 AI가 덜 헷갈려요" 같은 톤.
                - rewrite는 최대 3문장. 전문 용어를 쓰면 괄호로 짧게 풀어 설명.
                - 한 번에 한 가지만 가르친다. 여러 axis를 동시에 추가하지 마라.
                """
                : """
                Beginner:
                - allowed intents: tighten_draft, ask_one_question, stay_silent
                - forbidden intents: graduate_to_agent, point_at_wrong_tool
                - microLesson is REQUIRED. Tone: "adding this one line makes the AI less confused".
                - rewrite is at most 3 sentences. If you use jargon, define it inline in parentheses.
                - Teach exactly one thing at a time. Do NOT add multiple missing axes in one rewrite.
                """
        case .intermediate:
            return isKorean
                ? """
                Intermediate:
                - 허용 intents: tighten_draft, fill_missing_axis, ask_one_question, point_at_wrong_tool, stay_silent
                - 금지 intents: graduate_to_agent (아직 졸업시키지 마라)
                - microLesson은 유저의 draft에 명확한 오해(예: chat-only로 multi-file 리팩터링 시도)가 보일 때만 포함.
                - 2~3개 file/component를 넘는 작업이면 point_at_wrong_tool을 우선 고려하고 Cursor / Claude Code를 이름으로 명시.
                - acceptance criteria, non-goals, verify-by 같은 axis 이름을 reason에 명시적으로 적어라.
                """
                : """
                Intermediate:
                - allowed intents: tighten_draft, fill_missing_axis, ask_one_question, point_at_wrong_tool, stay_silent
                - forbidden intents: graduate_to_agent (do NOT graduate them yet)
                - Include microLesson ONLY if the draft shows a concrete misconception
                  (e.g. asking chat-only AI to refactor multiple files).
                - If the task spans >2 files or needs deployment, prefer point_at_wrong_tool
                  and NAME the right tool (Cursor / Claude Code) explicitly.
                - In `reason`, NAME the specific missing axis (acceptance criteria, non-goals,
                  verify-by, target user, etc.) instead of saying "be more specific".
                """
        case .advanced:
            return isKorean
                ? """
                Advanced:
                - 선호 intents: graduate_to_agent, stay_silent
                - 보조 intents: point_at_wrong_tool, fill_missing_axis (draft가 이미 단단하면 stay_silent)
                - microLesson은 포함하지 마라 (자존심 상함).
                - draft에 goal / done-when / verify-by / constraints 중 3개 이상이 이미 있으면 stay_silent.
                - graduate_to_agent를 고르면 OpenCode / Claude Code / Cursor / Hermes / oh-my-openagent 중 하나를 정확히 이름으로 지목하고, firstPrompt에는 그 도구에 그대로 붙여 넣을 한 문단을 작성.
                """
                : """
                Advanced:
                - preferred intents: graduate_to_agent, stay_silent
                - secondary intents: point_at_wrong_tool, fill_missing_axis (stay_silent if the draft is already tight)
                - Do NOT include microLesson — it reads as condescending.
                - If 3 of {goal, done-when, verify-by, constraints} are already in the draft, stay_silent.
                - When choosing graduate_to_agent, name exactly one of: OpenCode, Claude Code,
                  Cursor, Hermes, oh-my-openagent — and put the literal paste-ready first prompt
                  for that tool into `firstPrompt`.
                """
        }
    }

    @MainActor
    private func frontmostApplicationName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the current app"
    }

    @MainActor
    private func captureCursorScreenDataURL() async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            return nil
        }

        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let capture = captures.first(where: \.isCursorScreen) ?? captures.first
            guard let capture else { return nil }
            return "data:image/jpeg;base64,\(capture.imageData.base64EncodedString())"
        } catch {
            return nil
        }
    }

    private func extractOutputText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw parseError("Invalid OpenAI response")
        }

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let texts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { block in
                    if let text = block["text"] as? String {
                        return text
                    }
                    if let outputText = block["output_text"] as? String {
                        return outputText
                    }
                    return nil
                }
            }

            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return joined
            }
        }

        throw parseError("OpenAI response did not include output text")
    }

    private func parseSuggestionPayload(from text: String) throws -> OpenAISuggestionPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directData = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(OpenAISuggestionPayload.self, from: directData) {
            return payload
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            throw parseError("OpenAI output was not JSON")
        }

        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8) else {
            throw parseError("Could not decode OpenAI JSON text")
        }

        return try JSONDecoder().decode(OpenAISuggestionPayload.self, from: data)
    }

    private func fallbackTitle(for language: PromptLanguage) -> String {
        language == .korean ? "더 구체적으로 쓰기" : "Make it more concrete"
    }

    private func parseError(_ message: String) -> NSError {
        NSError(
            domain: "OpenAIScreenSuggestionProvider",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// The model's JSON response. The schema is intent-shaped: most fields are
// optional and which ones are populated depends on which `intent` the model
// chose. We keep legacy `suggestion` as a backstop in case an older prompt
// path returns the old card-shaped output; mapPayloadToSuggestion prefers
// `rewrite` and falls back to `suggestion`.
private struct OpenAISuggestionPayload: Decodable {
    // Envelope
    let shouldSuggest: Bool?
    let intent: String?
    let confidence: Double?
    let title: String?
    let reason: String?
    let chips: [String]?
    let microLesson: String?

    // Per-intent payload fields
    let rewrite: String?      // tighten_draft, fill_missing_axis
    let question: String?     // ask_one_question
    let tool: String?         // point_at_wrong_tool, graduate_to_agent
    let why: String?          // point_at_wrong_tool, graduate_to_agent
    let firstPrompt: String?  // graduate_to_agent

    // Legacy field (older prompt versions return this). Used as a last-resort
    // fallback for the tighten_draft / fill_missing_axis paths.
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case shouldSuggest
        case intent
        case confidence
        case title
        case reason
        case chips
        case microLesson
        case rewrite
        case question
        case tool
        case why
        case firstPrompt
        case suggestion
    }
}
