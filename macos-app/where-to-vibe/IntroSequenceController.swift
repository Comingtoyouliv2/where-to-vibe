//
//  IntroSequenceController.swift
//  where-to-vibe
//
//  First-launch (currently every-launch, for dev) intro animation.
//
//  Sequence:
//   1. A chat card appears in the center of the screen and types out a short
//      introduction about the app, like a chat message arriving.
//   2. A fake cursor flies up to the menu bar status item ("where-to-vibe"),
//      and "clicks" it — we actually open the real menu bar panel.
//   3. A "we're here" speech bubble appears just below the menu bar button.
//
//  Fully self-contained and ADDITIVE: it renders in its own transparent,
//  click-through overlay window and never touches the suggestion / Tab path.
//  The real system cursor is never moved — the flying cursor is a drawn
//  overlay, so the user's pointer is left alone.
//

import AppKit
import SwiftUI

@MainActor
final class IntroSequenceController {
    private weak var menuBarController: MenuBarController?
    private let model = IntroSequenceModel()
    private var overlayWindow: NSWindow?
    private var sequenceTask: Task<Void, Never>?

    init(menuBarController: MenuBarController) {
        self.menuBarController = menuBarController
    }

    /// Plays the intro. For dev we play on every launch. To make it
    /// first-launch-only, guard here on a UserDefaults flag, e.g.:
    ///   guard !UserDefaults.standard.bool(forKey: "didPlayIntro") else { return }
    ///   UserDefaults.standard.set(true, forKey: "didPlayIntro")
    func play() {
        guard overlayWindow == nil else { return }
        guard let screen = NSScreen.main else { return }
        buildOverlay(on: screen)
        sequenceTask = Task { @MainActor in
            await runSequence(on: screen)
        }
    }

    func stop() {
        sequenceTask?.cancel()
        sequenceTask = nil
        teardown()
    }

    // MARK: - Overlay window

    private func buildOverlay(on screen: NSScreen) {
        let window = IntroOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the panel and the menu bar so the cursor + bubble render on top.
        // Transparent + click-through, so the real panel still shows through and
        // the user can keep working.
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)

        let hostingView = NSHostingView(
            rootView: IntroOverlayView(model: model, screenSize: screen.frame.size)
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

    // MARK: - Sequence

    private func runSequence(on screen: NSScreen) async {
        let center = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        model.cursorPosition = center

        // 1) Chat card fades in and types the intro.
        withAnimation(.easeOut(duration: 0.45)) { model.chatOpacity = 1 }
        await typeText(Self.introText)
        if Task.isCancelled { return }
        // Keep the finished introduction on screen ~5s before moving on.
        await sleep(5.0)

        // 2) Fade the chat card out, reveal the fake cursor at center.
        withAnimation(.easeIn(duration: 0.35)) { model.chatOpacity = 0 }
        await sleep(0.4)
        if Task.isCancelled { return }
        model.showChat = false
        model.showCursor = true

        // 3) Fly the cursor up to the menu bar button.
        let target = menuBarTargetPoint(on: screen)
        await sleep(0.2)
        withAnimation(.easeInOut(duration: 1.25)) { model.cursorPosition = target }
        await sleep(1.3)
        if Task.isCancelled { return }

        // 4) "Click": a pulse ring expands, and we open the REAL panel.
        model.showClickPulse = true
        withAnimation(.easeOut(duration: 0.5)) {
            model.clickPulseScale = 2.4
            model.clickPulseOpacity = 0
        }
        menuBarController?.showPanel()
        await sleep(0.55)
        if Task.isCancelled { return }

        // 5) "We're here" bubble, just below the menu bar button.
        model.bubblePosition = CGPoint(x: target.x, y: target.y + 36)
        model.bubbleText = "우린 여기 있어요! ✨"
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.bubbleOpacity = 1 }
        await sleep(3.5)
        if Task.isCancelled { return }

        // 6) Fade everything out — the real panel stays open.
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
            // Fallback: roughly where the menu bar status area sits.
            return CGPoint(x: screen.frame.width - 80, y: 12)
        }
        let screenPoint = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return CGPoint(
            x: screenPoint.x - screen.frame.minX,
            y: screen.frame.maxY - screenPoint.y
        )
    }

    private func typeText(_ text: String) async {
        model.chatText = ""
        for character in text {
            if Task.isCancelled { return }
            model.chatText.append(character)
            await sleep(0.022)
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static let introText = """
    안녕하세요, where-to-vibe예요 👋

    AI에게 막연하게 말하면 막연한 결과가 나와요. 제가 더 좋은 질문을 만들도록 옆에서 도와드릴게요.

    프롬프트를 치다 잠깐 멈추면 더 나은 버전을 제안해요. 마음에 들면 Tab을 눌러 복사하세요.
    """
}

/// Borderless, never-key transparent window that hosts the intro animation.
private final class IntroOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IntroSequenceModel: ObservableObject {
    // Chat card
    @Published var chatText: String = ""
    @Published var chatOpacity: Double = 0
    @Published var showChat: Bool = true

    // Fake cursor
    @Published var showCursor: Bool = false
    @Published var cursorOpacity: Double = 1
    @Published var cursorPosition: CGPoint = .zero

    // Click pulse
    @Published var showClickPulse: Bool = false
    @Published var clickPulseScale: CGFloat = 0.6
    @Published var clickPulseOpacity: Double = 0.9

    // "We're here" bubble
    @Published var bubbleText: String? = nil
    @Published var bubbleOpacity: Double = 0
    @Published var bubblePosition: CGPoint = .zero
}

private struct IntroOverlayView: View {
    @ObservedObject var model: IntroSequenceModel
    let screenSize: CGSize

    var body: some View {
        ZStack {
            // Transparent, greedy canvas establishing full-screen coordinates.
            Color.clear

            if model.showChat {
                chatCard
                    .opacity(model.chatOpacity)
                    .position(x: screenSize.width / 2, y: screenSize.height / 2)
            }

            if model.showCursor {
                cursor
                    .opacity(model.cursorOpacity)
                    .position(model.cursorPosition)
            }

            if let bubbleText = model.bubbleText {
                bubble(bubbleText)
                    .opacity(model.bubbleOpacity)
                    .position(
                        x: min(max(model.bubblePosition.x, 90), screenSize.width - 90),
                        y: model.bubblePosition.y
                    )
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .allowsHitTesting(false)
    }

    private var cursor: some View {
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

    private var chatCard: some View {
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
            Text(model.chatText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.82))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
        )
    }

    private func bubble(_ text: String) -> some View {
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
}
