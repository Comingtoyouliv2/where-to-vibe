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
//   5. After a beat, a coach advice bubble appears — showing what the app does.
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
    case codex = "Codex"
    case gpt = "ChatGPT"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var systemImage: String {
        switch self {
        case .claude: return "sparkle"
        case .codex:  return "chevron.left.forwardslash.chevron.right"
        case .gpt:    return "bubble.left.and.bubble.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.55, blue: 0.30) // warm orange
        case .codex:  return Color(red: 0.45, green: 0.78, blue: 0.55) // green
        case .gpt:    return Color(red: 0.36, green: 0.72, blue: 0.65) // teal
        }
    }
}

@MainActor
final class IntroSequenceController {
    private weak var menuBarController: MenuBarController?
    private let model = IntroSequenceModel()
    private var overlayWindow: NSWindow?
    private var sequenceTask: Task<Void, Never>?
    /// Resumed when the user taps an AI choice.
    private var selectionContinuation: CheckedContinuation<IntroAI, Never>?

    init(menuBarController: MenuBarController) {
        self.menuBarController = menuBarController
    }

    func play() {
        guard overlayWindow == nil else { return }
        guard let screen = NSScreen.main else { return }
        buildOverlay(on: screen)
        sequenceTask = Task { @MainActor in
            await runSequence(on: screen)
        }
    }

    func stop() {
        // Resume any pending selection so the suspended sequence can unwind.
        if let continuation = selectionContinuation {
            selectionContinuation = nil
            continuation.resume(returning: .claude)
        }
        sequenceTask?.cancel()
        sequenceTask = nil
        teardown()
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
        model.showMock = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { model.mockOpacity = 1 }
        await sleep(0.7)
        if Task.isCancelled { return }

        // 5) The companion types a vague prompt into it.
        await typeMockPrompt(Self.demoPrompt)
        if Task.isCancelled { return }
        await sleep(1.2)  // "thinking" beat

        // 6) Fade the mock and reveal the AMBITION LADDER — the differentiator.
        //    Same one-line request, three levels of ambition, each surfacing
        //    the pro tools a beginner doesn't know to ask for.
        withAnimation(.easeIn(duration: 0.4)) { model.mockOpacity = 0 }
        await sleep(0.4)
        model.showMock = false
        model.ladderTiers = AmbitionLadderLibrary.ladder(for: Self.demoPrompt)
        model.showLadder = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { model.ladderOpacity = 1 }
        await sleep(8.0)  // time to absorb the three tiers
        if Task.isCancelled { return }

        // 7) Fade the ladder out.
        withAnimation(.easeIn(duration: 0.45)) { model.ladderOpacity = 0 }
        await sleep(0.45)
        model.showLadder = false

        // 8) Finale chat.
        model.showFinale = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { model.finaleOpacity = 1 }
        await sleep(4.0)
        if Task.isCancelled { return }

        // 9) Finale fades out.
        withAnimation(.easeIn(duration: 0.5)) { model.finaleOpacity = 0 }
        await sleep(0.5)
        model.showFinale = false

        // 10) Fly a cursor up to the menu bar to show where we live.
        model.cursorPosition = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        model.showCursor = true
        let target = menuBarTargetPoint(on: screen)
        await sleep(0.2)
        withAnimation(.easeInOut(duration: 1.25)) { model.cursorPosition = target }
        await sleep(1.3)
        if Task.isCancelled { return }

        // 11) "Click" the menu bar — pulse + open the real panel.
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

        // 13) Fade everything out — the real panel stays open.
        withAnimation(.easeIn(duration: 0.5)) {
            model.bubbleOpacity = 0
            model.cursorOpacity = 0
        }
        await sleep(0.5)
        teardown()
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

    // Coach advice bubble
    @Published var adviceText: String? = nil
    @Published var adviceOpacity: Double = 0

    // Ambition ladder (the differentiator)
    @Published var showLadder: Bool = false
    @Published var ladderOpacity: Double = 0
    @Published var ladderTiers: [AmbitionTier] = []

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
                mockChatWindow
                    .opacity(model.mockOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showLadder {
                AmbitionLadderView(promptText: model.mockPrompt, tiers: model.ladderTiers)
                    .opacity(model.ladderOpacity)
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
            Text("선택하면, 함께 한 번 써볼게요.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 12) {
                ForEach(IntroAI.allCases) { ai in
                    aiChoiceButton(ai)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(cardBackground)
    }

    private func aiChoiceButton(_ ai: IntroAI) -> some View {
        Button {
            onSelectAI(ai)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: ai.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(ai.tint.opacity(0.9)))
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

    // MARK: Simulated AI chat window

    private var mockChatWindow: some View {
        let ai = model.selectedAI ?? .claude
        return HStack(alignment: .top, spacing: 16) {
            mockChatClient(ai)
            if let adviceText = model.adviceText {
                adviceBubble(adviceText)
                    .opacity(model.adviceOpacity)
            }
        }
    }

    private func mockChatClient(_ ai: IntroAI) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mockChatHeader(ai)
            Divider().overlay(.white.opacity(0.1))
            Spacer(minLength: 60)
            mockInputBox(ai)
        }
        .frame(width: 420, height: 280, alignment: .topLeading)
        .background(mockChatBackground)
    }

    private func mockChatHeader(_ ai: IntroAI) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ai.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(ai.tint.opacity(0.9)))
            Text(ai.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .padding(14)
    }

    private func mockInputBox(_ ai: IntroAI) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(model.mockPrompt)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.92))
                Rectangle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 2, height: 16)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            )
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(ai.tint)
        }
        .padding(14)
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

    private func adviceBubble(_ text: String) -> some View {
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
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(cardBackground)
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
