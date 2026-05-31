import AppKit
import Combine
import SwiftUI

private final class PromptCoachPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum FloatingSuggestionLayout {
    static let panelWidth: CGFloat = 420
    static let contentWidth: CGFloat = 398
    static let minimumHeight: CGFloat = 120
    static let fallbackHeight: CGFloat = 260
    static let screenPadding: CGFloat = 10
    static let maximumScreenHeightRatio: CGFloat = 0.86
}

private enum FloatingSuggestionVerticalPlacement {
    case below
    case above
}

private enum FloatingSuggestionHorizontalPlacement {
    case right
    case left
}

@MainActor
final class FloatingSuggestionPanel {
    private let appState: AppState
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    // The panel is pinned where it first appears and does NOT follow the mouse.
    // Continuously chasing the cursor at 60fps made the card shiver up and down
    // while advice streamed in (mouse-sensor noise was baked into the position
    // every frame, and the constant re-layout fought the growing content). The
    // card now stays put; only its height grows as text streams, anchored at
    // the spot captured when it opened.
    private var panelAnchor: CGPoint?
    private var verticalPlacement: FloatingSuggestionVerticalPlacement = .below
    private var horizontalPlacement: FloatingSuggestionHorizontalPlacement = .right
    private var renderedPanelHeight: CGFloat = FloatingSuggestionLayout.minimumHeight

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
        let visibleAnchor = normalizedAnchor(anchor)
        let wasVisible = panel?.isVisible == true
        if panelAnchor == nil {
            panelAnchor = visibleAnchor
        }
        if !wasVisible {
            renderedPanelHeight = FloatingSuggestionLayout.minimumHeight
            lockPlacement(near: panelAnchor ?? visibleAnchor)
            positionPanel(near: panelAnchor ?? visibleAnchor)
            panel?.orderFrontRegardless()
            panel?.displayIfNeeded()
        }
        // The panel is pinned at panelAnchor; it never follows the cursor.
        // Height changes from streaming content are applied in place by
        // contentSizeDidChange, so there is nothing to do here when re-shown.
        let frame = panel?.frame ?? .zero
        print("[Coach/Panel] show() anchor=(\(Int(anchor.x)),\(Int(anchor.y))) normalized=(\(Int(visibleAnchor.x)),\(Int(visibleAnchor.y))) frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))) isVisible=\(panel?.isVisible == true)")
    }

    func hide() {
        if panel?.isVisible == true {
            print("[Coach/Panel] hide() — was visible.")
        }
        panelAnchor = nil
        verticalPlacement = .below
        horizontalPlacement = .right
        renderedPanelHeight = FloatingSuggestionLayout.minimumHeight
        panel?.orderOut(nil)
    }

    private func observeState() {
        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    guard let self else { return }
                    self.panel?.contentView?.needsLayout = true
                }
            }
            .store(in: &cancellables)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = FloatingSuggestionPanelView(
            appState: appState,
            onContentSizeChange: { [weak self] size in
                Task { @MainActor in
                    self?.contentSizeDidChange(size)
                }
            }
        )
            .frame(width: FloatingSuggestionLayout.panelWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(
            origin: .zero,
            size: CGSize(
                width: FloatingSuggestionLayout.panelWidth,
                height: FloatingSuggestionLayout.minimumHeight
            )
        )
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
        let visibleAnchor = normalizedAnchor(anchor)
        // Remember the exact anchor the card opened at so later height growth
        // resizes against the same fixed point instead of the live cursor.
        panelAnchor = visibleAnchor
        let layoutSize = panelSize(forContentHeight: renderedPanelHeight, near: visibleAnchor)
        let origin = panelOrigin(forSize: layoutSize, near: visibleAnchor)
        panel.setFrame(NSRect(origin: origin, size: layoutSize), display: true)
    }

    private func contentSizeDidChange(_ size: CGSize) {
        guard let panel, panel.isVisible else { return }
        let measuredHeight = ceil(size.height)
        guard measuredHeight.isFinite, measuredHeight > 0 else { return }

        // Grow with the typed content. Do not shrink while visible; shrinking
        // during the typewriter reset reads as the panel being reloaded.
        let nextHeight = max(renderedPanelHeight, measuredHeight)
        guard abs(nextHeight - renderedPanelHeight) > 0.5 else { return }
        renderedPanelHeight = nextHeight

        // Resize in place, pinned to the fixed open-anchor. The top edge stays
        // put and the card extends downward — no cursor sampling, no per-frame
        // timer, so streaming content can never make the panel tremble.
        let anchor = panelAnchor ?? normalizedAnchor(NSEvent.mouseLocation)
        let layoutSize = panelSize(forContentHeight: nextHeight, near: anchor)
        let origin = panelOrigin(forSize: layoutSize, near: anchor)
        panel.setFrame(NSRect(origin: origin, size: layoutSize), display: true)
    }

    private func lockPlacement(near anchor: CGPoint) {
        let size = panelSize(forContentHeight: renderedPanelHeight, near: anchor)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        verticalPlacement = anchor.y - size.height - 10 >= screenFrame.minY + FloatingSuggestionLayout.screenPadding
            ? .below
            : .above
        horizontalPlacement = anchor.x + 18 + size.width <= screenFrame.maxX - FloatingSuggestionLayout.screenPadding
            ? .right
            : .left
    }

    private func normalizedAnchor(_ anchor: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -160, dy: -160).contains(anchor) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -160, dy: -160).contains(anchor) }
            ?? NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -160, dy: -160).contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return NSEvent.mouseLocation }

        let frame = screen.visibleFrame
        let fallback = frame.contains(NSEvent.mouseLocation)
            ? NSEvent.mouseLocation
            : CGPoint(x: frame.midX, y: frame.midY)
        let candidate = anchor.x.isFinite && anchor.y.isFinite ? anchor : fallback

        return CGPoint(
            x: min(max(candidate.x, frame.minX + FloatingSuggestionLayout.screenPadding), frame.maxX - FloatingSuggestionLayout.screenPadding),
            y: min(max(candidate.y, frame.minY + FloatingSuggestionLayout.screenPadding), frame.maxY - FloatingSuggestionLayout.screenPadding)
        )
    }

    private func panelSize(forContentHeight contentHeight: CGFloat, near anchor: CGPoint) -> CGSize {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let maximumHeight = max(
            FloatingSuggestionLayout.minimumHeight,
            (screenFrame.height - FloatingSuggestionLayout.screenPadding * 2)
                * FloatingSuggestionLayout.maximumScreenHeightRatio
        )

        let fittingHeight = contentHeight.isFinite && contentHeight > 0
            ? contentHeight
            : FloatingSuggestionLayout.minimumHeight
        let clampedHeight = min(
            maximumHeight,
            max(FloatingSuggestionLayout.minimumHeight, fittingHeight)
        )
        return CGSize(width: FloatingSuggestionLayout.panelWidth, height: clampedHeight)
    }

    /// Clamped top-anchored origin for a panel of `size` placed next to
    /// `anchor` (screen coords). Factored out of positionPanel so the
    /// cursor-follow timer can reuse the exact same offset + clamp rules.
    private func panelOrigin(forSize size: CGSize, near anchor: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        var origin = CGPoint(
            x: horizontalPlacement == .right
                ? anchor.x + 18
                : anchor.x - size.width - 18,
            y: verticalPlacement == .below
                ? anchor.y - size.height - 10
                : anchor.y + 20
        )

        if origin.x + size.width > screenFrame.maxX - FloatingSuggestionLayout.screenPadding {
            origin.x = screenFrame.maxX - size.width - FloatingSuggestionLayout.screenPadding
        }
        if origin.y < screenFrame.minY + FloatingSuggestionLayout.screenPadding {
            origin.y = screenFrame.minY + FloatingSuggestionLayout.screenPadding
        }
        let minimumX = screenFrame.minX + FloatingSuggestionLayout.screenPadding
        let maximumX = max(minimumX, screenFrame.maxX - size.width - FloatingSuggestionLayout.screenPadding)
        let minimumY = screenFrame.minY + FloatingSuggestionLayout.screenPadding
        let maximumY = max(minimumY, screenFrame.maxY - size.height - FloatingSuggestionLayout.screenPadding)
        origin.x = min(max(origin.x, minimumX), maximumX)
        origin.y = min(max(origin.y, minimumY), maximumY)
        return origin
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

@MainActor
private enum FloatingSuggestionCopy {
    static func reason(for appState: AppState) -> String {
        let isKorean = appState.promptLanguage == .korean
        let fallback = isKorean ? "조금 더 구체적으로 해볼까요?" : "This could be more specific."
        return conversationalReason(appState.lastReason ?? appState.selectedSuggestion?.reason ?? fallback)
    }

    static func suggestionLine(for appState: AppState) -> String {
        guard let suggestion = appState.selectedSuggestion else { return "" }
        let rewrite = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewrite.isEmpty else { return "" }
        return appState.promptLanguage == .korean
            ? "저라면 이렇게 써볼 것 같아요:\n\(rewrite)"
            : "Here's how I'd write it:\n\(rewrite)"
    }

    static func hasCopyableAdvice(for appState: AppState) -> Bool {
        guard let suggestion = appState.selectedSuggestion else { return false }
        if !suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let reason = (appState.lastReason ?? suggestion.reason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !reason.isEmpty
    }

    private static func conversationalReason(_ reason: String) -> String {
        if reason.hasSuffix(".") || reason.hasSuffix("?") || reason.hasSuffix("!") {
            return reason
        }
        return "\(reason)."
    }
}

@MainActor
struct FloatingSuggestionPanelView: View {
    @ObservedObject var appState: AppState
    let onContentSizeChange: @Sendable (CGSize) -> Void
    @StateObject private var typingModel = CoachTypingModel()

    var body: some View {
        let reportContentSize = onContentSizeChange

        VStack(alignment: .leading, spacing: 9) {
            // Gap-first teaching: name the dimensions the user's draft is missing
            // BEFORE showing the rewrite, so they learn the checklist instead of
            // just copying a finished answer.
            if !appState.missingAxes.isEmpty {
                missingAxesCallout
            }

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
        .frame(width: FloatingSuggestionLayout.contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        // While the typewriter appends a character every ~14ms, a springy
        // height animation never settles — each new character restarts the
        // spring (plus its overshoot), so the panel's measured height jitters
        // and the window faithfully reproduces that jitter as a visible
        // tremble. A short, non-bouncy easeOut lets the panel grow smoothly
        // line-by-line without the shake.
        .animation(.easeOut(duration: 0.12), value: typingModel.visibleReason)
        .animation(.easeOut(duration: 0.12), value: typingModel.visibleSuggestion)
        .animation(.easeOut(duration: 0.16), value: typingModel.hasFinished)
        .onAppear {
            configureTyping()
        }
        .onChange(of: appState.selectedSuggestion?.id) { _, _ in
            configureTyping()
        }
        .onChange(of: appState.lastReason) { _, _ in
            configureTyping()
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: FloatingSuggestionContentSizePreferenceKey.self,
                        value: proxy.size
                    )
            }
        )
        .onPreferenceChange(FloatingSuggestionContentSizePreferenceKey.self) { size in
            reportContentSize(size)
        }
    }

    // Renders the accept hint only for suggestions that are safe to insert into
    // the user's focused draft. Advisory cards are read-only and dismiss with Esc.
    /// True when there's something Tab can copy — mirrors the controller's
    /// `copyableAdviceText`: the rewrite (`text`) if present, else the reason.
    private var hasCopyableAdvice: Bool {
        FloatingSuggestionCopy.hasCopyableAdvice(for: appState)
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

    // Gap-first checklist shown above the rewrite. Lists the missing dimensions
    // (max 4, two per row) so the user learns the prompt checklist by name.
    private var missingAxesCallout: some View {
        let axes = Array(appState.missingAxes.prefix(4))
        let isKorean = appState.promptLanguage == .korean
        let rows = stride(from: 0, to: axes.count, by: 2).map { start in
            Array(axes[start..<min(start + 2, axes.count)])
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.85))
                Text(isKorean ? "이걸 채우면 바로 실행돼요" : "Add these to make it buildable")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(rows[rowIndex], id: \.self) { axis in
                        missingAxisChip(axis, isKorean: isKorean)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.cyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func missingAxisChip(_ axis: String, isKorean: Bool) -> some View {
        HStack(spacing: 4) {
            Text(Self.axisIcon(axis))
                .font(.system(size: 10))
            Text(Self.axisLabel(axis, isKorean: isKorean))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.white.opacity(0.07))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }

    private static func axisIcon(_ axis: String) -> String {
        switch axis {
        case "goal": return "🎯"
        case "scope": return "🧩"
        case "target user": return "👤"
        case "success criteria": return "✅"
        case "constraints": return "⛔️"
        case "context": return "🧭"
        default: return "•"
        }
    }

    // Domain-neutral labels: these are about clarifying ANY piece of writing, not
    // just software. Avoid product jargon like "target user" / "success criteria".
    private static func axisLabel(_ axis: String, isKorean: Bool) -> String {
        if isKorean {
            switch axis {
            case "goal": return "목표"
            case "scope": return "범위"
            case "target user": return "누구를 위한지"
            case "success criteria": return "좋은 결과 기준"
            case "constraints": return "제약"
            case "context": return "맥락"
            default: return axis
            }
        }
        switch axis {
        case "target user": return "who it's for"
        case "success criteria": return "what 'good' means"
        default: return axis
        }
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

        typingModel.start(
            id: suggestion.id,
            reason: FloatingSuggestionCopy.reason(for: appState),
            suggestion: FloatingSuggestionCopy.suggestionLine(for: appState)
        )
    }
}

private struct FloatingSuggestionContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
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
