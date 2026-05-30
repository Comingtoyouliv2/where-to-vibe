import AppKit
import Combine
import SwiftUI

private final class PromptCoachPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingSuggestionPanel {
    private let appState: AppState
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private let panelSize = CGSize(width: 360, height: 260)

    // Cursor-follow: while the panel is visible, a 60Hz timer eases the panel
    // toward the mouse so it glides with the cursor instead of jumping to a
    // new spot each time the advice updates.
    private var cursorFollowTimer: Timer?
    private var smoothedPanelOrigin: CGPoint?
    /// Per-tick easing factor. Lower = floatier, higher = snappier. 0.18 at
    /// 60Hz catches up to the cursor in a few frames without feeling rigid.
    private let cursorFollowEaseFactor: CGFloat = 0.18

    init(appState: AppState) {
        self.appState = appState
        observeState()
    }

    func show(anchor: CGPoint) {
        guard appState.shouldShowSuggestionPanel else {
            // Pinpoint exactly which sub-condition is false so the console says
            // why the panel is being suppressed at the very last step.
            let reasons: [String] = [
                appState.isEnabled ? nil : "isEnabled=false",
                appState.hasAccessibilityPermission ? nil : "hasAccessibilityPermission=false",
                appState.selectedSuggestion != nil ? nil : "selectedSuggestion=nil (suggestions array is empty)"
            ].compactMap { $0 }
            print("[Coach/Panel] GATE: shouldShowSuggestionPanel=false → hide(). Failed: \(reasons.joined(separator: ", "))")
            hide()
            return
        }

        ensurePanel()
        positionPanel(near: anchor)
        panel?.orderFrontRegardless()
        startCursorFollow()
        let frame = panel?.frame ?? .zero
        print("[Coach/Panel] show() at frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))) isVisible=\(panel?.isVisible == true)")
    }

    func hide() {
        if panel?.isVisible == true {
            print("[Coach/Panel] hide() — was visible.")
        }
        stopCursorFollow()
        panel?.orderOut(nil)
    }

    private func observeState() {
        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.panel?.contentView?.needsLayout = true
                }
            }
            .store(in: &cancellables)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = FloatingSuggestionPanelView(appState: appState)
            .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let newPanel = PromptCoachPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hostingView
        panel = newPanel
    }

    private func positionPanel(near anchor: CGPoint) {
        guard let panel else { return }
        let size = panel.contentView?.fittingSize ?? CGSize(width: 360, height: 168)
        let layoutSize = CGSize(
            width: max(size.width, panelSize.width),
            height: max(size.height, panelSize.height)
        )
        let origin = panelOrigin(forSize: layoutSize, near: anchor)
        panel.setFrame(NSRect(origin: origin, size: layoutSize), display: true)
        // Seed the smoothed origin so the follow timer eases from here rather
        // than snapping on its first tick.
        smoothedPanelOrigin = origin
    }

    /// Clamped top-anchored origin for a panel of `size` placed next to
    /// `anchor` (screen coords). Factored out of positionPanel so the
    /// cursor-follow timer can reuse the exact same offset + clamp rules.
    private func panelOrigin(forSize size: CGSize, near anchor: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        var origin = CGPoint(x: anchor.x + 18, y: anchor.y - size.height - 10)
        if origin.x + size.width > screenFrame.maxX - 10 {
            origin.x = anchor.x - size.width - 18
        }
        if origin.y < screenFrame.minY + 10 {
            origin.y = anchor.y + 20
        }
        origin.x = min(max(origin.x, screenFrame.minX + 10), screenFrame.maxX - size.width - 10)
        origin.y = min(max(origin.y, screenFrame.minY + 10), screenFrame.maxY - size.height - 10)
        return origin
    }

    // MARK: - Cursor follow

    /// Starts the 60Hz timer that eases the panel toward the mouse while it's
    /// visible. Added in `.common` run-loop mode so it keeps animating during
    /// scrolling / event tracking. Idempotent.
    private func startCursorFollow() {
        guard cursorFollowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cursorFollowTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorFollowTimer = timer
    }

    private func stopCursorFollow() {
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
        smoothedPanelOrigin = nil
    }

    /// One eased step toward the cursor. Moves only the origin (never resizes)
    /// so it's cheap, and skips sub-pixel moves to avoid compositing churn.
    private func cursorFollowTick() {
        guard let panel, panel.isVisible else { return }
        let targetOrigin = panelOrigin(forSize: panel.frame.size, near: NSEvent.mouseLocation)
        let current = smoothedPanelOrigin ?? panel.frame.origin
        let next = CGPoint(
            x: current.x + (targetOrigin.x - current.x) * cursorFollowEaseFactor,
            y: current.y + (targetOrigin.y - current.y) * cursorFollowEaseFactor
        )
        smoothedPanelOrigin = next
        if abs(next.x - panel.frame.origin.x) > 0.1 || abs(next.y - panel.frame.origin.y) > 0.1 {
            panel.setFrameOrigin(next)
        }
    }
}

private final class PromptCoachContextPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ContextStatusPanel {
    private let appState: AppState
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private let panelSize = CGSize(width: 286, height: 76)

    init(appState: AppState) {
        self.appState = appState
        observeState()
    }

    func refresh() {
        guard appState.isEnabled, appState.contextHUDEnabled, appState.hasAccessibilityPermission else {
            hide()
            return
        }

        ensurePanel()
        positionBottomRight()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func observeState() {
        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.panel?.contentView?.needsLayout = true
                }
            }
            .store(in: &cancellables)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = ContextStatusPanelView(appState: appState)
            .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let newPanel = PromptCoachContextPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hostingView
        panel = newPanel
    }

    private func positionBottomRight() {
        guard let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let origin = CGPoint(
            x: screenFrame.maxX - panelSize.width - 18,
            y: screenFrame.minY + 18
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }
}

private struct ContextStatusPanelView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(.white.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Watching")
                        .foregroundStyle(.white.opacity(0.50))
                    Text(appState.watchedAppName)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 0)
                    Text(appState.promptLanguage.menuTitle)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(size: 10, weight: .medium))

                Text(appState.watchedContextPreview)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(appState.watchedContextSource)
                    Text("\(appState.currentInput.count) chars")
                    Text("\(appState.effectiveUserLevel.shortLabel) · \(appState.effectivePromptEvolutionStage.displayName)")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 286, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.52))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        )
    }
}

struct FloatingSuggestionPanelView: View {
    @ObservedObject var appState: AppState
    @StateObject private var typingModel = CoachTypingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                coachGlyph

                VStack(alignment: .leading, spacing: 7) {
                    if !typingModel.visibleReason.isEmpty {
                        Text(typingModel.visibleReason)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !typingModel.visibleSuggestion.isEmpty {
                        Text(typingModel.visibleSuggestion)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if typingModel.isTyping {
                        typingCursor
                    }

                    // Beginner-only one-line lesson explaining WHY this is a better prompt.
                    // We surface this under the suggestion (not at the top) so it reads
                    // as a footnote, not as the headline. Hidden for Intermediate /
                    // Advanced because we don't want to patronize them.
                    if typingModel.hasFinished,
                       let lesson = appState.selectedSuggestion?.microLesson,
                       !lesson.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.yellow.opacity(0.78))
                                .padding(.top, 2)
                            Text(lesson)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.white.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            if typingModel.hasFinished {
                HStack(spacing: 8) {
                    if hasCopyableAdvice {
                        acceptAffordance
                    }
                    Text("Esc")
                        .foregroundStyle(.white.opacity(0.45))
                    Text("dismiss")
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Text("\(appState.effectiveUserLevel.shortLabel) · \(appState.effectivePromptEvolutionStage.displayName)")
                        .foregroundStyle(.white.opacity(0.45))
                    Text(appState.suggestionMode.displayName)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.74))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: typingModel.visibleReason)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: typingModel.visibleSuggestion)
        .animation(.easeOut(duration: 0.16), value: typingModel.hasFinished)
        .onAppear {
            configureTyping()
        }
        .onChange(of: appState.selectedSuggestion?.id) { _ in
            configureTyping()
        }
        .onChange(of: appState.lastReason) { _ in
            configureTyping()
        }
    }

    // Renders the accept hint only for suggestions that are safe to insert into
    // the user's focused draft. Advisory cards are read-only and dismiss with Esc.
    /// True when there's something Tab can copy — mirrors the controller's
    /// `copyableAdviceText`: the rewrite (`text`) if present, else the reason.
    private var hasCopyableAdvice: Bool {
        guard let suggestion = appState.selectedSuggestion else { return false }
        if !suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let reason = (appState.lastReason ?? suggestion.reason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !reason.isEmpty
    }

    @ViewBuilder
    private var acceptAffordance: some View {
        // Tab now copies whatever advice is on screen (the rewrite, or the
        // reason/question when there's no rewrite), so always show the hint
        // when a suggestion is up — including question-style advice. This is
        // why the "Tab" hint had disappeared: question intents used to render
        // EmptyView here.
        KeyCap("Tab")
        Text("copy")
    }

    private var coachGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 20, height: 20)
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var typingCursor: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(.white.opacity(0.72))
            .frame(width: 5, height: 13)
            .padding(.top, 1)
    }

    private func configureTyping() {
        guard let suggestion = appState.selectedSuggestion else {
            typingModel.clear()
            return
        }

        let reason = appState.lastReason ?? "This could be more specific."
        typingModel.start(
            id: suggestion.id,
            reason: conversationalReason(reason),
            suggestion: "Try this: \(suggestion.text)"
        )
    }

    private func conversationalReason(_ reason: String) -> String {
        if reason.hasSuffix(".") {
            return reason
        }
        return "\(reason)."
    }
}

@MainActor
private final class CoachTypingModel: ObservableObject {
    @Published var visibleReason = ""
    @Published var visibleSuggestion = ""
    @Published var hasFinished = false

    var isTyping: Bool { !hasFinished }

    private var currentID: UUID?
    private var targetReason = ""
    private var targetSuggestion = ""
    private var timer: Timer?
    private var phase: Phase = .reason

    private enum Phase {
        case reason
        case pauseBeforeSuggestion
        case suggestion
        case done
    }

    func start(id: UUID, reason: String, suggestion: String) {
        guard currentID != id || targetReason != reason || targetSuggestion != suggestion else { return }

        currentID = id
        targetReason = reason
        targetSuggestion = suggestion
        visibleReason = ""
        visibleSuggestion = ""
        hasFinished = false
        phase = .reason

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.014, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        currentID = nil
        targetReason = ""
        targetSuggestion = ""
        visibleReason = ""
        visibleSuggestion = ""
        hasFinished = false
        phase = .done
    }

    private func tick() {
        switch phase {
        case .reason:
            if visibleReason.count < targetReason.count {
                appendNextCharacter(from: targetReason, to: &visibleReason)
            } else {
                phase = .pauseBeforeSuggestion
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.phase = .suggestion
                        self?.timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                            Task { @MainActor in
                                self?.tick()
                            }
                        }
                    }
                }
            }

        case .pauseBeforeSuggestion:
            break

        case .suggestion:
            if visibleSuggestion.count < targetSuggestion.count {
                appendNextCharacter(from: targetSuggestion, to: &visibleSuggestion)
            } else {
                phase = .done
                hasFinished = true
                timer?.invalidate()
                timer = nil
            }

        case .done:
            timer?.invalidate()
            timer = nil
        }
    }

    private func appendNextCharacter(from source: String, to destination: inout String) {
        let index = source.index(source.startIndex, offsetBy: destination.count)
        destination.append(source[index])
    }
}

private struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
            )
    }
}
