//
//  IntroSequenceController.swift
//  where-to-vibe
//
//  First-launch (currently every-launch, for dev) interactive intro.
//
//  Flow:
//   1. A chat card types a short introduction.
//   2. The user picks which AI they use (Claude / Codex / GPT) — clickable.
//   3. A SIMULATED chat window for that AI appears (mock, in our overlay).
//   4. The companion "types" a vague prompt ("앱을 만들어줘") into it.
//   5. A SIMULATED advice bubble appears inside the tutorial overlay.
//      The live mouse-side coach starts only after the tutorial fully finishes.
//   6. A finale chat ("같이 함께 만들어봐요") wraps it up.
//
//  Everything is simulated inside our own transparent overlay window — no
//  external app is launched and the user's real cursor/focus is never touched.
//  Additive only: does not touch the suggestion / Tab path.
//

import AppKit
import SwiftUI

/// The AI options offered in the intro.
enum IntroAI: String, CaseIterable, Identifiable {
    case claude = "Claude"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Asset-catalog image name for the real brand logo. Add an image set named
    /// "logo-claude" (the official Claude logo) to Assets.xcassets. Until it's
    /// present we fall back to `systemImage` so the build still renders.
    var logoAssetName: String { "logo-claude" }

    /// Fallback glyph used only when the logo asset is missing.
    var systemImage: String { "sparkle" }

    var tint: Color { Color(red: 0.85, green: 0.55, blue: 0.30) } // warm Claude orange
}

@MainActor
final class IntroSequenceController {
    private weak var menuBarController: MenuBarController?
    private let accessibilityOnboarder: AccessibilityPermissionOnboarder
    private let model = IntroSequenceModel()
    private var overlayWindow: NSWindow?
    private var sequenceTask: Task<Void, Never>?
    /// Resumed when the user taps an AI choice.
    private var selectionContinuation: CheckedContinuation<IntroAI, Never>?
    /// Called exactly once when the intro ends (naturally or via stop()). The
    /// host uses this to pause the live coach during the tutorial and resume.
    var onFinished: (() -> Void)?
    private var didFinish = false

    init(menuBarController: MenuBarController, accessibilityOnboarder: AccessibilityPermissionOnboarder) {
        self.menuBarController = menuBarController
        self.accessibilityOnboarder = accessibilityOnboarder
    }

    func play() -> Bool {
        guard overlayWindow == nil else { return false }
        guard let screen = NSScreen.main else { return false }
        buildOverlay(on: screen)
        sequenceTask = Task { @MainActor in
            await runSequence(on: screen)
        }
        return true
    }

    func stop() {
        // Resume any pending selection so the suspended sequence can unwind.
        if let continuation = selectionContinuation {
            selectionContinuation = nil
            continuation.resume(returning: .claude)
        }
        sequenceTask?.cancel()
        sequenceTask = nil
        finishIntro()
    }

    /// Tears down the overlay and notifies the host exactly once.
    private func finishIntro() {
        teardown()
        guard !didFinish else { return }
        didFinish = true
        onFinished?()
    }

    // MARK: - Overlay window

    private func buildOverlay(on screen: NSScreen) {
        let window = IntroOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true  // toggled to false only during the choice step
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)

        let hostingView = NSHostingView(
            rootView: IntroOverlayView(
                model: model,
                screenSize: screen.frame.size,
                refinedPrompt: Self.demoRefinedPrompt,
                onSelectAI: { [weak self] ai in self?.selectAI(ai) }
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        window.orderFrontRegardless()
        overlayWindow = window
    }

    private func teardown() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    /// Lets clicks reach the overlay (for the choice buttons) or pass through.
    private func setInteractive(_ interactive: Bool) {
        model.acceptsInput = interactive
        // When interactive we also become key so the buttons highlight, but we
        // stay a non-activating panel so we don't steal the user's app focus.
        overlayWindow?.ignoresMouseEvents = !interactive
    }

    private func selectAI(_ ai: IntroAI) {
        guard let continuation = selectionContinuation else { return }
        selectionContinuation = nil
        continuation.resume(returning: ai)
    }

    // MARK: - Sequence

    private func runSequence(on screen: NSScreen) async {
        // 1) Intro card types in.
        withAnimation(.easeOut(duration: 0.45)) { model.introOpacity = 1 }
        await typeIntro(Self.introText)
        if Task.isCancelled { return }
        await sleep(3.5)

        // 2) Swap intro for the AI picker, and make the overlay clickable.
        withAnimation(.easeInOut(duration: 0.35)) {
            model.introOpacity = 0
            model.showIntro = false
        }
        await sleep(0.35)
        if Task.isCancelled { return }
        model.showChoice = true
        setInteractive(true)
        withAnimation(.easeOut(duration: 0.4)) { model.choiceOpacity = 1 }

        // 3) Wait for the user to pick an AI.
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<IntroAI, Never>) in
            selectionContinuation = continuation
        }
        if Task.isCancelled { return }
        model.selectedAI = chosen
        setInteractive(false)
        withAnimation(.easeIn(duration: 0.3)) { model.choiceOpacity = 0 }
        await sleep(0.3)
        model.showChoice = false

        // 4) The chosen AI's (simulated) chat window appears.
        model.hasPastedRefinedPrompt = false
        model.showMock = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { model.mockOpacity = 1 }
        await sleep(0.7)
        if Task.isCancelled { return }

        // 5) The companion types a vague prompt into it.
        await typeMockPrompt(Self.demoPrompt)
        if Task.isCancelled { return }
        await sleep(0.5)

        // 5.5) Waiting beat — this is still tutorial-only. The live coach is
        // not running during the intro, so no real mouse-side advice appears.
        model.showThinkingDots = true
        model.demoCaption = "조금만 기다리면…"
        await sleep(2.0)
        if Task.isCancelled { return }

        // 6) Simulated advice arrives inside the tutorial overlay.
        model.showThinkingDots = false
        model.demoCaption = "이런 식으로 조언을 보여줘요"
        model.showAdvice = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { model.adviceOpacity = 1 }
        await sleep(7.0)
        if Task.isCancelled { return }

        // 6.5) Tab → copy → paste motion, still simulated inside tutorial.
        model.demoCaption = "마음에 들면 Tab으로 복사해요"
        model.keyHint = "Tab"
        await pressKeyChip()
        if Task.isCancelled { return }
        model.demoCaption = "복사됐어요. 이제 붙여넣기"
        model.keyHint = "⌘V"
        await pressKeyChip()
        if Task.isCancelled { return }

        // 7) The vague prompt is replaced by a concrete, coached version.
        model.keyHint = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            model.promptHighlight = true
            model.hasPastedRefinedPrompt = true
        }
        model.mockPrompt = Self.demoRefinedPrompt
        await sleep(2.3)
        withAnimation(.easeOut(duration: 0.4)) { model.promptHighlight = false }
        await sleep(0.6)
        if Task.isCancelled { return }

        // 8) Fade the whole demo out.
        withAnimation(.easeIn(duration: 0.45)) { model.mockOpacity = 0 }
        await sleep(0.45)
        model.showMock = false
        model.showAdvice = false
        model.demoCaption = nil

        // 9) Finale chat.
        model.showFinale = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { model.finaleOpacity = 1 }
        await sleep(4.0)
        if Task.isCancelled { return }

        // 10) Finale fades out.
        withAnimation(.easeIn(duration: 0.5)) { model.finaleOpacity = 0 }
        await sleep(0.5)
        model.showFinale = false

        // 11) Fly a cursor up to the menu bar to show where we live.
        model.cursorPosition = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        model.showCursor = true
        let target = menuBarTargetPoint(on: screen)
        await sleep(0.2)
        withAnimation(.easeInOut(duration: 1.25)) { model.cursorPosition = target }
        await sleep(1.3)
        if Task.isCancelled { return }

        // 12) "Click" the menu bar — pulse + open the real panel.
        model.showClickPulse = true
        withAnimation(.easeOut(duration: 0.5)) {
            model.clickPulseScale = 2.4
            model.clickPulseOpacity = 0
        }
        menuBarController?.showPanel()
        await sleep(0.55)
        if Task.isCancelled { return }

        // 12) "우리는 여기 있어요" bubble, just below the menu bar button.
        model.bubblePosition = CGPoint(x: target.x, y: target.y + 36)
        model.bubbleText = "우리는 여기 있어요! ✨"
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.bubbleOpacity = 1 }
        await sleep(3.5)
        if Task.isCancelled { return }

        // 12.5) Final beat: walk the user through turning on Accessibility, so
        // the whole onboarding — tutorial → menu bar → permission — is one
        // continuous flow. Skipped instantly if permission is already granted.
        await guideAccessibilityGrantIfNeeded(on: screen)
        if Task.isCancelled { return }

        // 13) Fade everything out — the real panel stays open.
        withAnimation(.easeIn(duration: 0.5)) {
            model.bubbleOpacity = 0
            model.cursorOpacity = 0
        }
        await sleep(0.5)
        finishIntro()
    }

    /// Final tutorial beat: guides the user through granting Accessibility.
    ///
    /// Registers the app into the Accessibility list (so a ready-made toggle
    /// exists), opens the System Settings pane, and keeps an instruction bubble
    /// up — floating above Settings thanks to our screen-saver-level overlay —
    /// until the user flips the toggle. Returns the instant permission is
    /// granted; no quit, no relaunch. No-op when permission already exists.
    private func guideAccessibilityGrantIfNeeded(on screen: NSScreen) async {
        guard !WindowPositionManager.hasAccessibilityPermission() else { return }

        model.bubbleText = "마지막으로 권한 하나만 켜면 끝이에요.\n제가 설정 창을 열어드릴게요 👇"
        await sleep(2.6)
        if Task.isCancelled { return }

        // Pre-list the app and open the Accessibility pane. Our transparent,
        // click-through overlay stays on top so the bubble guides the user while
        // they interact with the real Settings window underneath.
        accessibilityOnboarder.registerAndOpenSettings()
        await sleep(0.9)
        if Task.isCancelled { return }

        // Park the instruction bubble near the top-center as a persistent hint.
        withAnimation(.easeInOut(duration: 0.35)) {
            model.bubblePosition = CGPoint(x: screen.frame.width / 2, y: 96)
            model.bubbleOpacity = 1
        }
        model.bubbleText = "열린 설정 창에서 'Where-to-vibe' 스위치를 켜주세요.\n딱 한 번만 누르면 됩니다 ✨"

        // Wait for the toggle. AXIsProcessTrusted() reflects the change live, so
        // the user never has to quit or relaunch the app.
        while !WindowPositionManager.hasAccessibilityPermission() {
            if Task.isCancelled { return }
            await sleep(0.4)
        }

        // Granted — bring our overlay back to the front and celebrate briefly
        // before the tutorial hands off to the live coach.
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow?.orderFrontRegardless()
        model.bubbleText = "완료! 🎉 이제 같이 시작해요."
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.bubbleOpacity = 1 }
        await sleep(2.2)
    }

    /// Converts the menu bar button's screen frame (AppKit, bottom-left origin)
    /// into the overlay's SwiftUI-local coordinates (top-left origin).
    private func menuBarTargetPoint(on screen: NSScreen) -> CGPoint {
        guard let buttonFrame = menuBarController?.menuBarButtonScreenFrame() else {
            return CGPoint(x: screen.frame.width - 80, y: 12)
        }
        let screenPoint = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return CGPoint(
            x: screenPoint.x - screen.frame.minX,
            y: screen.frame.maxY - screenPoint.y
        )
    }

    private func typeIntro(_ text: String) async {
        model.introText = ""
        for character in text {
            if Task.isCancelled { return }
            model.introText.append(character)
            await sleep(0.022)
        }
    }

    private func typeMockPrompt(_ text: String) async {
        model.mockPrompt = ""
        for character in text {
            if Task.isCancelled { return }
            model.mockPrompt.append(character)
            await sleep(0.06)  // a touch slower — feels like deliberate typing
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Animates one key-chip "press" (shrink + release) with a short beat.
    private func pressKeyChip() async {
        await sleep(0.45)
        withAnimation(.easeOut(duration: 0.12)) { model.keyPressed = true }
        await sleep(0.16)
        withAnimation(.easeIn(duration: 0.14)) { model.keyPressed = false }
        await sleep(0.5)
    }

    private static let introText = """
    안녕하세요 👋

    저는 당신의 AI Companion입니다. AI 자체는 배우지 않아도 되지만,

    AI와 효과적으로 협업하는 방법은
    배워야 합니다.

    더 좋은 질문을 만드는 법,
    아이디어를 제품으로 발전시키는 법,
    AI를 활용해 창작하는 법을 함께 배웁니다.

    당신의 첫 아이디어를 들려주세요.
    """

    private static let demoPrompt = "앱을 만들어줘"
    private static let demoRefinedPrompt = """
    혼자 쓰는 데일리 할 일 앱의 첫 MVP를 만들어줘.

    대상: 매일 아침 오늘 할 일을 3~7개만 정리하고 싶은 개인 사용자.
    첫 화면: 오늘 날짜, 할 일 입력창, 오늘의 할 일 리스트, 완료된 항목 접기 영역.
    핵심 기능: 할 일 추가/완료 체크/삭제, 완료율 표시, 앱을 껐다 켜도 오늘 목록 유지.
    제약: macOS SwiftUI 앱으로 만들고, 외부 서버 없이 UserDefaults나 로컬 저장소만 사용.
    완료 기준: 새 할 일을 추가하면 즉시 리스트에 보이고, 체크하면 완료 영역으로 이동하며, 재실행 후에도 상태가 남아 있어야 함.
    """
}

/// Borderless transparent window that hosts the intro. Can become key (so the
/// choice buttons respond) but never main, and it's a non-activating panel.
private final class IntroOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IntroSequenceModel: ObservableObject {
    // Intro card
    @Published var introText: String = ""
    @Published var introOpacity: Double = 0
    @Published var showIntro: Bool = true

    // AI choice
    @Published var showChoice: Bool = false
    @Published var choiceOpacity: Double = 0
    @Published var selectedAI: IntroAI? = nil

    // Simulated AI chat window
    @Published var showMock: Bool = false
    @Published var mockOpacity: Double = 0
    @Published var mockPrompt: String = ""
    @Published var hasPastedRefinedPrompt: Bool = false

    // Demo captions + key cues (the "wait → advice → Tab to copy" narration)
    @Published var demoCaption: String? = nil
    @Published var showThinkingDots: Bool = false
    @Published var keyHint: String? = nil      // "Tab" / "⌘V" chip during the copy motion
    @Published var keyPressed: Bool = false     // press animation for the key chip
    @Published var promptHighlight: Bool = false  // brief flash when the pasted prompt lands

    // Real coaching advice shown in the demo (a concrete suggestion, like the app)
    @Published var showAdvice: Bool = false
    @Published var adviceOpacity: Double = 0

    // Finale chat
    @Published var showFinale: Bool = false
    @Published var finaleOpacity: Double = 0

    // Menu-bar pointer ("우리는 여기 있어요")
    @Published var showCursor: Bool = false
    @Published var cursorOpacity: Double = 1
    @Published var cursorPosition: CGPoint = .zero
    @Published var showClickPulse: Bool = false
    @Published var clickPulseScale: CGFloat = 0.6
    @Published var clickPulseOpacity: Double = 0.9
    @Published var bubbleText: String? = nil
    @Published var bubbleOpacity: Double = 0
    @Published var bubblePosition: CGPoint = .zero

    /// True only during the choice step, so the overlay accepts clicks.
    @Published var acceptsInput: Bool = false
}

private struct IntroOverlayView: View {
    @ObservedObject var model: IntroSequenceModel
    let screenSize: CGSize
    let refinedPrompt: String
    let onSelectAI: (IntroAI) -> Void

    var body: some View {
        ZStack {
            // A subtle dim only while we need the user's attention/click.
            Color.black
                .opacity(model.acceptsInput ? 0.38 : 0.0)
                .animation(.easeInOut(duration: 0.35), value: model.acceptsInput)

            if model.showIntro {
                introCard
                    .opacity(model.introOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showChoice {
                choiceCard
                    .opacity(model.choiceOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showMock {
                demoStack
                    .opacity(model.mockOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showFinale {
                finaleCard
                    .opacity(model.finaleOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showCursor {
                cursorView
                    .opacity(model.cursorOpacity)
                    .position(model.cursorPosition)
            }

            if let bubbleText = model.bubbleText {
                weAreHereBubble(bubbleText)
                    .opacity(model.bubbleOpacity)
                    .position(
                        x: min(max(model.bubblePosition.x, 90), screenSize.width - 90),
                        y: model.bubblePosition.y
                    )
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .allowsHitTesting(model.acceptsInput)
    }

    private var cursorView: some View {
        ZStack {
            if model.showClickPulse {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .scaleEffect(model.clickPulseScale)
                    .opacity(model.clickPulseOpacity)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        }
    }

    private func weAreHereBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.95))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            )
    }

    // MARK: Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor.opacity(0.32))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    )
                Text("where-to-vibe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(model.introText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: Choice

    private var choiceCard: some View {
        VStack(spacing: 16) {
            Text("어떤 AI를 사용하세요?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Claude를 클릭해보세요.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 12) {
                ForEach(IntroAI.allCases) { ai in
                    aiChoiceButton(ai)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                Text("여기를 클릭해보세요")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.72))
        }
        .padding(28)
        .frame(width: 460)
        .background(cardBackground)
    }

    /// Brand badge: the real logo on a white circle if the asset is present in
    /// the bundle/asset catalog, otherwise a tinted SF Symbol fallback so the
    /// build always renders even before the logo files are added.
    @ViewBuilder
    private func aiBadge(_ ai: IntroAI, size: CGFloat) -> some View {
        if let logo = NSImage(named: ai.logoAssetName) {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .padding(size * 0.16)
                .frame(width: size, height: size)
                .background(Circle().fill(.white))
                .clipShape(Circle())
        } else {
            Image(systemName: ai.systemImage)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(ai.tint.opacity(0.9)))
        }
    }

    private func aiChoiceButton(_ ai: IntroAI) -> some View {
        Button {
            onSelectAI(ai)
        } label: {
            VStack(spacing: 10) {
                aiBadge(ai, size: 46)
                Text(ai.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 110)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Simulated AI chat window + demo

    /// The full demo column: a narration caption, the simulated AI chat client,
    /// and the ambition ladder once advice arrives. All fade together.
    private var demoStack: some View {
        let ai = model.selectedAI ?? .claude
        return VStack(spacing: 14) {
            if let caption = model.demoCaption {
                demoCaptionView(caption)
            }
            // Advice sits to the RIGHT of the chat window (not below).
            HStack(alignment: .center, spacing: 16) {
                mockChatClient(ai)
                if model.showAdvice {
                    adviceBubble
                        .opacity(model.adviceOpacity)
                }
            }
        }
    }

    /// Real-looking coaching advice: a short reason + a concrete rewrite, with a
    /// "Tab to copy" affordance — exactly the shape the live coach produces.
    private var adviceBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor.opacity(0.32))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    )
                Text("where-to-vibe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text("\"앱을 만들어줘\"는 너무 막연해요. 대상 사용자, 첫 화면, 핵심 기능, 저장 방식, 완료 기준을 넣으면 AI가 바로 구현 계획을 세울 수 있어요.")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(.white.opacity(0.15))

            Text("이렇게 써보세요")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(refinedPrompt)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Tab")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.16))
                    )
                Text("눌러서 복사")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(cardBackground)
    }

    private func demoCaptionView(_ caption: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
            Text(caption)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.6))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }

    private func mockChatClient(_ ai: IntroAI) -> some View {
        let chatWidth: CGFloat = model.hasPastedRefinedPrompt ? 500 : 440
        let chatHeight: CGFloat = model.hasPastedRefinedPrompt ? 410 : 240

        return VStack(alignment: .leading, spacing: 0) {
            mockChatHeader(ai)
            Divider().overlay(.white.opacity(0.1))
            // Response area — shows a "thinking" indicator while waiting.
            ZStack(alignment: .leading) {
                if model.showThinkingDots {
                    thinkingDots(tint: ai.tint)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            Spacer(minLength: 0)
            mockInputBox(ai)
        }
        .frame(width: chatWidth, height: chatHeight, alignment: .topLeading)
        .background(mockChatBackground)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.hasPastedRefinedPrompt)
    }

    private func thinkingDots(tint: Color) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(0.9))
                    .frame(width: 7, height: 7)
                    .scaleEffect(model.showThinkingDots ? 1.0 : 0.6)
                    .opacity(model.showThinkingDots ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.18),
                        value: model.showThinkingDots
                    )
            }
        }
    }

    private func mockChatHeader(_ ai: IntroAI) -> some View {
        HStack(spacing: 8) {
            aiBadge(ai, size: 24)
            Text(ai.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .padding(14)
    }

    private func mockInputBox(_ ai: IntroAI) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 2) {
                    Text(model.mockPrompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Rectangle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 2, height: 16)
                    Spacer(minLength: 0)
                    if let keyHint = model.keyHint {
                        keyChip(keyHint)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mockInputBackground(ai))
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(ai.tint)
        }
        .padding(14)
    }

    private func mockInputBackground(_ ai: IntroAI) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(model.promptHighlight ? ai.tint.opacity(0.20) : .white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(model.promptHighlight ? ai.tint.opacity(0.6) : .white.opacity(0.14), lineWidth: 1)
            )
    }

    private func keyChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
            )
            .scaleEffect(model.keyPressed ? 0.8 : 1.0)
    }

    private var mockChatBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    // MARK: Finale

    private var finaleCard: some View {
        VStack(spacing: 10) {
            Text("✨")
                .font(.system(size: 34))
            Text("같이 함께 만들어봐요")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("당신의 첫 아이디어를 입력창에 적어보세요.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(28)
        .frame(width: 380)
        .background(cardBackground)
    }

    // MARK: Shared

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.black.opacity(0.82))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }
}
