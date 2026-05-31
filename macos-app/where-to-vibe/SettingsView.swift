import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    private var copy: SettingsCopy {
        SettingsCopy(language: appState.promptLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            primaryAction
            accessControl
            languageSection
            apiSection
            permissionSection
            footerActions
        }
        .padding(16)
        .background(panelBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(red: 0.93, green: 0.61, blue: 0.33).opacity(0.22))
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.45))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Where-to-vibe")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(copy.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }

                Spacer(minLength: 0)

                statusPill
            }

            HStack(spacing: 8) {
                metricPill(
                    title: copy.coachStatusTitle,
                    value: appState.isEnabled ? copy.on : copy.off,
                    color: appState.isEnabled ? .green : .orange
                )
                metricPill(
                    title: copy.apiStatusTitle,
                    value: appState.hasOpenAIAPIKey ? copy.saved : copy.empty,
                    color: appState.hasOpenAIAPIKey ? .cyan : .white.opacity(0.45)
                )
                metricPill(
                    title: copy.permissionStatusTitle,
                    value: appState.hasAccessibilityPermission ? copy.ready : copy.needed,
                    color: appState.hasAccessibilityPermission ? .green : .orange
                )
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(appState.isEnabled ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(appState.isEnabled ? copy.live : copy.paused)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.white.opacity(0.08))
                .overlay(Capsule().stroke(.white.opacity(0.11), lineWidth: 1))
        )
    }

    private var primaryAction: some View {
        Button {
            NotificationCenter.default.post(name: .startIdeaRefinement, object: nil)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.refineTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(copy.refineSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(13)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.86, green: 0.45, blue: 0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var accessControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(copy.accessTitle, systemImage: "hand.raised.fill")

            Button {
                appState.isEnabled.toggle()
                if appState.isEnabled {
                    _ = AccessibilityTextReader.hasPermission(prompt: true)
                    appState.refreshAccessibilityPermission()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: appState.isEnabled ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(appState.isEnabled ? .green : .orange)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.08)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.isEnabled ? copy.restrictAccess : copy.allowAccess)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(appState.isEnabled ? copy.accessOnDescription : copy.accessOffDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.58))
                    }

                    Spacer(minLength: 0)

                    Text(appState.isEnabled ? copy.on : copy.off)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(appState.isEnabled ? .green : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .padding(12)
                .background(cardBackground)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(copy.languageTitle, systemImage: "character.bubble.fill")
            Picker("", selection: $appState.promptLanguage) {
                ForEach(PromptLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
        .background(cardBackground)
    }

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(copy.apiTitle, systemImage: "key.fill")
                Spacer(minLength: 0)
                Label(copy.savedAutomatically, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(appState.hasOpenAIAPIKey ? .green : .white.opacity(0.38))
            }

            SecureField("sk-...", text: $appState.openAIAPIKey)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.26))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(appState.hasOpenAIAPIKey ? Color.green.opacity(0.32) : .white.opacity(0.12), lineWidth: 1)
                        )
                )

            Text(copy.apiHint)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(cardBackground)
    }

    private var permissionSection: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: appState.hasAccessibilityPermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appState.hasAccessibilityPermission ? .green : .orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.hasAccessibilityPermission ? copy.permissionGranted : copy.permissionRequired)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(copy.permissionHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer(minLength: 0)

            Button {
                openAccessibilitySettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(cardBackground)
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button {
                appState.refreshAccessibilityPermission()
            } label: {
                Label(copy.refresh, systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.74))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
            )
            .pointerCursor()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label(copy.quit, systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 1.0, green: 0.54, blue: 0.48))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.red.opacity(0.20), lineWidth: 1))
            )
            .pointerCursor()
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.58))
    }

    private func metricPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(red: 0.075, green: 0.078, blue: 0.088).opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.36), radius: 30, x: 0, y: 18)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SettingsCopy {
    let subtitle: String
    let live: String
    let paused: String
    let on: String
    let off: String
    let saved: String
    let empty: String
    let ready: String
    let needed: String
    let coachStatusTitle: String
    let apiStatusTitle: String
    let permissionStatusTitle: String
    let refineTitle: String
    let refineSubtitle: String
    let accessTitle: String
    let allowAccess: String
    let restrictAccess: String
    let accessOnDescription: String
    let accessOffDescription: String
    let languageTitle: String
    let apiTitle: String
    let savedAutomatically: String
    let apiHint: String
    let permissionGranted: String
    let permissionRequired: String
    let permissionHint: String
    let refresh: String
    let quit: String

    init(language: PromptLanguage) {
        switch language {
        case .english:
            subtitle = "Prompt clarity, quietly on your side"
            live = "LIVE"
            paused = "PAUSED"
            on = "On"
            off = "Off"
            saved = "Saved"
            empty = "Empty"
            ready = "Ready"
            needed = "Needed"
            coachStatusTitle = "Coach"
            apiStatusTitle = "API"
            permissionStatusTitle = "Access"
            refineTitle = "Refine an idea"
            refineSubtitle = "Turn a rough thought into an AI-ready prompt"
            accessTitle = "Access"
            allowAccess = "Allow coaching"
            restrictAccess = "Restrict coaching"
            accessOnDescription = "Where-to-vibe can watch prompt fields."
            accessOffDescription = "Paused. No prompt field watching."
            languageTitle = "Language"
            apiTitle = "OpenAI API Key"
            savedAutomatically = "Saved automatically"
            apiHint = "Saved privately on this Mac."
            permissionGranted = "Accessibility granted"
            permissionRequired = "Accessibility required"
            permissionHint = "Needed for focused text and Tab replacement."
            refresh = "Refresh"
            quit = "Quit"
        case .korean:
            subtitle = "막연한 생각을 선명한 프롬프트로"
            live = "실행 중"
            paused = "일시정지"
            on = "켜짐"
            off = "꺼짐"
            saved = "저장됨"
            empty = "비어 있음"
            ready = "준비됨"
            needed = "필요"
            coachStatusTitle = "코치"
            apiStatusTitle = "API"
            permissionStatusTitle = "접근"
            refineTitle = "아이디어 구체화"
            refineSubtitle = "막연한 생각을 AI가 이해할 프롬프트로"
            accessTitle = "접근"
            allowAccess = "코칭 허용"
            restrictAccess = "코칭 제한"
            accessOnDescription = "프롬프트 입력창을 보고 도와줄 수 있어요."
            accessOffDescription = "일시정지됨. 입력창을 보지 않아요."
            languageTitle = "언어"
            apiTitle = "OpenAI API Key"
            savedAutomatically = "자동 저장"
            apiHint = "이 Mac에 비공개로 저장됩니다."
            permissionGranted = "접근 권한 허용됨"
            permissionRequired = "접근 권한 필요"
            permissionHint = "텍스트 읽기와 Tab 교체에 필요해요."
            refresh = "새로고침"
            quit = "종료"
        }
    }
}
