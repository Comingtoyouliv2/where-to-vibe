import Foundation

enum UserLevel: String, CaseIterable, Identifiable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced: return "Advanced"
        }
    }

    var shortLabel: String {
        switch self {
        case .beginner: return "B"
        case .intermediate: return "I"
        case .advanced: return "A"
        }
    }

    func guidanceCopy(language: PromptLanguage) -> String {
        switch (self, language) {
        case (.beginner, .english):
            return "Helps turn a raw idea into a first AI conversation."
        case (.intermediate, .english):
            return "Focuses on decomposition, architecture, and debugging prompts."
        case (.advanced, .english):
            return "Explains limits and routes complex work into agent workflows."
        case (.beginner, .korean):
            return "막연한 아이디어를 AI와 처음 대화할 수 있는 요청으로 바꿉니다."
        case (.intermediate, .korean):
            return "기능 분해, 구조화, 디버깅 프롬프트에 집중합니다."
        case (.advanced, .korean):
            return "AI 한계를 설명하고 agent workflow로 자연스럽게 넘깁니다."
        }
    }
}

enum AgentTool: String, CaseIterable, Identifiable {
    case claudeCode
    case cursor
    case openCode
    case openAgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        case .openAgent: return "OpenAgent"
        }
    }

    func recommendedUse(language: PromptLanguage) -> String {
        switch (self, language) {
        case (.claudeCode, .english):
            return "Best when the agent should inspect files, plan edits, and run verification from the terminal."
        case (.cursor, .english):
            return "Best when you want IDE-native context, inline edits, and codebase navigation."
        case (.openCode, .english):
            return "Best when you prefer an open, terminal-first coding agent workflow."
        case (.openAgent, .english):
            return "Best when you want an agent-style workflow that can be adapted to your own stack."
        case (.claudeCode, .korean):
            return "터미널에서 파일을 읽고, 수정 계획을 세우고, 검증까지 맡기고 싶을 때 적합합니다."
        case (.cursor, .korean):
            return "IDE 안에서 코드베이스 맥락, inline edit, 파일 탐색을 함께 쓰고 싶을 때 적합합니다."
        case (.openCode, .korean):
            return "오픈소스 기반의 terminal-first coding agent 흐름을 선호할 때 적합합니다."
        case (.openAgent, .korean):
            return "내 스택에 맞게 agent workflow를 커스터마이즈하고 싶을 때 적합합니다."
        }
    }

    func transitionPrompt(
        task rawTask: String,
        language: PromptLanguage
    ) -> String {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = task.isEmpty
            ? (language == .korean ? "현재 작업" : "the current task")
            : task

        if language == .korean {
            return """
            \(displayName)에서 다음 작업을 진행할 수 있는 agent workflow prompt로 바꿔줘.

            Task:
            \(subject)

            반드시 포함할 것:
            - 관련 파일/폴더를 먼저 읽기
            - 현재 실행/테스트 방법 확인
            - 변경 범위를 작게 제안하기
            - 수정 전 계획을 짧게 설명하기
            - 구현 후 테스트 또는 수동 검증 수행하기
            - chat-only workflow에서 놓칠 수 있는 context/window 한계를 명시하기
            """
        }

        return """
        Rewrite this into an agent workflow prompt for \(displayName).

        Task:
        \(subject)

        Include:
        - inspect the relevant files and folders first
        - identify how to run and test the project
        - propose a small change scope
        - briefly explain the plan before editing
        - verify with tests or manual checks after implementation
        - call out any context-window or chat-only workflow limits
        """
    }
}

enum PromptEvolutionStage: String, CaseIterable, Identifiable {
    case idea
    case mvp
    case featureSpec
    case architecturePrompt
    case debuggingPrompt
    case agentWorkflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idea: return "Idea"
        case .mvp: return "MVP"
        case .featureSpec: return "Spec"
        case .architecturePrompt: return "Architecture"
        case .debuggingPrompt: return "Debug"
        case .agentWorkflow: return "Agent"
        }
    }

    var shortName: String {
        switch self {
        case .idea: return "Idea"
        case .mvp: return "MVP"
        case .featureSpec: return "Spec"
        case .architecturePrompt: return "Arch"
        case .debuggingPrompt: return "Debug"
        case .agentWorkflow: return "Agent"
        }
    }

    var next: PromptEvolutionStage? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        guard nextIndex < Self.allCases.endIndex else { return nil }
        return Self.allCases[nextIndex]
    }

    func nextStepPrompt(
        seed rawSeed: String,
        userLevel: UserLevel,
        language: PromptLanguage
    ) -> String {
        let seed = rawSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = seed.isEmpty
            ? (language == .korean ? "내 아이디어" : "my current idea")
            : seed

        if language == .korean {
            switch self {
            case .idea:
                return """
                다음 아이디어를 더 명확한 제품 아이디어로 정리해줘.

                Idea:
                \(subject)

                포함할 것:
                - 누구를 위한 것인지
                - 해결하려는 문제
                - 가장 중요한 사용 순간
                - 아직 모르는 질문 3개
                """
            case .mvp:
                return """
                다음 아이디어를 초보자도 만들 수 있는 작은 MVP로 줄여줘.

                Idea:
                \(subject)

                포함할 것:
                - 타겟 사용자
                - 핵심 사용 흐름 1개
                - 반드시 필요한 기능 3개
                - 나중으로 미룰 기능
                - AI 코딩 도구에 보낼 첫 프롬프트
                """
            case .featureSpec:
                return """
                다음 MVP를 기능 명세로 발전시켜줘.

                Current draft:
                \(subject)

                포함할 것:
                - 사용자 시나리오
                - 화면 또는 컴포넌트 목록
                - 데이터 모델
                - 예외 케이스
                - 완료 기준
                - 구현 순서
                """
            case .architecturePrompt:
                return """
                다음 기능을 구현하기 전에 아키텍처 계획을 세워줘.

                Current draft:
                \(subject)

                포함할 것:
                - 폴더 구조
                - 데이터 모델 또는 DB schema
                - API/component 경계
                - 상태 관리 방식
                - 트레이드오프
                - 첫 구현 마일스톤
                """
            case .debuggingPrompt:
                return """
                다음 문제를 디버깅 가능한 요청으로 바꿔줘.

                Current draft:
                \(subject)

                포함할 것:
                - 재현 방법
                - 현재 동작과 기대 동작
                - 로그/스크린샷/에러 메시지
                - 의심되는 파일 또는 기능
                - 가장 작은 안전한 수정
                - 검증 방법
                """
            case .agentWorkflow:
                return """
                다음 작업은 chat-only보다 filesystem-aware coding agent가 적합할 수 있어.

                Current task:
                \(subject)

                Claude Code, Cursor, OpenCode 같은 agent에서 진행할 수 있도록:
                - 관련 파일/폴더 먼저 읽기
                - 현재 실행/테스트 방법 확인
                - 변경 범위 제안
                - 작은 단계로 구현
                - 테스트 또는 수동 검증까지 수행
                하는 agent workflow prompt로 바꿔줘.
                """
            }
        }

        switch self {
        case .idea:
            return """
            Clarify the following idea into a concrete product direction.

            Idea:
            \(subject)

            Include:
            - target user
            - problem being solved
            - most important user moment
            - 3 open questions
            """
        case .mvp:
            return """
            Turn the following idea into a beginner-friendly MVP.

            Idea:
            \(subject)

            Include:
            - target user
            - one core workflow
            - 3 must-have features
            - features to postpone
            - the first prompt I should send to an AI coding tool
            """
        case .featureSpec:
            return """
            Turn the following MVP into a feature spec.

            Current draft:
            \(subject)

            Include:
            - user stories
            - screens or components
            - data model
            - edge cases
            - acceptance criteria
            - implementation order
            """
        case .architecturePrompt:
            return """
            Create an architecture plan before implementing this feature.

            Current draft:
            \(subject)

            Include:
            - folder structure
            - data model or database schema
            - API/component boundaries
            - state management
            - tradeoffs
            - first implementation milestone
            """
        case .debuggingPrompt:
            return """
            Turn the following issue into a debuggable AI coding prompt.

            Current draft:
            \(subject)

            Include:
            - reproduction steps
            - actual vs expected behavior
            - logs/screenshots/error messages
            - suspected files or feature area
            - smallest safe fix
            - verification method
            """
        case .agentWorkflow:
            return """
            This task may be better suited for a filesystem-aware coding agent than a chat-only workflow.

            Current task:
            \(subject)

            Rewrite this for Claude Code, Cursor, OpenCode, or a similar agent. Ask the agent to:
            - inspect relevant files/folders first
            - identify how to run and test the project
            - propose the change scope
            - implement in small steps
            - verify with tests or manual checks
            """
        }
    }
}

struct LearningProfile: Equatable {
    let userLevel: UserLevel
    let stage: PromptEvolutionStage
    let reason: String
}

struct LearningProfileResolver {
    func resolve(
        text rawText: String,
        manualLevel: UserLevel,
        manualStage: PromptEvolutionStage,
        isAutoDetectEnabled: Bool,
        language: PromptLanguage
    ) -> LearningProfile {
        guard isAutoDetectEnabled else {
            return LearningProfile(
                userLevel: manualLevel,
                stage: manualStage,
                reason: language == .korean ? "수동 설정 사용 중" : "Manual profile"
            )
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()
        let englishWordCount = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .count
        let koreanUnitCount = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        let wordCount = language == .korean && englishWordCount == 0 ? koreanUnitCount : englishWordCount

        if containsAny(normalized, advancedTerms(language: language)) {
            return LearningProfile(
                userLevel: .advanced,
                stage: .agentWorkflow,
                reason: language == .korean
                    ? "multi-file, 배포, 인프라, 실시간 기능 신호가 있어요."
                    : "Detected multi-file, deployment, infrastructure, or realtime complexity."
            )
        }

        if containsAny(normalized, debuggingTerms(language: language)) {
            return LearningProfile(
                userLevel: .intermediate,
                stage: .debuggingPrompt,
                reason: language == .korean
                    ? "디버깅 흐름이 필요해 보여요."
                    : "Detected a debugging workflow."
            )
        }

        if containsAny(normalized, architectureTerms(language: language)) {
            return LearningProfile(
                userLevel: .intermediate,
                stage: .architecturePrompt,
                reason: language == .korean
                    ? "데이터/API/구조 설계 신호가 있어요."
                    : "Detected architecture, data, or API planning."
            )
        }

        if containsAny(normalized, specTerms(language: language)) {
            return LearningProfile(
                userLevel: .intermediate,
                stage: .featureSpec,
                reason: language == .korean
                    ? "기능 명세로 발전시킬 수 있어요."
                    : "Detected feature specification work."
            )
        }

        if containsAny(normalized, mvpTerms(language: language)) || wordCount <= 7 {
            return LearningProfile(
                userLevel: .beginner,
                stage: .mvp,
                reason: language == .korean
                    ? "아이디어를 먼저 작은 MVP로 줄이는 단계예요."
                    : "This looks like an idea that should become a small MVP first."
            )
        }

        return LearningProfile(
            userLevel: .beginner,
            stage: .idea,
            reason: language == .korean
                ? "아직 아이디어를 구조화하는 단계예요."
                : "Still in idea-shaping mode."
        )
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private func advancedTerms(language: PromptLanguage) -> [String] {
        language == .korean
            ? ["여러 파일", "전체 코드베이스", "대규모", "배포", "인프라", "웹소켓", "실시간", "docker", "kubernetes", "마이그레이션", "ci", "프로덕션", "모니터링", "리팩터링", "전체 구조", "레포", "코드베이스", "운영", "서버"]
            : ["multi-file", "entire codebase", "large codebase", "deploy", "deployment", "infrastructure", "websocket", "realtime", "docker", "kubernetes", "migration", "ci", "production", "monitoring"]
    }

    private func debuggingTerms(language: PromptLanguage) -> [String] {
        language == .korean
            ? ["버그", "에러", "디버그", "고쳐", "수정", "crash", "로그", "스택트레이스", "안돼", "안 되", "실패", "깨져", "멈춰", "오류", "원인"]
            : ["bug", "error", "debug", "crash", "fix", "logs", "stack trace", "broken", "failing"]
    }

    private func architectureTerms(language: PromptLanguage) -> [String] {
        language == .korean
            ? ["아키텍처", "구조", "db", "데이터베이스", "스키마", "supabase", "api", "백엔드", "폴더 구조", "상태 관리", "컴포넌트", "데이터 모델", "테이블", "인증", "권한", "라우팅"]
            : ["architecture", "structure", "database", "schema", "supabase", "api", "backend", "folder structure", "state management"]
    }

    private func specTerms(language: PromptLanguage) -> [String] {
        language == .korean
            ? ["요구사항", "명세", "기능", "로드맵", "유저 플로우", "사용자 시나리오", "완료 기준", "화면", "사용 흐름", "정의", "스펙"]
            : ["requirements", "spec", "feature", "roadmap", "user flow", "user story", "acceptance criteria"]
    }

    private func mvpTerms(language: PromptLanguage) -> [String] {
        language == .korean
            ? ["앱", "웹사이트", "사이트", "만들", "아이디어", "mvp", "랜딩", "서비스", "툴", "하고 싶", "기획", "초안"]
            : ["app", "website", "site", "build", "make", "idea", "mvp", "landing"]
    }
}

struct GBrainMemorySnapshot: Equatable {
    let acceptedPromptCount: Int
    let lastAcceptedPrompt: String?
    let lastAcceptedLevel: UserLevel?
    let lastAcceptedStage: PromptEvolutionStage?
}

final class GBrainMemoryStore {
    static let shared = GBrainMemoryStore()

    private let acceptedPromptCountKey = "PromptCoach.gbrain.acceptedPromptCount"
    private let lastAcceptedPromptKey = "PromptCoach.gbrain.lastAcceptedPrompt"
    private let lastAcceptedLevelKey = "PromptCoach.gbrain.lastAcceptedLevel"
    private let lastAcceptedStageKey = "PromptCoach.gbrain.lastAcceptedStage"

    private init() {}

    func snapshot() -> GBrainMemorySnapshot {
        let defaults = UserDefaults.standard
        let level = defaults.string(forKey: lastAcceptedLevelKey).flatMap(UserLevel.init(rawValue:))
        let stage = defaults.string(forKey: lastAcceptedStageKey).flatMap(PromptEvolutionStage.init(rawValue:))
        return GBrainMemorySnapshot(
            acceptedPromptCount: defaults.integer(forKey: acceptedPromptCountKey),
            lastAcceptedPrompt: defaults.string(forKey: lastAcceptedPromptKey),
            lastAcceptedLevel: level,
            lastAcceptedStage: stage
        )
    }

    func recordAcceptedSuggestion(
        originalInput: String,
        acceptedPrompt: String,
        userLevel: UserLevel,
        stage: PromptEvolutionStage
    ) {
        let defaults = UserDefaults.standard
        let nextCount = defaults.integer(forKey: acceptedPromptCountKey) + 1
        defaults.set(nextCount, forKey: acceptedPromptCountKey)
        defaults.set(acceptedPrompt, forKey: lastAcceptedPromptKey)
        defaults.set(userLevel.rawValue, forKey: lastAcceptedLevelKey)
        defaults.set(stage.rawValue, forKey: lastAcceptedStageKey)
    }
}

struct GStackGuidance: Equatable {
    let shouldCoach: Bool
    let reason: String?
    let limitationNote: String?
    let chips: [String]
    let recommendedStage: PromptEvolutionStage?
    let requiresAgentWorkflow: Bool
}

struct GStackGuidanceEngine {
    func assess(
        text: String,
        signal: VaguePromptSignal,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        language: PromptLanguage
    ) -> GStackGuidance {
        let normalized = text.lowercased()
        let hasDebuggingNeed = containsAny(
            normalized,
            language == .korean
                ? ["버그", "에러", "디버그", "고쳐", "수정", "안돼", "실패", "오류", "로그"]
                : ["bug", "error", "debug", "crash", "fix"]
        )
        let hasArchitectureNeed = containsAny(
            normalized,
            language == .korean
                ? ["아키텍처", "구조", "db", "데이터베이스", "supabase", "api", "백엔드", "컴포넌트", "데이터 모델", "스키마"]
                : ["architecture", "database", "schema", "supabase", "api", "backend", "folder structure"]
        )
        let hasInfrastructureNeed = containsAny(
            normalized,
            language == .korean
                ? ["배포", "인프라", "웹소켓", "실시간", "docker", "kubernetes", "마이그레이션", "인증"]
                : ["deploy", "infrastructure", "websocket", "realtime", "docker", "kubernetes", "migration", "auth"]
        )
        let hasMultiFileNeed = containsAny(
            normalized,
            language == .korean
                ? ["여러 파일", "전체 코드베이스", "리팩터링", "대규모"]
                : ["multi-file", "entire codebase", "large codebase", "refactor across", "many files"]
        )

        let requiresAgentWorkflow = userLevel == .advanced
            || stage == .agentWorkflow
            || hasInfrastructureNeed
            || hasMultiFileNeed

        if requiresAgentWorkflow {
            return GStackGuidance(
                shouldCoach: true,
                reason: language == .korean
                    ? "이 요청은 단일 채팅보다 파일시스템을 이해하는 agent workflow가 더 적합할 수 있어요."
                    : "This is likely beyond a single chat prompt and may need a filesystem-aware agent workflow.",
                limitationNote: language == .korean
                    ? "multi-file 구조, 배포, 실시간 기능은 context window와 chat-only workflow에서 쉽게 무너질 수 있습니다."
                    : "Multi-file architecture, deployment, and realtime systems can exceed chat-only context handling.",
                chips: language == .korean
                    ? ["agent", "multi-file", "한계"]
                    : ["agent", "multi-file", "limits"],
                recommendedStage: .agentWorkflow,
                requiresAgentWorkflow: true
            )
        }

        if hasDebuggingNeed {
            return GStackGuidance(
                shouldCoach: true,
                reason: language == .korean
                    ? "디버깅 요청은 재현 방법과 기대 동작이 있어야 AI가 덜 헤맵니다."
                    : "Debugging prompts need reproduction steps and expected behavior.",
                limitationNote: nil,
                chips: language == .korean ? ["재현", "기대 동작", "테스트"] : ["repro", "expected", "test"],
                recommendedStage: .debuggingPrompt,
                requiresAgentWorkflow: false
            )
        }

        if hasArchitectureNeed || stage == .architecturePrompt {
            return GStackGuidance(
                shouldCoach: true,
                reason: language == .korean
                    ? "구조 요청은 파일 구조, 데이터 모델, API 경계를 먼저 나누면 좋아요."
                    : "Architecture prompts work better when folder structure, data model, and API boundaries are explicit.",
                limitationNote: nil,
                chips: language == .korean ? ["구조", "DB", "API"] : ["structure", "schema", "API"],
                recommendedStage: .architecturePrompt,
                requiresAgentWorkflow: false
            )
        }

        return GStackGuidance(
            shouldCoach: signal.isVague,
            reason: nil,
            limitationNote: nil,
            chips: [],
            recommendedStage: nil,
            requiresAgentWorkflow: false
        )
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
