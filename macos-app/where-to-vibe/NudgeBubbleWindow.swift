//
//  NudgeBubbleWindow.swift
//  where-to-vibe
//
//  Read-only speech bubble next to the mouse cursor when /coach replies.
//
//  Implementation: full-screen transparent click-through NSWindow at
//  .screenSaver level (same pattern as upstream Where-to-vibe's OverlayWindow,
//  which renders reliably even when another app is frontmost). Inside
//  the window we host a small NSView containing the SwiftUI bubble pill,
//  positioned with AppKit frame coordinates (bottom-left origin, the same
//  coordinate system as NSEvent.mouseLocation) — no SwiftUI offset math,
//  no GeometryReader, no coordinate-flip bugs.
//
//  Behaviour:
//  - Bubble pins to the cursor location at the moment the trigger fired.
//  - Auto-dismisses after 7 seconds.
//  - ESC dismisses immediately.
//  - A new nudge replaces the current one (no stacking).
//

import AppKit
import Combine
import SwiftUI

/// Borderless transparent NSWindow that never takes focus, sized to the
/// full screen so WindowServer composites it like an assistive overlay.
private final class BubbleOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NudgeBubbleWindow: NSObject {

    // MARK: - Tunables

    private let bubbleMinimumWidth: CGFloat = 220
    private let bubbleToastMinimumWidth: CGFloat = 160
    private let bubbleMaximumWidth: CGFloat = 520
    private let bubbleMaximumScreenHeightRatio: CGFloat = 0.94
    /// How long the bubble stays on screen before auto-dismissing.
    /// 17s is long enough to read the nudge + the rewrite block and
    /// decide whether to press Tab to copy. ESC dismisses immediately
    /// for users who want to clear it faster.
    private let bubbleAutoDismissSeconds: Double = 17.0
    /// Gap between cursor hotspot and left edge of the bubble.
    private let cursorToBubbleHorizontalGap: CGFloat = 14
    private let bubbleScreenEdgePadding: CGFloat = 8

    // MARK: - State

    private var overlayWindow: BubbleOverlayWindow?
    /// NSHostingView for the bubble pill. Reparented inside the overlay
    /// window and positioned with `frame` (AppKit bottom-left origin).
    private var bubbleHostingView: NSHostingView<NudgeBubbleView>?
    /// One typewriter model survives across bubble renders so the same
    /// SwiftUI subtree updates as text streams in. Re-using it avoids
    /// the bubble flickering when content changes.
    private let typewriterModel = NudgeBubbleTypewriterModel()
    private var escapeKeyMonitor: Any?
    private var autoDismissTask: Task<Void, Never>?

    /// True between `showNudgeAtCurrentCursor(...)` and `dismiss()`. The
    /// auto-coach observer reads this to suppress new /coach calls while
    /// the user is still reading the previous nudge.
    private(set) var isShowingBubble: Bool = false

    /// The rewrite text currently on screen, if any. The Tab key intercept
    /// reads this when the user presses Tab — if non-nil, we copy it to
    /// the pasteboard and swallow the Tab so the user's input field
    /// doesn't get an indent. nil = no rewrite to copy, Tab passes
    /// through to the user's app as normal.
    private(set) var availableRewriteForCopy: String?

    /// Drives the per-frame cursor-follow animation. Runs only while the
    /// bubble is visible; invalidated on dismiss so we don't waste cycles
    /// when there's nothing to render. ~60Hz is enough for "glued to the
    /// cursor" feel without burning battery.
    private var cursorFollowTimer: Timer?
    /// Currently rendered (smoothed) bubble origin in window-local coords.
    /// We interpolate from this towards the cursor every frame so the
    /// bubble eases into position rather than teleporting.
    private var smoothedBubbleOriginInWindowCoords: CGPoint?
    /// Cached bubble size so per-frame frame updates don't have to call
    /// fittingSize repeatedly (that's expensive — it lays out SwiftUI).
    private var currentBubbleSize: CGSize = .zero

    // MARK: - Public API

    func showNudgeAtCurrentCursor(
        nudgeText: String,
        modeLabel: String?,
        rewriteText: String?
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        // Stash the rewrite so the Tab-key intercept can read it without
        // having to dig through the SwiftUI tree.
        self.availableRewriteForCopy = rewriteText

        let cursorScreenPoint = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = cursorScreen else {
            print("🧠 bubble: no screen found for cursor at \(cursorScreenPoint)")
            return
        }

        // Step 1: make sure the full-screen overlay window exists on the
        // cursor's screen.
        ensureOverlayWindow(forScreen: screen)

        // Step 2a: pre-measure the bubble at its FINAL (fully-typed)
        // size so the pill is the right shape from frame 1 and the
        // text simply fills in. Do this with a throwaway hosting view
        // that holds the full text — never mounted in the window.
        let measurementModel = NudgeBubbleTypewriterModel()
        measurementModel.targetNudgeText = nudgeText
        measurementModel.targetRewriteText = rewriteText
        measurementModel.modeLabel = modeLabel
        // Reveal everything so fittingSize reflects the final layout
        // including the rewrite block and the "Tab to copy" affordance.
        measurementModel.revealedCharacterCount = nudgeText.count + (rewriteText?.count ?? 0)
        measurementModel.hasFinishedTypingRewrite = (rewriteText?.isEmpty == false)
        currentBubbleSize = measureBubbleSize(
            with: measurementModel,
            on: screen,
            minimumWidth: bubbleToastMinimumWidth,
            minimumHeight: 40
        )
        let bubbleWidth = currentBubbleSize.width
        let bubbleHeight = currentBubbleSize.height

        // Step 2b: build (or reuse) the LIVE hosting view bound to the
        // real typewriterModel. We then start typing — characters flow
        // in via the model's @Published counter, which the SwiftUI tree
        // observes.
        let hostingView: NSHostingView<NudgeBubbleView>
        if let existingHostingView = bubbleHostingView {
            hostingView = existingHostingView
        } else {
            let newHostingView = NSHostingView(
                rootView: NudgeBubbleView(typewriterModel: typewriterModel)
            )
            newHostingView.wantsLayer = true
            newHostingView.layer?.backgroundColor = NSColor.clear.cgColor
            overlayWindow?.contentView?.addSubview(newHostingView)
            bubbleHostingView = newHostingView
            hostingView = newHostingView
        }
        typewriterModel.startTypingFresh(
            nudgeText: nudgeText,
            rewriteText: rewriteText,
            modeLabel: modeLabel
        )

        // Step 3: compute the bubble's INITIAL position next to the cursor.
        // The cursor-follow timer (started below) recomputes this every
        // frame so the bubble eases along with the mouse rather than
        // teleporting on each tick.
        let initialBubbleOrigin = computeBubbleOriginNearCursor(
            cursorInScreenCoords: cursorScreenPoint,
            screen: screen,
            bubbleWidth: bubbleWidth,
            bubbleHeight: bubbleHeight
        )

        // Seed the smoothed position to the initial origin so the first
        // frame doesn't ease in from (0, 0).
        smoothedBubbleOriginInWindowCoords = initialBubbleOrigin

        hostingView.frame = NSRect(
            x: initialBubbleOrigin.x,
            y: initialBubbleOrigin.y,
            width: bubbleWidth,
            height: bubbleHeight
        )

        overlayWindow?.orderFrontRegardless()
        overlayWindow?.display()
        isShowingBubble = true

        // Start (or restart) the per-frame cursor-follow timer.
        startCursorFollowTimer()

        if let overlayWindow {
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            print("🧠 bubble overlay frame=\(overlayWindow.frame) hostingFrame=\(hostingView.frame) cursorAt=\(cursorScreenPoint) screen=\(screen.frame) front=\(frontApp) ourActive=\(NSApp.isActive)")
        }

        installEscapeKeyDismissMonitor()
        scheduleAutoDismiss()
    }

    // MARK: - Streaming API

    /// Open a placeholder bubble immediately at the current cursor, with no
    /// text yet. The observer then drives the text via
    /// `appendStreamedNudgeText` and finalizes with `finalizeStreamedBubble`
    /// when the /coach-stream response completes.
    ///
    /// We don't pre-measure the final size here — we re-measure on every
    /// `appendStreamedNudgeText` call so the bubble grows with the text.
    /// That avoids the awkward "giant empty pill" effect when the stream
    /// is just starting.
    func showStreamingBubbleAtCurrentCursor(modeLabelHint: String?) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        availableRewriteForCopy = nil

        let cursorScreenPoint = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = cursorScreen else { return }

        ensureOverlayWindow(forScreen: screen)

        // Stop any leftover typewriter from a previous (non-streaming) call.
        typewriterModel.stopTyping()
        typewriterModel.targetNudgeText = ""
        typewriterModel.targetRewriteText = nil
        typewriterModel.modeLabel = modeLabelHint ?? "thinking…"
        typewriterModel.revealedCharacterCount = 0
        typewriterModel.hasFinishedTypingRewrite = false

        // Create the hosting view if it doesn't exist yet.
        let hostingView: NSHostingView<NudgeBubbleView>
        if let existingHostingView = bubbleHostingView {
            hostingView = existingHostingView
        } else {
            let newHostingView = NSHostingView(
                rootView: NudgeBubbleView(typewriterModel: typewriterModel)
            )
            newHostingView.wantsLayer = true
            newHostingView.layer?.backgroundColor = NSColor.clear.cgColor
            overlayWindow?.contentView?.addSubview(newHostingView)
            bubbleHostingView = newHostingView
            hostingView = newHostingView
        }

        // Seed a small initial size so the bubble shows up immediately
        // even before any token arrives. Final size is computed each
        // time text grows.
        let placeholderSize = CGSize(width: bubbleMinimumWidth, height: 44)
        currentBubbleSize = placeholderSize
        let initialOrigin = computeBubbleOriginNearCursor(
            cursorInScreenCoords: cursorScreenPoint,
            screen: screen,
            bubbleWidth: placeholderSize.width,
            bubbleHeight: placeholderSize.height
        )
        smoothedBubbleOriginInWindowCoords = initialOrigin
        hostingView.frame = NSRect(
            x: initialOrigin.x,
            y: initialOrigin.y,
            width: placeholderSize.width,
            height: placeholderSize.height
        )

        overlayWindow?.orderFrontRegardless()
        overlayWindow?.display()
        isShowingBubble = true
        startCursorFollowTimer()
        installEscapeKeyDismissMonitor()
        // No auto-dismiss yet — we don't start that timer until the
        // stream finalizes. Otherwise a slow stream could time the
        // bubble out before the first sentence finishes.
    }

    /// Update the bubble's nudge text to the current streamed value.
    /// Called repeatedly as tokens arrive. We resize the bubble each
    /// time so the pill grows visibly along with the text — that IS
    /// the typewriter effect when the server is driving the speed.
    func appendStreamedNudgeText(_ nudgeSoFar: String) {
        guard isShowingBubble, let hostingView = bubbleHostingView else { return }

        // Push the new text into the typewriter model. We set
        // revealedCharacterCount equal to the full length because the
        // SERVER is now controlling the speed — we want every character
        // we've received to be visible immediately.
        typewriterModel.targetNudgeText = nudgeSoFar
        typewriterModel.revealedCharacterCount = nudgeSoFar.count

        // Re-measure for the new text length so the bubble grows.
        let measurementModel = NudgeBubbleTypewriterModel()
        measurementModel.targetNudgeText = nudgeSoFar
        measurementModel.modeLabel = typewriterModel.modeLabel
        measurementModel.revealedCharacterCount = nudgeSoFar.count
        let screen = activeBubbleScreen()
        let newBubbleSize = measureBubbleSize(
            with: measurementModel,
            on: screen,
            minimumWidth: bubbleMinimumWidth,
            minimumHeight: 44
        )
        currentBubbleSize = newBubbleSize
        // Keep position smooth — the cursor-follow timer will catch up
        // next frame. We only mutate the size here; origin updates come
        // from advanceCursorFollowOneFrame.
        hostingView.frame = NSRect(
            x: hostingView.frame.origin.x,
            y: hostingView.frame.origin.y,
            width: newBubbleSize.width,
            height: newBubbleSize.height
        )
    }

    /// Update the bubble's rewrite text to the current streamed value.
    /// Same pattern as `appendStreamedNudgeText` but for the spec /
    /// rewrite block. Fires repeatedly as rewrite tokens arrive — the
    /// pill grows downward as more of the spec materialises.
    ///
    /// We intentionally do NOT show the "Tab to copy" affordance while
    /// the rewrite is still streaming. That comes on in
    /// `finalizeStreamedBubble` once we know the rewrite is complete.
    func appendStreamedRewriteText(_ rewriteSoFar: String) {
        guard isShowingBubble, let hostingView = bubbleHostingView else { return }

        // Push the new rewrite text into the typewriter model. We bump
        // revealedCharacterCount to cover BOTH nudge + rewrite so
        // SwiftUI reveals the full rewrite-so-far.
        typewriterModel.targetRewriteText = rewriteSoFar
        typewriterModel.revealedCharacterCount =
            typewriterModel.targetNudgeText.count + rewriteSoFar.count
        // Affordance stays hidden until finalize — we don't know whether
        // more rewrite tokens are coming.
        typewriterModel.hasFinishedTypingRewrite = false

        // Re-measure so the bubble grows to fit the rewrite text. We
        // measure with the FULL current state (nudge + partial rewrite)
        // and let SwiftUI lay it out at the right height.
        let measurementModel = NudgeBubbleTypewriterModel()
        measurementModel.targetNudgeText = typewriterModel.targetNudgeText
        measurementModel.targetRewriteText = rewriteSoFar
        measurementModel.modeLabel = typewriterModel.modeLabel
        measurementModel.revealedCharacterCount =
            typewriterModel.targetNudgeText.count + rewriteSoFar.count
        measurementModel.hasFinishedTypingRewrite = false  // no affordance during stream
        let screen = activeBubbleScreen()
        let newBubbleSize = measureBubbleSize(
            with: measurementModel,
            on: screen,
            minimumWidth: bubbleMinimumWidth,
            minimumHeight: 44
        )
        currentBubbleSize = newBubbleSize
        hostingView.frame = NSRect(
            x: hostingView.frame.origin.x,
            y: hostingView.frame.origin.y,
            width: newBubbleSize.width,
            height: newBubbleSize.height
        )
    }

    /// Called once the /coach-stream response has fully completed and
    /// been parsed. Fills in the rewrite block, mode label, and starts
    /// the auto-dismiss timer.
    func finalizeStreamedBubble(with response: CoachResponse) {
        guard isShowingBubble else { return }
        typewriterModel.targetNudgeText = response.nudge
        typewriterModel.targetRewriteText = response.rewrite
        typewriterModel.modeLabel = response.mode
        typewriterModel.revealedCharacterCount =
            response.nudge.count + (response.rewrite?.count ?? 0)
        typewriterModel.hasFinishedTypingRewrite = (response.rewrite?.isEmpty == false)
        availableRewriteForCopy = response.rewrite

        // Re-measure with the final content (including rewrite + tab
        // affordance) so the bubble settles at its final shape.
        if let hostingView = bubbleHostingView {
            let finalMeasureModel = NudgeBubbleTypewriterModel()
            finalMeasureModel.targetNudgeText = response.nudge
            finalMeasureModel.targetRewriteText = response.rewrite
            finalMeasureModel.modeLabel = response.mode
            finalMeasureModel.revealedCharacterCount =
                response.nudge.count + (response.rewrite?.count ?? 0)
            finalMeasureModel.hasFinishedTypingRewrite = (response.rewrite?.isEmpty == false)
            let screen = activeBubbleScreen()
            let finalSize = measureBubbleSize(
                with: finalMeasureModel,
                on: screen,
                minimumWidth: bubbleMinimumWidth,
                minimumHeight: 44
            )
            currentBubbleSize = finalSize
            hostingView.frame = NSRect(
                x: hostingView.frame.origin.x,
                y: hostingView.frame.origin.y,
                width: finalSize.width,
                height: finalSize.height
            )
        }

        scheduleAutoDismiss()
    }

    /// Called when the stream failed before completing. If we already
    /// got some nudge text on screen, we keep it (it's still useful);
    /// otherwise we just dismiss.
    func handleStreamFailure(error: CoachAPIError) {
        if typewriterModel.targetNudgeText.isEmpty {
            dismiss()
        } else {
            // Leave whatever text we have visible, start the dismiss
            // timer so the user has time to read it.
            scheduleAutoDismiss()
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        stopCursorFollowTimer()
        typewriterModel.stopTyping()
        removeEscapeKeyDismissMonitor()
        overlayWindow?.orderOut(nil)
        isShowingBubble = false
        availableRewriteForCopy = nil
    }

    /// Copies the rewrite text to the system pasteboard and animates a
    /// short "Copied — paste with ⌘V" confirmation in place of the bubble
    /// before dismissing. Returns true if there was a rewrite to copy
    /// (i.e. the Tab keypress was consumed); false if there was nothing
    /// and the caller should let the Tab pass through.
    @discardableResult
    func copyAvailableRewriteToPasteboardAndShowConfirmation() -> Bool {
        guard let rewrite = availableRewriteForCopy, !rewrite.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rewrite, forType: .string)

        // Swap the bubble's content for a tiny confirmation toast. We
        // skip the typewriter for the toast — instant reveal feels more
        // like a system confirmation than typing.
        let toastNudge = "Copied — paste with ⌘V"
        typewriterModel.stopTyping()
        typewriterModel.targetNudgeText = toastNudge
        typewriterModel.targetRewriteText = nil
        typewriterModel.modeLabel = "ready"
        typewriterModel.revealedCharacterCount = toastNudge.count
        typewriterModel.hasFinishedTypingRewrite = false

        // Re-measure for the smaller toast so we don't leave a giant pill.
        let toastMeasureModel = NudgeBubbleTypewriterModel()
        toastMeasureModel.targetNudgeText = toastNudge
        toastMeasureModel.revealedCharacterCount = toastNudge.count
        currentBubbleSize = measureBubbleSize(
            with: toastMeasureModel,
            on: activeBubbleScreen(),
            minimumWidth: bubbleToastMinimumWidth,
            minimumHeight: 40
        )

        // Clear the rewrite so a second Tab doesn't re-copy.
        availableRewriteForCopy = nil

        // Auto-dismiss the toast after ~1.5s — it's just a confirmation,
        // no need to linger.
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismiss()
            }
        }
        return true
    }

    // MARK: - Cursor-following

    private func activeBubbleScreen() -> NSScreen? {
        let cursorScreenPoint = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPoint) })
            ?? overlayWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func maximumBubbleWidth(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return bubbleMaximumWidth }
        let availableWidth = screen.frame.width
            - bubbleScreenEdgePadding * 2
            - cursorToBubbleHorizontalGap
        return min(bubbleMaximumWidth, max(bubbleMinimumWidth, availableWidth))
    }

    private func maximumBubbleHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return 720 }
        let availableHeight = screen.frame.height - bubbleScreenEdgePadding * 2
        return max(160, availableHeight * bubbleMaximumScreenHeightRatio)
    }

    private func measureBubbleSize(
        with model: NudgeBubbleTypewriterModel,
        on screen: NSScreen?,
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> CGSize {
        let maximumWidth = maximumBubbleWidth(on: screen)
        let maximumHeight = maximumBubbleHeight(on: screen)
        let measuringHostingView = NSHostingView(
            rootView: NudgeBubbleView(typewriterModel: model)
        )
        measuringHostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: maximumWidth,
            height: max(4000, maximumHeight * 2)
        )
        measuringHostingView.layoutSubtreeIfNeeded()

        let fittingSize = measuringHostingView.fittingSize
        let width = min(maximumWidth, max(minimumWidth, ceil(fittingSize.width)))
        let height = min(maximumHeight, max(minimumHeight, ceil(fittingSize.height)))
        return CGSize(width: width, height: height)
    }

    /// Computes where the bubble's bottom-left corner should sit, in the
    /// overlay window's local coords, given the cursor's current global
    /// position. Mirrors to the left of the cursor if the right edge
    /// would clip, and clamps into the screen's safe area.
    private func computeBubbleOriginNearCursor(
        cursorInScreenCoords: CGPoint,
        screen: NSScreen,
        bubbleWidth: CGFloat,
        bubbleHeight: CGFloat
    ) -> CGPoint {
        let cursorInWindowLocalX = cursorInScreenCoords.x - screen.frame.origin.x
        let cursorInWindowLocalY = cursorInScreenCoords.y - screen.frame.origin.y

        var bubbleOriginX = cursorInWindowLocalX + cursorToBubbleHorizontalGap
        var bubbleOriginY = cursorInWindowLocalY - bubbleHeight / 2

        // Mirror to the LEFT of the cursor if we'd overflow the right edge.
        if bubbleOriginX + bubbleWidth > screen.frame.size.width - bubbleScreenEdgePadding {
            bubbleOriginX = cursorInWindowLocalX - cursorToBubbleHorizontalGap - bubbleWidth
        }
        // Clamp left.
        if bubbleOriginX < bubbleScreenEdgePadding {
            bubbleOriginX = bubbleScreenEdgePadding
        }
        // Clamp vertically.
        let minimumOriginY = bubbleScreenEdgePadding
        let maximumOriginY = screen.frame.size.height - bubbleHeight - bubbleScreenEdgePadding
        if maximumOriginY <= minimumOriginY {
            bubbleOriginY = minimumOriginY
        } else {
            if bubbleOriginY < minimumOriginY { bubbleOriginY = minimumOriginY }
            if bubbleOriginY > maximumOriginY { bubbleOriginY = maximumOriginY }
        }

        return CGPoint(x: bubbleOriginX, y: bubbleOriginY)
    }

    private func startCursorFollowTimer() {
        stopCursorFollowTimer()
        // ~60 Hz (16.67ms) — matches the display refresh on most Macs and
        // produces a buttery-smooth follow without burning CPU.
        cursorFollowTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advanceCursorFollowOneFrame()
            }
        }
        // Put the timer on the .common run loop mode so it keeps ticking
        // while other apps (Claude/Cursor) are receiving events. Without
        // this, the timer can pause when something else is interacting.
        if let cursorFollowTimer {
            RunLoop.current.add(cursorFollowTimer, forMode: .common)
        }
    }

    private func stopCursorFollowTimer() {
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
    }

    /// One frame of "ease the bubble toward the cursor". Uses a simple
    /// linear-interpolation factor — at 60Hz with t = 0.22, the bubble
    /// catches up to within a pixel of the cursor in ~10 frames (~160ms).
    /// That feels glued without looking like it teleports.
    private func advanceCursorFollowOneFrame() {
        guard isShowingBubble,
              let overlayWindow,
              let hostingView = bubbleHostingView,
              currentBubbleSize != .zero
        else { return }

        // Recompute which screen the cursor is on every frame so dragging
        // across monitors hands the bubble over to the right overlay.
        let cursorScreenPoint = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPoint) })
            ?? NSScreen.main
        guard let screen = cursorScreen else { return }

        // If the cursor moved to a different monitor than the overlay
        // window's screen, move the overlay there.
        if overlayWindow.frame != screen.frame {
            overlayWindow.setFrame(screen.frame, display: true)
            // Reset the smoothed origin so we don't try to ease across the
            // monitor seam — teleport into the new screen instead.
            smoothedBubbleOriginInWindowCoords = nil
        }

        let targetOrigin = computeBubbleOriginNearCursor(
            cursorInScreenCoords: cursorScreenPoint,
            screen: screen,
            bubbleWidth: currentBubbleSize.width,
            bubbleHeight: currentBubbleSize.height
        )

        // Ease toward the target. The factor controls "stiffness" of the
        // follow — higher = snappier, lower = lazier. 0.22 feels right
        // for "glued but not jittery".
        let easeFactor: CGFloat = 0.22
        let previous = smoothedBubbleOriginInWindowCoords ?? targetOrigin
        let nextOrigin = CGPoint(
            x: previous.x + (targetOrigin.x - previous.x) * easeFactor,
            y: previous.y + (targetOrigin.y - previous.y) * easeFactor
        )
        smoothedBubbleOriginInWindowCoords = nextOrigin

        // Skip the frame entirely if we're within half a pixel of the
        // target — avoids burning cycles redrawing for sub-pixel motion.
        if abs(nextOrigin.x - hostingView.frame.origin.x) < 0.5
            && abs(nextOrigin.y - hostingView.frame.origin.y) < 0.5 {
            return
        }

        hostingView.frame = NSRect(
            x: nextOrigin.x,
            y: nextOrigin.y,
            width: currentBubbleSize.width,
            height: currentBubbleSize.height
        )
    }

    // MARK: - Window plumbing

    private func ensureOverlayWindow(forScreen screen: NSScreen) {
        if let existingWindow = overlayWindow {
            if existingWindow.frame != screen.frame {
                existingWindow.setFrame(screen.frame, display: true)
            }
            return
        }

        let newOverlayWindow = BubbleOverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        newOverlayWindow.isOpaque = false
        newOverlayWindow.backgroundColor = .clear
        newOverlayWindow.level = .screenSaver
        newOverlayWindow.ignoresMouseEvents = true
        newOverlayWindow.hasShadow = false
        newOverlayWindow.hidesOnDeactivate = false
        newOverlayWindow.isReleasedWhenClosed = false
        newOverlayWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
        ]

        // Plain transparent NSView as the content view. The bubble
        // NSHostingView gets added as a subview and positioned by frame.
        let containerView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        newOverlayWindow.contentView = containerView

        newOverlayWindow.setFrame(screen.frame, display: true)
        self.overlayWindow = newOverlayWindow
    }

    /// One-off compositing test: flash a translucent yellow background
    /// across the whole overlay window for 200ms. If the user sees the
    /// flash, the overlay window is reaching the screen — the bubble's
    /// invisibility is then about the bubble's own subview, not the
    /// window. If they don't see it, the window itself is being
    /// suppressed and we have a deeper macOS-level issue to track down.
    private func flashYellowDiagnosticBackground() {
        guard let containerView = overlayWindow?.contentView else { return }
        let flashLayer = CALayer()
        flashLayer.frame = containerView.bounds
        flashLayer.backgroundColor = NSColor.yellow.withAlphaComponent(0.25).cgColor
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        containerView.layer?.addSublayer(flashLayer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            flashLayer.removeFromSuperlayer()
        }
    }

    // MARK: - Dismissal

    private func scheduleAutoDismiss() {
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.bubbleAutoDismissSeconds ?? 7.0) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismiss()
            }
        }
    }

    private func installEscapeKeyDismissMonitor() {
        removeEscapeKeyDismissMonitor()
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {  // kVK_Escape
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }
    }

    private func removeEscapeKeyDismissMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}

// MARK: - SwiftUI bubble pill view

/// Observable model that drives the typewriter effect inside the bubble.
/// We keep three pieces of text:
///
///  - `targetNudgeText`     — the full nudge the model returned.
///  - `targetRewriteText`   — the full rewrite the model returned (may be nil).
///  - `revealedCharacterCount` — how many characters of the COMBINED stream
///    have been "typed" so far. The view slices the targets based on this.
///
/// We type nudge first, then rewrite, so it reads like a thought finishing
/// before the worked example appears.
@MainActor
final class NudgeBubbleTypewriterModel: ObservableObject {
    @Published var targetNudgeText: String = ""
    @Published var targetRewriteText: String? = nil
    @Published var modeLabel: String? = nil
    /// Count of characters revealed across (nudge ++ rewrite). The view
    /// derives the substrings each frame from this single counter.
    @Published var revealedCharacterCount: Int = 0
    /// When true, render the affordance line ("Tab to copy"). We only
    /// show it once the rewrite is fully typed so it doesn't appear
    /// mid-stream and visually shift the layout.
    @Published var hasFinishedTypingRewrite: Bool = false

    private var typewriterTimer: Timer?

    /// Characters per second of typing. ~80 cps reads like a fast human
    /// thinker — slow enough to scan along, fast enough that a 2-sentence
    /// nudge finishes in ~1.5s. Tweakable if it feels off.
    private let charactersPerSecond: Double = 80.0

    /// Reset the model with new content and start the typewriter from
    /// zero. Safe to call repeatedly — the previous timer is cancelled.
    func startTypingFresh(
        nudgeText: String,
        rewriteText: String?,
        modeLabel: String?
    ) {
        stopTyping()
        self.targetNudgeText = nudgeText
        self.targetRewriteText = rewriteText
        self.modeLabel = modeLabel
        self.revealedCharacterCount = 0
        self.hasFinishedTypingRewrite = false

        let totalCharactersToReveal = nudgeText.count + (rewriteText?.count ?? 0)
        // Edge case: empty nudge. Treat as already-done.
        guard totalCharactersToReveal > 0 else {
            self.hasFinishedTypingRewrite = (rewriteText?.isEmpty ?? true)
            return
        }

        typewriterTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / charactersPerSecond,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.revealedCharacterCount >= totalCharactersToReveal {
                    timer.invalidate()
                    self.typewriterTimer = nil
                    self.hasFinishedTypingRewrite = true
                    return
                }
                self.revealedCharacterCount += 1
            }
        }
        if let typewriterTimer {
            RunLoop.current.add(typewriterTimer, forMode: .common)
        }
    }

    /// Stops the timer; the current `revealedCharacterCount` stays as-is.
    /// Used when the bubble is being torn down before typing finishes.
    func stopTyping() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }

    /// Substrings to render this frame. We split the single counter
    /// across nudge first, rewrite second, so the rewrite block doesn't
    /// "appear" until the nudge has fully typed in.
    var revealedNudgeSubstring: String {
        let limit = min(revealedCharacterCount, targetNudgeText.count)
        return String(targetNudgeText.prefix(limit))
    }

    var revealedRewriteSubstring: String? {
        guard let targetRewriteText else { return nil }
        let charactersAlreadyUsedByNudge = min(revealedCharacterCount, targetNudgeText.count)
        let charactersAvailableForRewrite = max(0, revealedCharacterCount - charactersAlreadyUsedByNudge)
        return String(targetRewriteText.prefix(charactersAvailableForRewrite))
    }
}

private struct NudgeBubbleView: View {
    @ObservedObject var typewriterModel: NudgeBubbleTypewriterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let modeLabel = typewriterModel.modeLabel, !modeLabel.isEmpty {
                Text(modeLabel.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(0.8)
            }
            // Nudge body — slices to the typewriter's current position so
            // the user sees characters appearing one at a time.
            Text(typewriterModel.revealedNudgeSubstring)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            // Rewrite block — only shown once the nudge has at least
            // started revealing characters from it (otherwise the block
            // appears with an empty body and looks like a bug).
            if let rewriteText = typewriterModel.targetRewriteText,
               !rewriteText.isEmpty,
               let revealedRewrite = typewriterModel.revealedRewriteSubstring,
               !revealedRewrite.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.18))
                    .padding(.vertical, 2)
                Text(revealedRewrite)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Affordance line — only shown after the rewrite is fully
            // typed in, so it doesn't slide around mid-typing. Whether
            // it's visible at all depends on having a real rewrite.
            if typewriterModel.hasFinishedTypingRewrite,
               let rewriteText = typewriterModel.targetRewriteText,
               !rewriteText.isEmpty {
                HStack(spacing: 6) {
                    Text("⇥")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.12))
                        )
                    Text("Tab to copy")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Frame to the FINAL size at all times. We compute this size
        // up-front from the full text in NudgeBubbleWindow so the pill
        // doesn't resize as characters appear — only the text inside
        // grows. The .frame(maxWidth:) on the hosting view at construction
        // pins the width; height adapts to whichever measure was taken
        // at the start of typing.
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
    }
}
