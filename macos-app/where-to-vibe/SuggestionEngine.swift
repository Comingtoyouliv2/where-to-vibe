import Foundation

enum SuggestionMode: String, CaseIterable, Identifiable {
    case localHeuristic
    case fastAI
    case highQualityAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localHeuristic: return "Local"
        case .fastAI: return "Fast AI"
        case .highQualityAI: return "High Quality AI"
        }
    }
}

// The shape of a single suggestion the panel can render.
//
// `intent` lets the model pick a form-factor instead of always producing the same
// "title + reason + suggestion + chips" card. Older code paths still create
// suggestions with the default `.tightenDraft` intent and that keeps rendering
// the existing card UI unchanged.
enum SuggestionIntent: String, Equatable {
    // The user's draft is roughly on the right track; we propose a tighter rewrite.
    case tightenDraft
    // The user's draft is missing one or two concrete axes (e.g. "done when", "target user").
    case fillMissingAxis
    // Best next move is a single clarifying question, not a rewrite.
    case askOneQuestion
    // The user is in a chat-only tool but the task wants a filesystem-aware agent.
    case pointAtWrongTool
    // The user is ready to leave this onboarding layer and use an advanced agent
    // workflow (OpenCode, Claude Code, Cursor, Hermes, oh-my-openagent, etc.).
    case graduateToAgent
    // Nothing actionable. Silence is the correct answer.
    case staySilent
}

struct PromptSuggestion: Identifiable, Equatable {
    let id: UUID
    let title: String
    let text: String
    let reason: String?
    let insertionMode: TextInsertionMode
    let chips: [String]
    // What kind of move this suggestion is. Drives both UI affordances (e.g. an
    // "ask one question" intent should not be Tab-acceptable as a rewrite) and
    // analytics on what coaching moves actually help users.
    let intent: SuggestionIntent
    // A short one-sentence lesson explaining WHY this is a better prompt.
    // Populated for Beginner users to make the onboarding learning loop explicit.
    // Nil for Intermediate / Advanced where the lesson would feel patronizing.
    let microLesson: String?

    var canAcceptWithTab: Bool {
        switch intent {
        case .tightenDraft, .fillMissingAxis, .graduateToAgent:
            return true
        case .askOneQuestion, .pointAtWrongTool, .staySilent:
            return false
        }
    }

    init(
        title: String,
        text: String,
        reason: String? = nil,
        insertionMode: TextInsertionMode,
        chips: [String],
        intent: SuggestionIntent = .tightenDraft,
        microLesson: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.text = text
        self.reason = reason
        self.insertionMode = insertionMode
        self.chips = chips
        self.intent = intent
        self.microLesson = microLesson
    }
}

protocol AIRefinementProvider {
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
    ) async throws -> [PromptSuggestion]
}

struct NoopAIRefinementProvider: AIRefinementProvider {
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
        return []
    }
}

struct SuggestionEngineResponse {
    let signal: VaguePromptSignal
    let suggestions: [PromptSuggestion]
    let debugMessage: String
}

final class SuggestionEngine {
    private let detector = VaguePromptDetector()
    private let guidanceEngine = GStackGuidanceEngine()
    private let memoryStore = GBrainMemoryStore.shared
    private let aiProvider: AIRefinementProvider

    init(aiProvider: AIRefinementProvider = NoopAIRefinementProvider()) {
        self.aiProvider = aiProvider
    }

    func suggestions(
        for text: String,
        mode: SuggestionMode,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        apiKey: String = "",
        forceCoach: Bool = false
    ) async -> SuggestionEngineResponse {
        let signal = detector.analyze(text, language: language)
        let guidance = guidanceEngine.assess(
            text: text,
            signal: signal,
            userLevel: userLevel,
            stage: stage,
            language: language
        )
        print("[Coach/Engine] analyze text(len=\(text.count)) mode=\(mode.rawValue) lang=\(language.rawValue) level=\(userLevel.rawValue) stage=\(stage.rawValue) → isVague=\(signal.isVague) score=\(String(format: "%.2f", signal.score)) missingAxes=\(signal.missingAxes) shouldCoach=\(guidance.shouldCoach) forceCoach=\(forceCoach)")
        guard forceCoach || signal.isVague || guidance.shouldCoach else {
            print("[Coach/Engine] GATE: draft looked specific enough (isVague=false, shouldCoach=false, forceCoach=false) → returning EMPTY. Either lower VaguePromptDetector threshold (currently 0.42) or type a vaguer prompt to test.")
            return SuggestionEngineResponse(
                signal: signal,
                suggestions: [],
                debugMessage: "No suggestion: draft looked specific enough"
            )
        }

        let memory = memoryStore.snapshot()

        // For the explicit Local mode, the user opted into template-based heuristics,
        // so we still produce them. For AI modes we deliberately do NOT fall back to
        // canned local templates anymore: the whole point of the redesign is that
        // every suggestion should feel written-for-this-moment, and a template card
        // appearing after an AI failure teaches users that the app always has
        // something to say. Silence on failure is more honest.
        if mode == .localHeuristic {
            let local = localSuggestions(
                for: text,
                signal: signal,
                guidance: guidance,
                memory: memory,
                language: language,
                userLevel: userLevel,
                stage: stage
            )
            print("[Coach/Engine] Local heuristic mode → returning \(local.count) suggestion(s).")
            return SuggestionEngineResponse(
                signal: signal,
                suggestions: local,
                debugMessage: "Local suggestion ready"
            )
        }

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No API key configured. We could show the local heuristic deck here, but
            // again that trains users that "something always shows up". Stay silent
            // instead — the settings UI is responsible for telling them the key is
            // missing.
            print("[Coach/Engine] GATE: mode=\(mode.rawValue) but OpenAI API key is empty → returning EMPTY. Set the key in the menu bar Settings, or switch SuggestionMode to .localHeuristic.")
            return SuggestionEngineResponse(
                signal: signal,
                suggestions: [],
                debugMessage: "No suggestion: OpenAI API key missing"
            )
        }

        do {
            let refined = try await aiProvider.refine(
                text: text,
                signal: signal,
                mode: mode,
                language: language,
                userLevel: userLevel,
                stage: stage,
                guidance: guidance,
                memory: memory,
                apiKey: apiKey
            )
            if refined.isEmpty {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && forceCoach {
                    print("[Coach/Engine] Proactive empty-context AI chose silence → staying silent instead of showing MVP fallback.")
                    return SuggestionEngineResponse(
                        signal: signal,
                        suggestions: [],
                        debugMessage: "AI chose silence for current screen"
                    )
                }
                let localFallback = localSuggestions(
                    for: text,
                    signal: signal,
                    guidance: guidance,
                    memory: memory,
                    language: language,
                    userLevel: userLevel,
                    stage: stage
                )
                print("[Coach/Engine] AI chose silence (stay_silent or empty rewrite) → falling back to \(localFallback.count) local suggestion(s).")
                return SuggestionEngineResponse(
                    signal: signal,
                    suggestions: localFallback,
                    debugMessage: "AI chose silence; local fallback shown"
                )
            }

            print("[Coach/Engine] AI mode=\(mode.rawValue) returned \(refined.count) suggestion(s).")
            return SuggestionEngineResponse(
                signal: signal,
                suggestions: refined,
                debugMessage: "\(mode.displayName) suggestion ready"
            )
        } catch {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && forceCoach {
                print("[Coach/Engine] Proactive empty-context AI request FAILED (\(error.localizedDescription)) → staying silent instead of showing MVP fallback.")
                return SuggestionEngineResponse(
                    signal: signal,
                    suggestions: [],
                    debugMessage: "Screen-aware idle suggestion failed: \(error.localizedDescription)"
                )
            }
            let localFallback = localSuggestions(
                for: text,
                signal: signal,
                guidance: guidance,
                memory: memory,
                language: language,
                userLevel: userLevel,
                stage: stage
            )
            print("[Coach/Engine] AI request FAILED (\(error.localizedDescription)) → falling back to \(localFallback.count) local suggestion(s).")
            return SuggestionEngineResponse(
                signal: signal,
                suggestions: localFallback,
                debugMessage: "AI failed; local fallback shown: \(error.localizedDescription)"
            )
        }
    }

    private func localSuggestions(
        for rawText: String,
        signal: VaguePromptSignal,
        guidance: GStackGuidance,
        memory: GBrainMemorySnapshot,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage
    ) -> [PromptSuggestion] {
        let context = PromptDraftContext(
            rawText: rawText,
            missingAxes: signal.missingAxes,
            guidance: guidance,
            memory: memory,
            language: language,
            userLevel: userLevel,
            stage: stage
        )

        return [
            context.primarySuggestion(),
            context.alternativeSuggestion()
        ]
    }
}

struct IdleNudgeComposer {
    func suggestion(
        for rawText: String,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        preferredAgentTool: AgentTool
    ) -> PromptSuggestion {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = text.isEmpty
        let isKorean = language == .korean

        if stage == .agentWorkflow || userLevel == .advanced {
            return PromptSuggestion(
                title: isKorean ? "agent에게 넘길 차례" : "Hand this to an agent",
                text: preferredAgentTool.transitionPrompt(task: text, language: language),
                reason: isKorean
                    ? "잠깐 멈춘 것 같아요. 이 작업은 agent workflow로 넘기기 좋습니다."
                    : "Looks like you paused. This may be ready for an agent workflow.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["agent", "context", "검증"] : ["agent", "context", "verify"]
            )
        }

        if isEmpty {
            return PromptSuggestion(
                title: isKorean ? "첫 문장부터 잡기" : "Start with one sentence",
                text: isKorean
                    ? "내가 만들고 싶은 것은 [제품/기능]입니다. 타겟 사용자는 [사용자]이고, 첫 번째 MVP는 [핵심 동작 1개]까지만 포함합니다. 이걸 더 구체적인 개발 프롬프트로 바꿔줘."
                    : "I want to build [product/feature] for [target user]. The first MVP should only include [one core behavior]. Turn this into a concrete development prompt.",
                reason: isKorean
                    ? "다음에 뭘 쓸지 막히면 목표, 사용자, 첫 MVP만 적어도 충분해요."
                    : "If you are stuck, start with the goal, user, and first MVP.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["목표", "사용자", "MVP"] : ["goal", "user", "MVP"]
            )
        }

        switch stage {
        case .idea:
            return PromptSuggestion(
                title: isKorean ? "아이디어를 MVP로 줄이기" : "Narrow the idea",
                text: isKorean
                    ? "다음 아이디어를 작은 MVP로 줄여줘: \(text)\n\n포함할 것: 타겟 사용자, 핵심 문제, 첫 사용 흐름 1개, 반드시 필요한 기능 3개, 나중으로 미룰 기능."
                    : "Narrow this idea into a small MVP: \(text)\n\nInclude: target user, core problem, one first workflow, 3 must-have features, and features to postpone.",
                reason: isKorean
                    ? "여기서는 기능을 더하기보다 범위를 줄이는 게 먼저예요."
                    : "At this point, narrowing the scope is more useful than adding features.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["MVP", "범위", "타겟"] : ["MVP", "scope", "target"]
            )

        case .mvp:
            return PromptSuggestion(
                title: isKorean ? "명세로 발전시키기" : "Turn it into a spec",
                text: isKorean
                    ? "이 MVP를 기능 명세로 발전시켜줘: \(text)\n\n화면/컴포넌트, 데이터 모델, 예외 케이스, 완료 기준, 구현 순서까지 정리해줘."
                    : "Turn this MVP into a feature spec: \(text)\n\nDefine screens/components, data model, edge cases, acceptance criteria, and implementation order.",
                reason: isKorean
                    ? "다음 채팅은 '무엇을 만들지'보다 '완료 기준'을 잡는 쪽이 좋아요."
                    : "The next useful move is to define what done means.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["명세", "완료 기준", "순서"] : ["spec", "criteria", "order"]
            )

        case .featureSpec:
            return PromptSuggestion(
                title: isKorean ? "구현 계획 요청하기" : "Ask for an implementation plan",
                text: isKorean
                    ? "이 기능 명세를 구현 계획으로 바꿔줘: \(text)\n\n폴더 구조, 컴포넌트/API 경계, 데이터 흐름, 가장 작은 첫 마일스톤, 테스트 방법을 제안해줘."
                    : "Turn this feature spec into an implementation plan: \(text)\n\nSuggest folder structure, component/API boundaries, data flow, the smallest first milestone, and test method.",
                reason: isKorean
                    ? "구현 전에 구조를 한 번 나누면 AI가 덜 엉킵니다."
                    : "Before implementation, splitting the structure helps the AI stay coherent.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["구조", "경계", "테스트"] : ["structure", "boundaries", "test"]
            )

        case .architecturePrompt:
            return PromptSuggestion(
                title: isKorean ? "작은 구현 단계로 나누기" : "Split into small edits",
                text: isKorean
                    ? "이 아키텍처 계획을 작은 구현 단계로 나눠줘: \(text)\n\n각 단계마다 변경 파일, 예상 리스크, 검증 방법을 포함해줘."
                    : "Split this architecture plan into small implementation steps: \(text)\n\nFor each step, include changed files, expected risk, and verification method.",
                reason: isKorean
                    ? "큰 구조 요청은 작은 변경 단위로 쪼개야 실패가 줄어듭니다."
                    : "Large architecture work is safer when it is broken into small edits.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["단계", "리스크", "검증"] : ["steps", "risk", "verify"]
            )

        case .debuggingPrompt:
            return PromptSuggestion(
                title: isKorean ? "디버깅 정보 채우기" : "Add debugging evidence",
                text: isKorean
                    ? "이 문제를 디버깅 가능한 요청으로 정리해줘: \(text)\n\n재현 방법, 현재 동작, 기대 동작, 에러 로그, 의심 파일, 가장 작은 안전한 수정, 검증 방법을 포함해줘."
                    : "Turn this into a debuggable request: \(text)\n\nInclude reproduction steps, actual behavior, expected behavior, error logs, suspected files, smallest safe fix, and verification method.",
                reason: isKorean
                    ? "디버깅은 증거가 있어야 AI가 원인을 덜 추측합니다."
                    : "Debugging works better when the AI has evidence instead of guesses.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["재현", "로그", "검증"] : ["repro", "logs", "verify"]
            )

        case .agentWorkflow:
            return PromptSuggestion(
                title: isKorean ? "agent에게 넘길 차례" : "Hand this to an agent",
                text: preferredAgentTool.transitionPrompt(task: text, language: language),
                reason: isKorean
                    ? "이 작업은 파일시스템 맥락을 읽는 agent가 더 잘 처리할 수 있어요."
                    : "This is a better fit for an agent that can read filesystem context.",
                insertionMode: .replaceAll,
                chips: isKorean ? ["agent", "파일", "검증"] : ["agent", "files", "verify"]
            )
        }
    }
}

private struct PromptDraftContext {
    let rawText: String
    let normalized: String
    let isKorean: Bool
    let intent: PromptIntent
    let subject: String
    let productKind: ProductKind
    let missingAxes: [String]
    let guidance: GStackGuidance
    let memory: GBrainMemorySnapshot
    let language: PromptLanguage
    let userLevel: UserLevel
    let stage: PromptEvolutionStage

    init(
        rawText: String,
        missingAxes: [String],
        guidance: GStackGuidance,
        memory: GBrainMemorySnapshot,
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage
    ) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawText = trimmed
        self.normalized = trimmed.lowercased()
        self.language = language
        self.userLevel = userLevel
        self.stage = stage
        self.isKorean = language == .korean
        self.intent = PromptIntent.detect(in: trimmed, language: language)
        self.productKind = ProductKind.detect(in: trimmed, language: language)
        self.subject = Self.extractSubject(from: trimmed, intent: intent, productKind: productKind, language: language)
        self.missingAxes = missingAxes
        self.guidance = guidance
        self.memory = memory
    }

    func primarySuggestion() -> PromptSuggestion {
        if guidance.requiresAgentWorkflow || stage == .agentWorkflow || userLevel == .advanced {
            return agentWorkflowSuggestion()
        }

        if isKorean {
            return PromptSuggestion(
                title: koreanTitle,
                text: koreanPrimaryText,
                reason: guidance.reason,
                insertionMode: .replaceAll,
                chips: chips
            )
        }

        return PromptSuggestion(
            title: englishTitle,
            text: englishPrimaryText,
            reason: guidance.reason,
            insertionMode: .replaceAll,
            chips: chips
        )
    }

    func alternativeSuggestion() -> PromptSuggestion {
        if guidance.requiresAgentWorkflow || stage == .agentWorkflow || userLevel == .advanced {
            return agentWorkflowAlternative()
        }

        if isKorean {
            return PromptSuggestion(
                title: "검증 가능하게 좁히기",
                text: "\(subject)을 작은 첫 단계로 바꿔줘. 반드시 포함할 것: 대상 사용자, 핵심 동작 1개, 하지 않을 범위, 제약 조건, 완료 기준, 직접 확인할 테스트 방법.",
                reason: guidance.reason,
                insertionMode: .replaceAll,
                chips: ["MVP", "범위", "검증"]
            )
        }

        return PromptSuggestion(
            title: "Constrain the first step",
            text: "Turn \(subjectArticle) into one small, verifiable first step. Include the target user, the single core behavior, non-goals, constraints, acceptance criteria, and how I should test it.",
            reason: guidance.reason,
            insertionMode: .replaceAll,
            chips: ["scope", "non-goals", "verify"]
        )
    }

    private var englishTitle: String {
        if let stageTitle = englishStageTitle {
            return stageTitle
        }

        switch intent {
        case .fix: return "Add debugging context"
        case .improve: return "Define the improvement"
        case .write: return "Specify the output"
        case .explain: return "Ask for usable explanation"
        case .build: return "Make the build request concrete"
        case .unknown: return "Make it executable"
        }
    }

    private var koreanTitle: String {
        if let stageTitle = koreanStageTitle {
            return stageTitle
        }

        switch intent {
        case .fix: return "버그 맥락 추가하기"
        case .improve: return "개선 기준 정하기"
        case .write: return "결과물 형태 정하기"
        case .explain: return "설명 목적 정하기"
        case .build: return "만들 요청 구체화하기"
        case .unknown: return "실행 가능한 요청으로 바꾸기"
        }
    }

    private var englishPrimaryText: String {
        if stage == .architecturePrompt {
            return "Ask for an architecture plan for \(subjectArticle). Include the folder structure, data model, API or component boundaries, state management, tradeoffs, non-goals, and the first implementation milestone."
        }

        if stage == .debuggingPrompt {
            return "Debug \(subjectArticle). Include reproduction steps, actual vs expected behavior, logs or screenshots, suspected files, the smallest safe fix, and a regression test or manual verification step."
        }

        if stage == .mvp || userLevel == .beginner {
            return "Turn \(subjectArticle) into a beginner-friendly MVP. Define the target user, one core workflow, the 3 must-have features, what to postpone, and the exact first prompt I should send to an AI coding tool."
        }

        if stage == .featureSpec || userLevel == .intermediate {
            return "Write a feature spec for \(subjectArticle). Include the target user, user stories, data model, API or component boundaries, edge cases, non-goals, acceptance criteria, and an implementation roadmap."
        }

        switch intent {
        case .fix:
            return "Debug \(subjectArticle). Reproduce the issue, compare actual vs expected behavior, identify the root cause, make the smallest safe fix, and add a regression test. Avoid unrelated refactors and explain how to verify the fix."
        case .improve:
            return "Improve \(subjectArticle) for a specific user and outcome. Describe the current problem, the desired behavior, constraints, success metrics, and the smallest change that would prove the improvement works."
        case .write:
            return "Write \(subjectArticle) for a clearly defined audience. Include the purpose, tone, required structure, constraints, examples to follow or avoid, and the criteria for a good final answer."
        case .explain:
            return "Explain \(subjectArticle) for someone with a specific background. Start with the mental model, show one concrete example, call out common mistakes, and end with a quick way to check understanding."
        case .build, .unknown:
            return "Build \(subjectArticle) for a defined target user. Include the core workflow, must-have behavior, constraints, visual or technical direction, non-goals, acceptance criteria, and verification steps."
        }
    }

    private var koreanPrimaryText: String {
        if stage == .architecturePrompt {
            return "\(subject)의 아키텍처 계획을 먼저 세워줘. 폴더 구조, 데이터 모델, API 또는 컴포넌트 경계, 상태 관리, 트레이드오프, 하지 않을 범위, 첫 구현 마일스톤을 포함해줘.\(koreanDomainFocus)"
        }

        if stage == .debuggingPrompt {
            return "\(subject)을 디버깅해줘. 재현 방법, 현재 동작과 기대 동작, 로그나 스크린샷, 의심되는 파일, 가장 작은 안전한 수정, 회귀 테스트 또는 수동 검증 방법을 포함해줘.\(koreanDomainFocus)"
        }

        if stage == .mvp || userLevel == .beginner {
            return "\(subject)을 초보자 친화적인 MVP로 줄여줘. 타겟 사용자, 핵심 사용 흐름 1개, 반드시 필요한 기능 3개, 나중으로 미룰 것, AI 코딩 도구에 보낼 첫 프롬프트를 포함해줘.\(koreanDomainFocus)"
        }

        if stage == .featureSpec || userLevel == .intermediate {
            return "\(subject)의 기능 명세를 작성해줘. 타겟 사용자, 사용자 시나리오, 데이터 모델, API 또는 컴포넌트 경계, 예외 케이스, 하지 않을 범위, 완료 기준, 구현 로드맵을 포함해줘.\(koreanDomainFocus)"
        }

        switch intent {
        case .fix:
            return "\(subject)을 디버깅해줘. 현재 동작과 기대 동작을 비교하고, 재현 방법, 원인, 가장 작은 수정, 회귀 테스트, 확인 방법을 포함해줘. 관련 없는 리팩터링은 하지 마."
        case .improve:
            return "\(subject)을 특정 사용자와 목표 기준에 맞게 개선해줘. 현재 문제, 원하는 동작, 제약 조건, 성공 기준, 가장 작은 변경 범위, 확인 방법을 포함해줘."
        case .write:
            return "\(subject)을 작성해줘. 대상 독자, 목적, 톤, 필수 구조, 포함할 내용, 피해야 할 내용, 좋은 결과물의 기준을 먼저 반영해줘."
        case .explain:
            return "\(subject)을 설명해줘. 대상자의 배경을 가정하고, 핵심 모델, 구체적 예시 1개, 자주 하는 실수, 이해 확인 질문까지 포함해줘."
        case .build, .unknown:
            return "\(subject)을 만들어줘. 타겟 사용자, 핵심 사용 흐름, 반드시 필요한 기능, 기술/디자인 제약, 하지 않을 범위, 완료 기준, 검증 방법을 포함해서 MVP 기준으로 구현해줘.\(koreanDomainFocus)"
        }
    }

    private var koreanDomainFocus: String {
        let focus: String?
        if containsAny(normalized, ["운동", "헬스", "러닝", "식단", "루틴"]) {
            focus = " 운동 기록, 루틴 반복, 진행률 확인 중 무엇이 첫 사용 순간인지도 정해줘."
        } else if containsAny(normalized, ["주식", "코인", "투자", "가격", "차트"]) {
            focus = " 관심 종목, 가격 표시, 알림, 차트 중 첫 MVP에 넣을 것과 미룰 것을 나눠줘."
        } else if containsAny(normalized, ["채팅", "메시지", "실시간", "웹소켓"]) {
            focus = " 메시지 전송 흐름, 읽음 상태, 실시간 동기화, 실패 처리 범위를 나눠줘."
        } else if containsAny(normalized, ["ai", "프롬프트", "agent", "에이전트", "코치"]) {
            focus = " 유저 입력 맥락, 조언 타이밍, accept UX, AI 한계를 어떻게 보여줄지도 정해줘."
        } else if containsAny(normalized, ["디자인", "ui", "ux", "화면", "랜딩"]) {
            focus = " 화면 상태, 시각 스타일, 인터랙션, 모바일/데스크톱 제약을 구체화해줘."
        } else {
            focus = nil
        }
        return focus ?? ""
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private var subjectArticle: String {
        let lowered = subject.lowercased()
        if lowered.hasPrefix("the ") || lowered.hasPrefix("a ") || lowered.hasPrefix("an ") || lowered.hasPrefix("this ") {
            return subject
        }
        let first = lowered.first ?? "t"
        let article = ["a", "e", "i", "o", "u"].contains(String(first)) ? "an" : "a"
        return "\(article) \(subject)"
    }

    private var chips: [String] {
        let inferred: [String]
        if guidance.requiresAgentWorkflow {
            inferred = guidance.chips
        } else if stage == .mvp || userLevel == .beginner {
            inferred = language == .korean ? ["MVP", "타겟", "첫 프롬프트"] : ["MVP", "target", "first prompt"]
        } else if stage == .featureSpec || userLevel == .intermediate {
            inferred = language == .korean ? ["명세", "구조", "로드맵"] : ["spec", "structure", "roadmap"]
        } else {
            switch intent {
        case .fix: inferred = ["expected", "root cause", "test"]
        case .improve: inferred = ["metric", "constraint", "before/after"]
        case .write: inferred = ["audience", "tone", "structure"]
        case .explain: inferred = ["audience", "example", "check"]
        case .build, .unknown:
            inferred = productKind == .unknown
                ? ["goal", "user", "verify"]
                : [productKind.displayName, "user", "verify"]
            }
        }
        let combined = inferred + guidance.chips + missingAxes
        return Array(NSOrderedSet(array: combined)) as? [String] ?? inferred
    }

    private var englishStageTitle: String? {
        switch stage {
        case .idea: return nil
        case .mvp: return "Shrink it into an MVP"
        case .featureSpec: return "Turn it into a feature spec"
        case .architecturePrompt: return "Ask for architecture first"
        case .debuggingPrompt: return "Make it debuggable"
        case .agentWorkflow: return "Move this into an agent workflow"
        }
    }

    private var koreanStageTitle: String? {
        switch stage {
        case .idea: return nil
        case .mvp: return "MVP로 줄이기"
        case .featureSpec: return "기능 명세로 바꾸기"
        case .architecturePrompt: return "구조 먼저 잡기"
        case .debuggingPrompt: return "디버깅 가능하게 만들기"
        case .agentWorkflow: return "Agent workflow로 넘기기"
        }
    }

    private func agentWorkflowSuggestion() -> PromptSuggestion {
        if isKorean {
            return PromptSuggestion(
                title: "Agent workflow로 전환",
                text: "현재 요청은 multi-file 구조나 배포/인프라 맥락이 필요할 수 있어요. Claude Code, Cursor, OpenCode 같은 filesystem-aware agent에서 진행해줘. 먼저 목표, 관련 파일/폴더, 실행 방법, 실패 로그, 제약 조건, 완료 기준을 확인하고, 작은 단계로 계획을 세운 뒤 변경해줘.",
                reason: guidance.reason,
                insertionMode: .replaceAll,
                chips: chips
            )
        }

        return PromptSuggestion(
            title: "Move into an agent workflow",
            text: "This task may need multi-file context or deployment/infrastructure awareness. Use a filesystem-aware agent such as Claude Code, Cursor, or OpenCode. First inspect the goal, relevant files, run commands, failure logs, constraints, and acceptance criteria, then plan small changes before editing.",
            reason: guidance.reason,
            insertionMode: .replaceAll,
            chips: chips
        )
    }

    private func agentWorkflowAlternative() -> PromptSuggestion {
        if isKorean {
            return PromptSuggestion(
                title: "한계 설명 포함하기",
                text: "이 요청은 chat-only 환경에서 context window와 multi-file reasoning 한계 때문에 실패할 수 있어요. 먼저 프로젝트 구조와 관련 파일을 읽고, 변경 범위를 제안한 뒤, 테스트 가능한 가장 작은 수정부터 진행해줘.",
                reason: guidance.limitationNote,
                insertionMode: .replaceAll,
                chips: ["한계", "파일", "검증"]
            )
        }

        return PromptSuggestion(
            title: "Name the limitation",
            text: "This may fail in a chat-only workflow because the agent needs repository context and multi-file reasoning. First inspect the project structure and relevant files, propose the smallest safe change, then implement it with a verification step.",
            reason: guidance.limitationNote,
            insertionMode: .replaceAll,
            chips: ["limits", "files", "verify"]
        )
    }

    private static func extractSubject(
        from text: String,
        intent: PromptIntent,
        productKind: ProductKind,
        language: PromptLanguage
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanupPatterns = [
            #"^(please\s+)?"#,
            #"^(can you\s+)?"#,
            #"^(make|build|create|fix|debug|improve|update|change|optimize|refactor|write|generate|explain|help)\s+"#,
            #"(해줘|해주세요|만들어줘|고쳐줘|수정해줘|개선해줘)$"#
        ]

        var subject = trimmed
        for pattern in cleanupPatterns {
            subject = subject.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        subject = subject.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        if subject.isEmpty {
            if language == .korean {
                switch intent {
                case .fix: return "이 문제"
                case .improve: return "이 흐름"
                case .write: return "요청한 초안"
                case .explain: return "이 개념"
                case .build, .unknown: return productKind.koreanDefaultSubject
                }
            }

            switch intent {
            case .fix: return "this issue"
            case .improve: return "this workflow"
            case .write: return "the requested draft"
            case .explain: return "this concept"
            case .build, .unknown: return productKind.defaultSubject
            }
        }

        return subject
    }
}

private enum PromptIntent {
    case build
    case fix
    case improve
    case write
    case explain
    case unknown

    static func detect(in text: String, language: PromptLanguage) -> PromptIntent {
        let normalized = text.lowercased()
        let fixTerms = language == .english
            ? ["fix", "debug", "bug", "error", "crash"]
            : ["고쳐", "수정", "버그", "에러"]
        let improveTerms = language == .english
            ? ["improve", "optimize", "refactor", "better"]
            : ["개선", "최적화", "리팩터"]
        let writeTerms = language == .english
            ? ["write", "draft", "email", "copy"]
            : ["문서", "글", "작성", "이메일"]
        let explainTerms = language == .english
            ? ["explain", "teach", "why", "how does"]
            : ["설명", "왜", "어떻게"]
        let buildTerms = language == .english
            ? ["make", "build", "create", "generate", "app", "website"]
            : ["만들", "생성", "앱", "웹", "사이트"]

        if containsAny(normalized, fixTerms) {
            return .fix
        }
        if containsAny(normalized, improveTerms) {
            return .improve
        }
        if containsAny(normalized, writeTerms) {
            return .write
        }
        if containsAny(normalized, explainTerms) {
            return .explain
        }
        if containsAny(normalized, buildTerms) {
            return .build
        }
        return .unknown
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

private enum ProductKind {
    case app
    case website
    case ui
    case prompt
    case code
    case unknown

    var displayName: String {
        switch self {
        case .app: return "app"
        case .website: return "website"
        case .ui: return "UI"
        case .prompt: return "prompt"
        case .code: return "code"
        case .unknown: return "scope"
        }
    }

    var defaultSubject: String {
        switch self {
        case .app: return "an app"
        case .website: return "a website"
        case .ui: return "a UI"
        case .prompt: return "a prompt"
        case .code: return "this code"
        case .unknown: return "this idea"
        }
    }

    var koreanDefaultSubject: String {
        switch self {
        case .app: return "앱"
        case .website: return "웹사이트"
        case .ui: return "UI"
        case .prompt: return "프롬프트"
        case .code: return "이 코드"
        case .unknown: return "이 아이디어"
        }
    }

    static func detect(in text: String, language: PromptLanguage) -> ProductKind {
        let normalized = text.lowercased()
        if containsAny(normalized, language == .english ? ["app"] : ["앱"]) { return .app }
        if containsAny(normalized, language == .english ? ["website", "site", "landing", "web"] : ["웹", "사이트", "랜딩"]) { return .website }
        if containsAny(normalized, language == .english ? ["ui", "screen", "view", "design"] : ["디자인", "화면", "ui"]) { return .ui }
        if containsAny(normalized, language == .english ? ["prompt"] : ["프롬프트"]) { return .prompt }
        if containsAny(normalized, language == .english ? ["code", "function", "bug"] : ["코드", "함수", "버그"]) { return .code }
        return .unknown
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
