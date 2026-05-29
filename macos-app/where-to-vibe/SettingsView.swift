import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where-to-vibe")
                        .font(.system(size: 15, weight: .semibold))
                    Text(appState.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $appState.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            Button {
                appState.isEnabled.toggle()
            } label: {
                Label(
                    appState.isEnabled ? "Pause coaching" : "Resume coaching",
                    systemImage: appState.isEnabled ? "pause.circle" : "play.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(appState.isEnabled ? .orange : .green)
            .pointerCursor()

            VStack(alignment: .leading, spacing: 8) {
                Text("Language")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $appState.promptLanguage) {
                    ForEach(PromptLanguage.allCases) { language in
                        Text(language.menuTitle).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Text(appState.promptLanguage == .english
                     ? "English mode reads and rewrites prompts in English."
                     : "한국어 모드는 입력을 한국어 기준으로 판단하고 한국어로 조언합니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Watching")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    Text(appState.watchedAppName)
                        .font(.system(size: 11, weight: .medium))
                    Text(appState.watchedContextSource)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(appState.watchedContextPreview)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(appState.watchedAppBundleIdentifier)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Learning level")
                    .font(.system(size: 12, weight: .semibold))
                Toggle("Auto detect from current prompt", isOn: $appState.autoDetectLearningProfile)
                    .font(.system(size: 11, weight: .medium))
                Picker("", selection: $appState.userLevel) {
                    ForEach(UserLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.autoDetectLearningProfile)
                Text(levelHelperText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt evolution")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $appState.promptEvolutionStage) {
                    ForEach(PromptEvolutionStage.allCases) { stage in
                        Text(stage.displayName).tag(stage)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.autoDetectLearningProfile)
                Text(stageHelperText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PromptEvolutionPanel(appState: appState)

            AgentTransitionCard(appState: appState)

            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestion mode")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $appState.suggestionMode) {
                    ForEach(SuggestionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(appState.hasOpenAIAPIKey
                     ? "Local is instant. Fast AI and High Quality AI use OpenAI for screen-aware rewrites."
                     : "Local is instant. Add an OpenAI key below to enable Fast AI and High Quality AI.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI API Key")
                    .font(.system(size: 12, weight: .semibold))
                SecureField("sk-...", text: $appState.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Fast AI and High Quality AI use the focused text plus a small screen snapshot when this key is set.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    appState.hasAccessibilityPermission ? "Accessibility granted" : "Accessibility required",
                    systemImage: appState.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appState.hasAccessibilityPermission ? .green : .orange)

                HStack {
                    Button("Request Permission") {
                        _ = AccessibilityTextReader.hasPermission(prompt: true)
                        appState.refreshAccessibilityPermission()
                    }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Keys")
                    .font(.system(size: 12, weight: .semibold))
                Toggle("Suggest next step after 3s idle", isOn: $appState.idleCoachEnabled)
                    .font(.system(size: 11, weight: .medium))
                Toggle("Show context HUD", isOn: $appState.contextHUDEnabled)
                    .font(.system(size: 11, weight: .medium))
                Text(appState.idleDebugText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    appState.requestIdleNudgeTest()
                } label: {
                    Label("Test idle bubble", systemImage: "timer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Tab accepts the rewrite. Esc dismisses. Arrow keys stay with the app you are typing in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Where-to-vibe", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .pointerCursor()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 12)
        )
    }

    private var levelHelperText: String {
        if appState.autoDetectLearningProfile {
            let level = appState.effectiveUserLevel.displayName
            let reason = appState.inferredProfileReason.isEmpty
                ? (appState.promptLanguage == .korean ? "입력을 보면 자동으로 바뀝니다." : "Updates as you type.")
                : appState.inferredProfileReason
            return appState.promptLanguage == .korean
                ? "자동 감지: \(level). \(reason)"
                : "Detected: \(level). \(reason)"
        }

        return appState.userLevel.guidanceCopy(language: appState.promptLanguage)
    }

    private var stageHelperText: String {
        if appState.autoDetectLearningProfile {
            let stage = appState.effectivePromptEvolutionStage.displayName
            return appState.promptLanguage == .korean
                ? "현재 단계: \(stage)"
                : "Current stage: \(stage)"
        }

        return appState.promptLanguage == .korean
            ? "수동으로 코칭 단계를 고릅니다."
            : "Manually choose the coaching stage."
    }
}

private struct PromptEvolutionPanel: View {
    @ObservedObject var appState: AppState
    @State private var copiedPrompt = false

    private var currentStage: PromptEvolutionStage {
        appState.effectivePromptEvolutionStage
    }

    private var targetStage: PromptEvolutionStage {
        currentStage.next ?? .agentWorkflow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Evolution")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Next: \(targetStage.displayName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                ForEach(PromptEvolutionStage.allCases) { stage in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(color(for: stage))
                            .frame(width: 9, height: 9)
                        Text(stage.shortName)
                            .font(.system(size: 9, weight: stage == currentStage ? .semibold : .regular))
                            .foregroundStyle(stage == currentStage ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityLabel("Prompt evolution progress")

            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                copyNextStepPrompt()
            } label: {
                Label(copiedPrompt ? "Copied" : buttonTitle, systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var buttonTitle: String {
        targetStage == .agentWorkflow ? "Copy agent prompt" : "Copy next-step prompt"
    }

    private var explanation: String {
        if appState.promptLanguage == .korean {
            return "\(currentStage.displayName) 단계에서 \(targetStage.displayName) 단계로 넘어갈 준비를 도와줍니다."
        }
        return "Helps move from \(currentStage.displayName) into \(targetStage.displayName)."
    }

    private func color(for stage: PromptEvolutionStage) -> Color {
        guard let stageIndex = PromptEvolutionStage.allCases.firstIndex(of: stage),
              let currentIndex = PromptEvolutionStage.allCases.firstIndex(of: currentStage) else {
            return .secondary.opacity(0.35)
        }

        if stageIndex < currentIndex {
            return .green.opacity(0.85)
        }
        if stageIndex == currentIndex {
            return .accentColor
        }
        return .secondary.opacity(0.28)
    }

    private func copyNextStepPrompt() {
        let prompt = targetStage.nextStepPrompt(
            seed: appState.currentInput,
            userLevel: appState.effectiveUserLevel,
            language: appState.promptLanguage
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        copiedPrompt = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copiedPrompt = false
        }
    }
}

private struct AgentTransitionCard: View {
    @ObservedObject var appState: AppState
    @State private var copiedPrompt = false

    private var shouldRecommendAgent: Bool {
        appState.effectiveUserLevel == .advanced
            || appState.effectivePromptEvolutionStage == .agentWorkflow
            || appState.effectivePromptEvolutionStage.next == .agentWorkflow
    }

    var body: some View {
        if shouldRecommendAgent {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Agent transition")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(appState.effectivePromptEvolutionStage.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $appState.preferredAgentTool) {
                    ForEach(AgentTool.allCases) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .pickerStyle(.menu)

                Text(appState.preferredAgentTool.recommendedUse(language: appState.promptLanguage))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyAgentPrompt()
                } label: {
                    Label(copiedPrompt ? "Copied" : "Copy agent handoff", systemImage: copiedPrompt ? "checkmark" : "arrowshape.turn.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                    )
            )
        }
    }

    private var message: String {
        if appState.promptLanguage == .korean {
            return "이 단계부터는 단일 채팅보다 파일시스템을 읽는 coding agent가 더 적합할 수 있습니다."
        }
        return "At this stage, a filesystem-aware coding agent may be a better fit than a single chat."
    }

    private func copyAgentPrompt() {
        let prompt = appState.preferredAgentTool.transitionPrompt(
            task: appState.currentInput,
            language: appState.promptLanguage
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        copiedPrompt = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copiedPrompt = false
        }
    }
}
