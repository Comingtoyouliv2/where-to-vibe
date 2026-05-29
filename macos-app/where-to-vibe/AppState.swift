import Foundation

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
            let hadKeyBefore = !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasKeyNow = hasOpenAIAPIKey
            if !hadKeyBefore, hasKeyNow, suggestionMode == .localHeuristic {
                suggestionMode = .fastAI
                statusText = "Fast AI enabled. Type a vague prompt and pause."
            }
        }
    }

    @Published private(set) var inferredUserLevel: UserLevel = .beginner
    @Published private(set) var inferredPromptEvolutionStage: PromptEvolutionStage = .idea
    @Published private(set) var inferredProfileReason = ""
    @Published private(set) var hasAccessibilityPermission = false
    @Published var currentInput: String = ""
    @Published var suggestions: [PromptSuggestion] = []
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

    var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        self.suggestionMode = SuggestionMode(rawValue: savedMode ?? "") ?? .localHeuristic

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

    func setSuggestions(_ suggestions: [PromptSuggestion], reason: String?) {
        self.suggestions = suggestions
        self.selectedSuggestionIndex = 0
        self.lastReason = reason
    }

    func clearSuggestions() {
        suggestions = []
        selectedSuggestionIndex = 0
        lastReason = nil
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
