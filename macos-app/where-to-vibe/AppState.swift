import Foundation
import Combine

enum PromptLanguage: String, CaseIterable, Identifiable {
    case english
    case korean

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .english: return "EN"
        case .korean: return "KR"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }
}

/// Which AI the suggestion coach talks to. The user picks one in Settings and
/// supplies their own key for it.
enum AICoachProvider: String, CaseIterable, Identifiable {
    case openAI
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openAI: return "sk-..."
        case .claude: return "sk-ant-..."
        }
    }

    var keyLabel: String {
        switch self {
        case .openAI: return "OpenAI API Key"
        case .claude: return "Anthropic (Claude) API Key"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "PromptCoach.isEnabled")
            if isEnabled {
                refreshAccessibilityPermission()
            } else {
                clearSuggestions()
                currentInput = ""
                statusText = "Paused. Keyboard pass-through."
                idleDebugText = "Idle off: coach paused"
            }
        }
    }

    @Published var suggestionMode: SuggestionMode {
        didSet { UserDefaults.standard.set(suggestionMode.rawValue, forKey: "PromptCoach.suggestionMode") }
    }

    @Published var promptLanguage: PromptLanguage {
        didSet {
            UserDefaults.standard.set(promptLanguage.rawValue, forKey: "PromptCoach.promptLanguage")
            clearSuggestions()
        }
    }

    @Published var userLevel: UserLevel {
        didSet {
            UserDefaults.standard.set(userLevel.rawValue, forKey: "PromptCoach.userLevel")
            clearSuggestions()
        }
    }

    @Published var promptEvolutionStage: PromptEvolutionStage {
        didSet {
            UserDefaults.standard.set(promptEvolutionStage.rawValue, forKey: "PromptCoach.promptEvolutionStage")
            clearSuggestions()
        }
    }

    @Published var autoDetectLearningProfile: Bool {
        didSet {
            UserDefaults.standard.set(autoDetectLearningProfile, forKey: "PromptCoach.autoDetectLearningProfile")
            clearSuggestions()
        }
    }

    @Published var preferredAgentTool: AgentTool {
        didSet { UserDefaults.standard.set(preferredAgentTool.rawValue, forKey: "PromptCoach.preferredAgentTool") }
    }

    @Published var idleCoachEnabled: Bool {
        didSet { UserDefaults.standard.set(idleCoachEnabled, forKey: "PromptCoach.idleCoachEnabled") }
    }

    @Published var contextHUDEnabled: Bool {
        didSet { UserDefaults.standard.set(contextHUDEnabled, forKey: "PromptCoach.contextHUDEnabled") }
    }

    @Published var openAIAPIKey: String {
        didSet {
            UserDefaults.standard.set(openAIAPIKey, forKey: "PromptCoach.openAIAPIKey")
            enableFastAIIfKeyJustAdded(hadKeyBefore: !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The provider the coach talks to (OpenAI or Claude). The raw value is read
    /// by the suggestion provider from UserDefaults under "PromptCoach.aiProvider".
    @Published var selectedAICoachProvider: AICoachProvider {
        didSet {
            UserDefaults.standard.set(selectedAICoachProvider.rawValue, forKey: "PromptCoach.aiProvider")
            // Switching to a provider that already has a key should turn the
            // coach on; switching to one without a key shouldn't surprise-disable.
            enableFastAIIfKeyJustAdded(hadKeyBefore: false)
        }
    }

    @Published var claudeAPIKey: String {
        didSet {
            UserDefaults.standard.set(claudeAPIKey, forKey: "PromptCoach.claudeAPIKey")
            enableFastAIIfKeyJustAdded(hadKeyBefore: !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// When a usable key for the selected provider appears, flip the coach out of
    /// offline Local mode into Fast AI so it starts working without extra steps.
    private func enableFastAIIfKeyJustAdded(hadKeyBefore: Bool) {
        if !hadKeyBefore, hasCoachAPIKey, suggestionMode == .localHeuristic {
            suggestionMode = .fastAI
            statusText = "Fast AI enabled. Type a vague prompt and pause."
        }
    }

    @Published private(set) var inferredUserLevel: UserLevel = .beginner
    @Published private(set) var inferredPromptEvolutionStage: PromptEvolutionStage = .idea
    @Published private(set) var inferredProfileReason = ""
    @Published private(set) var hasAccessibilityPermission = false
    @Published var currentInput: String = ""
    @Published var suggestions: [PromptSuggestion] = []
    /// Which page of the current advice card is shown: 0 = "how to think"
    /// (the reason/question), 1 = the concrete answer. Driven by ←/→ while the
    /// panel is up; reset to 0 whenever the advice changes.
    @Published var suggestionPage: Int = 0
    // Dimensions the user's current draft is missing (e.g. "target user",
    // "success criteria"). Surfaced in the panel as a gap-first checklist so the
    // user learns WHAT to add, not just copies a finished rewrite.
    @Published var missingAxes: [String] = []

    // MARK: - Prompt-skill learning path
    // The named skills the coach teaches, in display order. They mirror the
    // VaguePromptDetector axes, so "the user included this on their own" simply
    // means "that axis was NOT flagged missing in their draft".
    static let coachSkillAxes: [String] = ["goal", "scope", "context", "constraints", "success criteria"]
    /// How many times the user must include a skill unprompted before it counts
    /// as mastered. Small so progress feels reachable.
    static let skillMasteryThreshold = 3

    /// Per-skill count of times the user included that axis on their own. Capped
    /// at the mastery threshold and persisted so progress survives relaunches.
    @Published private(set) var axisMasteryCounts: [String: Int] = [:]
    /// The last draft we recorded, so repeatedly re-analyzing the same draft
    /// while the user pauses doesn't inflate the counts.
    private var lastRecordedCoachedDraft = ""

    @Published var selectedSuggestionIndex = 0
    @Published var statusText = "Watching focused text fields"
    @Published var idleDebugText = "Idle coach waiting"
    @Published var watchedAppName = "No app"
    @Published var watchedAppBundleIdentifier = "unknown"
    @Published var watchedContextSource = "None"
    @Published var watchedContextPreview = "No focused input yet"
    @Published var idleTestRequestID = UUID()
    @Published var lastReason: String?

    var selectedSuggestion: PromptSuggestion? {
        guard suggestions.indices.contains(selectedSuggestionIndex) else { return nil }
        return suggestions[selectedSuggestionIndex]
    }

    var shouldShowSuggestionPanel: Bool {
        isEnabled && hasAccessibilityPermission && selectedSuggestion != nil
    }

    /// When set in the built app's Info.plist, the suggestion card runs through
    /// our Cloudflare Worker proxy (on OUR OpenAI key) instead of requiring each
    /// user to paste their own key — used for public/demo builds. Dev builds
    /// leave it unset and fall back to the user's own key.
    static var openAIProxyURL: String? {
        AppBundleConfiguration.stringValue(forKey: "OpenAIProxyURL")
    }

    var isUsingOpenAIProxy: Bool { AppState.openAIProxyURL != nil }

    /// Literal OpenAI-key (or proxy) presence — used by features that call OpenAI
    /// directly regardless of the coach provider (e.g. idea-refinement chat).
    var hasOpenAIAPIKey: Bool {
        isUsingOpenAIProxy || !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the user's CURRENTLY SELECTED provider has a usable key (or, for
    /// OpenAI, a configured proxy). Drives the Settings status + Fast-AI gating.
    var hasCoachAPIKey: Bool {
        switch selectedAICoachProvider {
        case .openAI:
            return isUsingOpenAIProxy || !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claude:
            return !claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The key for the SELECTED provider, handed to the suggestion engine. With
    /// the OpenAI proxy active we pass a non-empty sentinel so the engine's
    /// "needs a key" gate passes; the Worker injects the real key.
    var coachAPIKey: String {
        switch selectedAICoachProvider {
        case .openAI:
            return isUsingOpenAIProxy ? "proxy" : openAIAPIKey
        case .claude:
            return claudeAPIKey
        }
    }

    var effectiveUserLevel: UserLevel {
        autoDetectLearningProfile ? inferredUserLevel : userLevel
    }

    var effectivePromptEvolutionStage: PromptEvolutionStage {
        autoDetectLearningProfile ? inferredPromptEvolutionStage : promptEvolutionStage
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "PromptCoach.isEnabled") == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: "PromptCoach.isEnabled")
        }

        let savedMode = defaults.string(forKey: "PromptCoach.suggestionMode")
        // Default to Fast AI when the proxy is configured (public build) so the
        // coach works out of the box without the user setting anything; otherwise
        // default to offline Local heuristics.
        self.suggestionMode = SuggestionMode(rawValue: savedMode ?? "")
            ?? (AppState.openAIProxyURL != nil ? .fastAI : .localHeuristic)

        let savedLanguage = defaults.string(forKey: "PromptCoach.promptLanguage")
        self.promptLanguage = PromptLanguage(rawValue: savedLanguage ?? "") ?? .english

        let savedUserLevel = defaults.string(forKey: "PromptCoach.userLevel")
        self.userLevel = UserLevel(rawValue: savedUserLevel ?? "") ?? .beginner

        let savedStage = defaults.string(forKey: "PromptCoach.promptEvolutionStage")
        self.promptEvolutionStage = PromptEvolutionStage(rawValue: savedStage ?? "") ?? .idea

        if defaults.object(forKey: "PromptCoach.autoDetectLearningProfile") == nil {
            self.autoDetectLearningProfile = true
        } else {
            self.autoDetectLearningProfile = defaults.bool(forKey: "PromptCoach.autoDetectLearningProfile")
        }

        let savedAgentTool = defaults.string(forKey: "PromptCoach.preferredAgentTool")
        self.preferredAgentTool = AgentTool(rawValue: savedAgentTool ?? "") ?? .claudeCode

        if defaults.object(forKey: "PromptCoach.idleCoachEnabled") == nil {
            self.idleCoachEnabled = true
        } else {
            self.idleCoachEnabled = defaults.bool(forKey: "PromptCoach.idleCoachEnabled")
        }

        if defaults.object(forKey: "PromptCoach.contextHUDEnabled") == nil {
            self.contextHUDEnabled = true
        } else {
            self.contextHUDEnabled = defaults.bool(forKey: "PromptCoach.contextHUDEnabled")
        }

        self.openAIAPIKey = defaults.string(forKey: "PromptCoach.openAIAPIKey") ?? ""
        self.claudeAPIKey = defaults.string(forKey: "PromptCoach.claudeAPIKey") ?? ""
        self.axisMasteryCounts = (defaults.dictionary(forKey: "PromptCoach.axisMasteryCounts") as? [String: Int]) ?? [:]
        self.selectedAICoachProvider = AICoachProvider(rawValue: defaults.string(forKey: "PromptCoach.aiProvider") ?? "") ?? .openAI
    }

    func refreshAccessibilityPermission() {
        let previous = hasAccessibilityPermission
        hasAccessibilityPermission = AccessibilityTextReader.hasPermission(prompt: false)
        if previous != hasAccessibilityPermission {
            print("[Coach/AppState] hasAccessibilityPermission: \(previous) → \(hasAccessibilityPermission)")
        }
        statusText = hasAccessibilityPermission
            ? "Ready. Type a vague prompt and pause briefly."
            : "Accessibility permission required"
    }

    func setSuggestions(_ suggestions: [PromptSuggestion], reason: String?, missingAxes: [String] = []) {
        self.suggestions = suggestions
        self.selectedSuggestionIndex = 0
        self.suggestionPage = 0
        self.lastReason = reason
        self.missingAxes = missingAxes
    }

    func clearSuggestions() {
        suggestions = []
        selectedSuggestionIndex = 0
        suggestionPage = 0
        lastReason = nil
        missingAxes = []
    }

    // MARK: - Prompt-skill learning path

    /// Records, for one coached draft, which skills the user included on their
    /// own. A skill the user already supplied (not in `missingAxes`) gets its
    /// count bumped toward mastery; this is what makes the learning path advance.
    func recordCoachedDraft(text: String, missingAxes: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only count real, distinct drafts (skip empty + repeated re-analysis).
        guard !trimmed.isEmpty, trimmed != lastRecordedCoachedDraft else { return }
        lastRecordedCoachedDraft = trimmed

        var updatedCounts = axisMasteryCounts
        for axis in AppState.coachSkillAxes where !missingAxes.contains(axis) {
            updatedCounts[axis] = min((updatedCounts[axis] ?? 0) + 1, AppState.skillMasteryThreshold)
        }
        axisMasteryCounts = updatedCounts
        UserDefaults.standard.set(updatedCounts, forKey: "PromptCoach.axisMasteryCounts")

        // Log this draft's strengths (axes present) and gaps (axes missing) to the
        // local habit store so the weekly note can summarize pros/cons over time.
        let presentAxes = AppState.coachSkillAxes.filter { !missingAxes.contains($0) }
        let relevantMissing = missingAxes.filter { AppState.coachSkillAxes.contains($0) }
        PromptHabitStore.shared.add(presentAxes: presentAxes, missingAxes: relevantMissing)
    }

    func isSkillMastered(_ axis: String) -> Bool {
        (axisMasteryCounts[axis] ?? 0) >= AppState.skillMasteryThreshold
    }

    /// 0.0–1.0 progress toward mastering a single skill.
    func skillProgressFraction(_ axis: String) -> Double {
        Double(min(axisMasteryCounts[axis] ?? 0, AppState.skillMasteryThreshold)) / Double(AppState.skillMasteryThreshold)
    }

    var masteredSkillCount: Int {
        AppState.coachSkillAxes.filter { isSkillMastered($0) }.count
    }

    /// The single skill to work on next: the least-practiced not-yet-mastered one.
    /// nil once every skill is mastered.
    var nextFocusSkillAxis: String? {
        AppState.coachSkillAxes
            .filter { !isSkillMastered($0) }
            .min { (axisMasteryCounts[$0] ?? 0) < (axisMasteryCounts[$1] ?? 0) }
    }

    /// A simple level label derived purely from how many skills are mastered, so
    /// the user sees a level that they earned and can clearly climb.
    var promptSkillLevelLabel: String {
        switch masteredSkillCount {
        case 0...1: return promptLanguage == .korean ? "입문" : "Beginner"
        case 2...3: return promptLanguage == .korean ? "중급" : "Intermediate"
        default:    return promptLanguage == .korean ? "능숙" : "Advanced"
        }
    }

    func updateInferredLearningProfile(_ profile: LearningProfile) {
        inferredUserLevel = profile.userLevel
        inferredPromptEvolutionStage = profile.stage
        inferredProfileReason = profile.reason
    }

    func requestIdleNudgeTest() {
        idleTestRequestID = UUID()
    }

    func updateWatchedContext(
        appName: String,
        bundleIdentifier: String = "unknown",
        source: String,
        preview: String
    ) {
        watchedAppName = appName
        watchedAppBundleIdentifier = bundleIdentifier
        watchedContextSource = source
        watchedContextPreview = preview
    }

}
