import AppKit
import Combine
import Foundation

@MainActor
final class PromptCoachController {
    private let appState: AppState
    private let textReader = AccessibilityTextReader()
    private let mouseTracker = MouseTracker()
    private let learningProfileResolver = LearningProfileResolver()
    private let suggestionEngine: SuggestionEngine
    private let idleNudgeComposer = IdleNudgeComposer()
    private let floatingPanel: FloatingSuggestionPanel
    private let contextStatusPanel: ContextStatusPanel
    private let acceptController = SuggestionAcceptController()

    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastSeenText = ""
    private var lastCaretFrame: CGRect?
    private var typedFallbackText = ""
    private var lastFrontmostProcessIdentifier: pid_t?
    private var lastObservedMouseLocation: CGPoint?
    private var lastIdleNudgeText = ""
    private var isKeyHandlingActive = false

    // Debug logging throttle. pollFocusedText runs every 0.25s; without throttling
    // the console gets flooded. We only re-emit the same reason after this interval,
    // or whenever the reason itself changes.
    private var lastDebugReason: String = ""
    private var lastDebugLogTime: Date = .distantPast
    private let debugLogThrottleInterval: TimeInterval = 2.0

    private func debugLog(_ reason: String, force: Bool = false) {
        let now = Date()
        if !force,
           reason == lastDebugReason,
           now.timeIntervalSince(lastDebugLogTime) < debugLogThrottleInterval {
            return
        }
        lastDebugReason = reason
        lastDebugLogTime = now
        print("[Coach] \(reason)")
    }
    private let ignoredApplicationBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass"
    ]
    private let aiCodingApplicationNameFragments = [
        "chatgpt",
        "claude",
        "codex",
        "cursor",
        "terminal",
        "iterm",
        "ghostty",
        "wezterm",
        "kitty",
        "alacritty",
        "opencode",
        "windsurf",
        "visual studio code",
        "warp",
        "xcode",
        "zed"
    ]

    init(appState: AppState) {
        self.appState = appState
        self.suggestionEngine = SuggestionEngine(aiProvider: OpenAIScreenSuggestionProvider())
        self.floatingPanel = FloatingSuggestionPanel(appState: appState)
        self.contextStatusPanel = ContextStatusPanel(appState: appState)
        wireKeyboardActions()
        observeSafetyState()
        observeMouseActivity()
        observeIdleTestRequests()
    }

    func start() {
        appState.refreshAccessibilityPermission()
        mouseTracker.start()
        syncSafetyState()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFocusedText() }
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.appState.refreshAccessibilityPermission()
                self?.syncSafetyState()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        permissionTimer?.invalidate()
        debounceTask?.cancel()
        suggestionTask?.cancel()
        idleTask?.cancel()
        acceptController.stop()
        floatingPanel.hide()
        contextStatusPanel.hide()
        mouseTracker.stop()
        isKeyHandlingActive = false
    }

    private func wireKeyboardActions() {
        acceptController.shouldHandleKeys = { [weak self] in
            guard let self else { return false }
            return self.appState.shouldShowSuggestionPanel
        }

        acceptController.shouldObserveKeys = { [weak self] in
            guard let self else { return false }
            return self.isKeyHandlingActive && self.ignoredFrontmostApplicationReason() == nil
        }

        acceptController.canAcceptWithTab = { [weak self] in
            guard let self, let suggestion = self.appState.selectedSuggestion else {
                print("🔧[TabCopy] canAcceptWithTab=false — no selectedSuggestion")
                return false
            }
            // Tab copies whatever advice is currently on screen. As long as the
            // panel is showing and there's some text to copy, Tab works — we do
            // NOT gate on the suggestion's intent or on the rewrite field
            // specifically (advisory suggestions keep their text in `reason`).
            let copyText = self.copyableAdviceText(for: suggestion)
            let ok = self.appState.shouldShowSuggestionPanel && !copyText.isEmpty
            print("🔧[TabCopy] canAcceptWithTab=\(ok) — panelShowing=\(self.appState.shouldShowSuggestionPanel) copyTextLen=\(copyText.count) suggestion.textLen=\(suggestion.text.count)")
            return ok
        }

        acceptController.accept = { [weak self] in
            guard let self,
                  let suggestion = self.appState.selectedSuggestion
            else {
                print("🔧[TabCopy] accept — no selectedSuggestion, nothing copied")
                return
            }
            let adviceText = self.copyableAdviceText(for: suggestion)
            guard !adviceText.isEmpty else {
                print("🔧[TabCopy] accept — copyable text empty, nothing copied")
                return
            }
            print("🔧[TabCopy] accept — COPIED to clipboard: \"\(adviceText.prefix(40))…\"")
            // Copy the visible advice to the clipboard; the user pastes it with
            // ⌘V wherever they want. We copy rather than insert so we don't
            // fight the target app's own Tab/indent behaviour.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(adviceText, forType: .string)
            GBrainMemoryStore.shared.recordAcceptedSuggestion(
                originalInput: self.appState.currentInput,
                acceptedPrompt: adviceText,
                userLevel: self.appState.effectiveUserLevel,
                stage: self.appState.effectivePromptEvolutionStage
            )
            self.appState.clearSuggestions()
            self.floatingPanel.hide()
        }

        acceptController.dismiss = { [weak self] in
            guard let self, self.isKeyHandlingActive else { return }
            self.appState.clearSuggestions()
            self.floatingPanel.hide()
        }

        acceptController.observeKeyInput = { [weak self] input in
            self?.recordFallbackInput(input)
        }
    }

    /// The text Tab should copy for a given suggestion: the rewrite (`text`)
    /// when present, otherwise the advice headline (`lastReason` / the
    /// suggestion's own `reason`). Trimmed; empty string means "nothing to
    /// copy". This is what makes Tab work for every kind of advice, not just
    /// rewrite suggestions.
    private func copyableAdviceText(for suggestion: PromptSuggestion) -> String {
        let rewrite = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rewrite.isEmpty {
            return rewrite
        }
        let reason = (appState.lastReason ?? suggestion.reason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason
    }

    private func observeMouseActivity() {
        mouseTracker.$location
            .sink { [weak self] location in
                Task { @MainActor in
                    self?.recordMouseActivity(location)
                }
            }
            .store(in: &cancellables)
    }

    private func observeSafetyState() {
        appState.$isEnabled
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncSafetyState()
                }
            }
            .store(in: &cancellables)

        appState.$hasAccessibilityPermission
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncSafetyState()
                }
            }
            .store(in: &cancellables)
    }

    private func syncSafetyState() {
        let shouldHandleKeys = appState.isEnabled && appState.hasAccessibilityPermission

        if shouldHandleKeys {
            guard !isKeyHandlingActive else { return }
            // Only mark active if the tap actually came up. If tap creation
            // fails (TCC trust race right after launch / rebuild), leave it
            // false so the 1.5s permission timer retries start() next tick
            // instead of getting stuck "active" with no tap — which is exactly
            // why Tab-to-copy could silently stop working.
            isKeyHandlingActive = acceptController.start()
            return
        }

        guard isKeyHandlingActive else {
            clearTransientCoachState()
            return
        }

        acceptController.stop()
        isKeyHandlingActive = false
        clearTransientCoachState()
    }

    private func clearTransientCoachState() {
        debounceTask?.cancel()
        suggestionTask?.cancel()
        idleTask?.cancel()
        appState.clearSuggestions()
        floatingPanel.hide()
        contextStatusPanel.hide()
        resetFallbackText()
        appState.currentInput = ""
        appState.idleDebugText = appState.isEnabled
            ? "Idle off: Accessibility missing"
            : "Idle off: coach paused"
    }

    private func observeIdleTestRequests() {
        appState.$idleTestRequestID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.showIdleNudge(force: true)
                }
            }
            .store(in: &cancellables)
    }

    private func pollFocusedText() {
        guard appState.isEnabled else {
            debugLog("GATE: appState.isEnabled is false — coach paused. Toggle on from menu bar.")
            appState.clearSuggestions()
            floatingPanel.hide()
            contextStatusPanel.hide()
            idleTask?.cancel()
            appState.idleDebugText = "Idle off: coach disabled"
            return
        }

        guard appState.hasAccessibilityPermission else {
            debugLog("GATE: hasAccessibilityPermission is FALSE — grant Accessibility permission in System Settings → Privacy & Security → Accessibility.")
            floatingPanel.hide()
            contextStatusPanel.hide()
            idleTask?.cancel()
            appState.idleDebugText = "Idle off: Accessibility missing"
            return
        }

        if frontmostProcessIdentifierChanged() {
            let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            debugLog("Frontmost app changed → \(frontmostName)", force: true)
            resetFallbackText()
        }

        if let ignoredReason = ignoredFrontmostApplicationReason() {
            debugLog("GATE: frontmost app is ignored — \(ignoredReason)")
            appState.clearSuggestions()
            floatingPanel.hide()
            contextStatusPanel.hide()
            idleTask?.cancel()
            updateWatchedContext(source: "Ignored app", preview: ignoredReason)
            appState.idleDebugText = "Idle off: \(ignoredReason)"
            return
        }

        guard let snapshot = textReader.readFocusedText(allowEmpty: true) else {
            let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            debugLog("AX could not find a focused text field in \(frontmostName). Falling back to typed-key buffer (len=\(typedFallbackText.count)).")
            let fallback = typedFallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else {
                lastSeenText = ""
                appState.currentInput = ""
                updateWatchedContext(source: "None", preview: "No readable focused input")
                contextStatusPanel.refresh()
                if isFrontmostAICodingApplication() {
                    debugLog("AI coding app detected (\(frontmostName)) with no readable input → arming forced idle nudge.")
                    if appState.shouldShowSuggestionPanel {
                        showPanelAtBestAnchor()
                    }
                    scheduleIdleNudgeIfNeeded(force: true)
                    appState.idleDebugText = "Idle armed: Codex-style app, no readable input yet"
                } else {
                    debugLog("GATE: not an AI coding app (\(frontmostName)) AND no readable input AND no typed fallback. Panel hidden. Focus a text field in TextEdit/ChatGPT/Cursor/etc, OR add this app's name to aiCodingApplicationNameFragments.")
                    if !appState.suggestions.isEmpty {
                        appState.clearSuggestions()
                        floatingPanel.hide()
                    }
                    idleTask?.cancel()
                    appState.idleDebugText = "Idle waiting: no readable input field"
                }
                return
            }

            debugLog("Using typed-key fallback as input (len=\(fallback.count)): \"\(fallback.prefix(40))\"", force: true)
            appState.currentInput = fallback
            updateWatchedContext(source: "Key fallback", preview: fallback)
            contextStatusPanel.refresh()
            lastCaretFrame = nil

            guard fallback != lastSeenText else {
                if appState.shouldShowSuggestionPanel {
                    showPanelAtBestAnchor()
                }
                scheduleIdleNudgeIfNeeded()
                return
            }

            lastSeenText = fallback
            lastIdleNudgeText = ""
            appState.clearSuggestions()
            floatingPanel.hide()
            scheduleSuggestion(for: fallback)
            restartIdleNudgeTimer()
            return
        }

        lastCaretFrame = snapshot.caretFrame
        appState.currentInput = snapshot.text
        typedFallbackText = snapshot.text
        updateWatchedContext(
            source: snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty input" : "AX text",
            preview: snapshot.text
        )
        contextStatusPanel.refresh()

        guard snapshot.text != lastSeenText else {
            if appState.shouldShowSuggestionPanel {
                showPanelAtBestAnchor()
            } else {
                debugLog("Text unchanged AND shouldShowSuggestionPanel=false (isEnabled=\(appState.isEnabled), hasAX=\(appState.hasAccessibilityPermission), selectedSuggestion=\(appState.selectedSuggestion != nil)) → not showing panel.")
            }
            scheduleIdleNudgeIfNeeded()
            return
        }

        debugLog("AX read focused text (len=\(snapshot.text.count)): \"\(snapshot.text.prefix(40))\"", force: true)
        lastSeenText = snapshot.text
        lastIdleNudgeText = ""
        appState.clearSuggestions()
        floatingPanel.hide()
        if !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSuggestion(for: snapshot.text)
        } else {
            debugLog("Focused text is empty after AX read — waiting for user to type.")
        }
        restartIdleNudgeTimer()
    }

    private func scheduleSuggestion(for text: String) {
        debounceTask?.cancel()
        suggestionTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.generateSuggestion(for: text)
        }
    }

    private func generateSuggestion(for text: String) async {
        suggestionTask?.cancel()
        let mode = appState.suggestionMode
        let language = appState.promptLanguage
        let profile = learningProfileResolver.resolve(
            text: text,
            manualLevel: appState.userLevel,
            manualStage: appState.promptEvolutionStage,
            isAutoDetectEnabled: appState.autoDetectLearningProfile,
            language: language
        )
        appState.updateInferredLearningProfile(profile)
        let userLevel = profile.userLevel
        let stage = profile.stage
        let apiKey = appState.coachAPIKey
        let shouldForceCoach = isFrontmostAICodingApplication()

        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let response = await self.suggestionEngine.suggestions(
                for: text,
                mode: mode,
                language: language,
                userLevel: userLevel,
                stage: stage,
                apiKey: apiKey,
                forceCoach: shouldForceCoach
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard text == self.lastSeenText else {
                    self.debugLog("Suggestion arrived but text changed in the meantime — discarding.", force: true)
                    return
                }
                let displayReason = response.suggestions.first?.reason ?? (response.signal.isVague ? response.signal.reason : nil)
                self.appState.setSuggestions(response.suggestions, reason: displayReason, missingAxes: response.signal.missingAxes)
                // Advance the learning path: credit the skills the user already
                // included on their own in this draft.
                self.appState.recordCoachedDraft(text: text, missingAxes: response.signal.missingAxes)
                self.appState.idleDebugText = response.debugMessage
                if response.suggestions.isEmpty {
                    self.debugLog("SuggestionEngine returned EMPTY (\(response.debugMessage)) → panel hidden. Check vagueness signal (isVague=\(response.signal.isVague), score=\(response.signal.score)) and SuggestionMode.", force: true)
                    self.floatingPanel.hide()
                } else {
                    self.debugLog("SuggestionEngine returned \(response.suggestions.count) suggestion(s) — showing panel. shouldShowSuggestionPanel=\(self.appState.shouldShowSuggestionPanel)", force: true)
                    self.showPanelAtBestAnchor()
                }
            }
        }
    }

    private func scheduleIdleNudgeIfNeeded(force: Bool = false) {
        guard appState.idleCoachEnabled, appState.isEnabled, appState.hasAccessibilityPermission else { return }
        guard force || appState.suggestions.isEmpty else { return }
        guard idleTask == nil else { return }

        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showIdleNudge(force: false)
        }
        appState.idleDebugText = "Idle armed: showing next-step coach in 3s"
    }

    private func restartIdleNudgeTimer() {
        idleTask?.cancel()
        idleTask = nil
        scheduleIdleNudgeIfNeeded()
    }

    private func showIdleNudge(force: Bool) {
        idleTask = nil
        guard appState.idleCoachEnabled, appState.isEnabled, appState.hasAccessibilityPermission else { return }
        guard force || appState.suggestions.isEmpty else {
            appState.idleDebugText = "Idle skipped: another suggestion is already ready"
            if appState.shouldShowSuggestionPanel {
                showPanelAtBestAnchor()
            }
            return
        }

        let text = appState.currentInput
        let language = appState.promptLanguage
        let profile = learningProfileResolver.resolve(
            text: text,
            manualLevel: appState.userLevel,
            manualStage: appState.promptEvolutionStage,
            isAutoDetectEnabled: appState.autoDetectLearningProfile,
            language: language
        )
        appState.updateInferredLearningProfile(profile)

        let apiKey = appState.coachAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !apiKey.isEmpty else {
                appState.idleDebugText = "Idle waiting: screen-aware suggestions need an API key"
                debugLog("Idle empty input skipped — no API key for screen-aware suggestion.", force: true)
                return
            }
            generateProactiveIdleSuggestion(language: language, userLevel: profile.userLevel, stage: profile.stage, apiKey: apiKey, force: force)
            return
        }

        let suggestion = idleNudgeComposer.suggestion(
            for: text,
            language: language,
            userLevel: profile.userLevel,
            stage: profile.stage,
            preferredAgentTool: appState.preferredAgentTool
        )
        guard force || suggestion.text != lastIdleNudgeText else {
            appState.idleDebugText = "Idle skipped: same nudge was already shown"
            return
        }

        lastIdleNudgeText = suggestion.text
        appState.setSuggestions([suggestion], reason: suggestion.reason)
        showPanelAtBestAnchor()
        appState.idleDebugText = force ? "Idle test shown" : "Idle nudge shown"
    }

    private func generateProactiveIdleSuggestion(
        language: PromptLanguage,
        userLevel: UserLevel,
        stage: PromptEvolutionStage,
        apiKey: String,
        force: Bool
    ) {
        suggestionTask?.cancel()
        appState.idleDebugText = "Idle reading current screen..."

        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let preferredAIMode: SuggestionMode = self.appState.suggestionMode == .highQualityAI
                ? .highQualityAI
                : .fastAI
            let response = await self.suggestionEngine.suggestions(
                for: "",
                mode: preferredAIMode,
                language: language,
                userLevel: userLevel,
                stage: stage,
                apiKey: apiKey,
                forceCoach: true
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let suggestion = response.suggestions.first
                self.appState.idleDebugText = response.debugMessage
                guard let suggestion else {
                    self.debugLog("Proactive idle screen suggestion returned EMPTY (\(response.debugMessage)).", force: true)
                    self.floatingPanel.hide()
                    return
                }

                guard force || suggestion.text != self.lastIdleNudgeText else {
                    self.appState.idleDebugText = "Idle skipped: same screen-aware nudge was already shown"
                    return
                }

                self.lastIdleNudgeText = suggestion.text
                self.appState.setSuggestions([suggestion], reason: suggestion.reason)
                self.showPanelAtBestAnchor()
                self.debugLog("Proactive idle screen suggestion shown.", force: true)
            }
        }
    }

    private func showPanelAtBestAnchor() {
        let anchor: CGPoint
        let source: String
        if let lastCaretFrame {
            anchor = CGPoint(x: lastCaretFrame.maxX, y: lastCaretFrame.minY)
            source = "caret"
        } else {
            anchor = mouseTracker.location
            source = "mouse"
        }
        debugLog("showPanelAtBestAnchor anchor=(\(Int(anchor.x)),\(Int(anchor.y))) source=\(source), shouldShowSuggestionPanel=\(appState.shouldShowSuggestionPanel)", force: true)
        floatingPanel.show(anchor: anchor)
    }

    private func recordFallbackInput(_ input: ObservedKeyInput) {
        guard appState.isEnabled else { return }
        guard ignoredFrontmostApplicationReason() == nil else { return }
        idleTask?.cancel()

        if frontmostProcessIdentifierChanged() {
            resetFallbackText()
        }

        switch input {
        case .text(let string):
            typedFallbackText.append(string)
        case .backspace:
            if !typedFallbackText.isEmpty {
                typedFallbackText.removeLast()
            }
        case .deleteForward:
            break
        case .commit:
            resetFallbackText()
            appState.clearSuggestions()
            floatingPanel.hide()
            return
        }

        let trimmed = typedFallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != lastSeenText {
            lastIdleNudgeText = ""
            appState.clearSuggestions()
            floatingPanel.hide()
        }
        appState.currentInput = trimmed
        lastSeenText = trimmed
        updateWatchedContext(source: "Key fallback", preview: trimmed)
        contextStatusPanel.refresh()
        scheduleSuggestion(for: trimmed)
        restartIdleNudgeTimer()
    }

    private func recordMouseActivity(_ location: CGPoint) {
        defer { lastObservedMouseLocation = location }
        guard let lastObservedMouseLocation else { return }
        let dx = location.x - lastObservedMouseLocation.x
        let dy = location.y - lastObservedMouseLocation.y
        guard hypot(dx, dy) > 2 else { return }
        guard lastCaretFrame != nil || !appState.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        restartIdleNudgeTimer()
    }

    private func frontmostProcessIdentifierChanged() -> Bool {
        let currentIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer { lastFrontmostProcessIdentifier = currentIdentifier }
        guard let currentIdentifier else { return false }
        guard let lastFrontmostProcessIdentifier else { return false }
        return currentIdentifier != lastFrontmostProcessIdentifier
    }

    private func resetFallbackText() {
        typedFallbackText = ""
        lastSeenText = ""
        lastCaretFrame = nil
        lastIdleNudgeText = ""
        idleTask?.cancel()
    }

    private func ignoredFrontmostApplicationReason() -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleIdentifier = frontmostApplication.bundleIdentifier ?? ""
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return "Where-to-vibe settings are frontmost"
        }

        if ignoredApplicationBundleIdentifiers.contains(bundleIdentifier) {
            return "\(frontmostApplication.localizedName ?? "This app") is excluded"
        }

        return nil
    }

    private func isFrontmostAICodingApplication() -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let haystack = [
            frontmostApplication.localizedName,
            frontmostApplication.bundleIdentifier
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return aiCodingApplicationNameFragments.contains { haystack.contains($0) }
    }

    private func updateWatchedContext(source: String, preview rawPreview: String) {
        let trimmed = rawPreview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if trimmed.isEmpty {
            preview = "Focused input is empty"
        } else if trimmed.count > 80 {
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 80)
            preview = "\(trimmed[..<endIndex])..."
        } else {
            preview = trimmed
        }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        appState.updateWatchedContext(
            appName: frontmostApplication?.localizedName ?? "Unknown app",
            bundleIdentifier: frontmostApplication?.bundleIdentifier ?? "unknown",
            source: source,
            preview: preview
        )
    }
}
