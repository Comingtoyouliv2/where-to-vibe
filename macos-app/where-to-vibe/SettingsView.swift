import AppKit
import SwiftUI

/// Minimal menu-bar panel. We intentionally surface only what a user actually
/// needs to deal with:
///   • OpenAI API Key (for screen-aware coaching)
///   • Accessibility permission (required to read focused text + intercept Tab)
///   • Quit
///
/// Everything else (language, learning level, prompt-evolution, suggestion
/// mode, debug keys, watching HUD …) is auto-handled and hidden so the panel
/// stays calm and beginner-friendly.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                Text("Where-to-vibe")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            Divider()

            // Prompt Coach on/off
            Toggle(isOn: $appState.isEnabled) {
                Text("Prompt Coach")
                    .font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)

            // Language (English / 한국어)
            VStack(alignment: .leading, spacing: 6) {
                Text("Language")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $appState.promptLanguage) {
                    ForEach(PromptLanguage.allCases) { language in
                        Text(language.menuTitle).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // OpenAI API Key
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI API Key")
                    .font(.system(size: 12, weight: .semibold))
                SecureField("sk-...", text: $appState.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("화면 인식 코칭에 사용돼요. 비워두면 로컬 모드로 동작합니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // System permission (Accessibility)
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
                    .pointerCursor()

                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .pointerCursor()
                }
            }

            Divider()

            // Quit
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
}
