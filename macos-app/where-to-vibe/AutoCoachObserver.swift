//
//  AutoCoachObserver.swift
//  where-to-vibe
//
//  Implements ARCHITECTURE.md §4.1 (auto trigger) and §4.2 (dedupe) for the
//  text-based coding coach.
//
//  Loop:
//   1. Every `tickIntervalSeconds` while the panel is enabled, check the
//      frontmost application's bundle ID and name.
//   2. If the frontmost app is NOT in the AI-chat / terminal / editor
//      allow-list, do nothing (we don't even take a screenshot — cheap and
//      respectful of the user's other workflows).
//   3. If the frontmost app IS in the allow-list, take a low-resolution
//      JPEG snapshot of the focused screen.
//   4. Diff a hash of that snapshot against the previous one. If the screen
//      has been *stable for ≥ stableScreenSecondsBeforeCoach seconds*, that
//      is our proxy for "the user paused typing for 3-4s" — fire /coach.
//   5. When /coach returns, hash (mode + nudge + rewrite) and check the
//      last-N ring buffer. Drop if duplicate; render the NudgeBubbleWindow
//      otherwise, and push the hash onto the buffer.
//
//  This screen-diff fallback is exactly the path ARCHITECTURE.md §4.1
//  authorises for apps where we don't have Accessibility-API access to the
//  input field. We can swap in a transition-based path per-app later
//  without changing the worker contract.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class AutoCoachObserver {

    // MARK: - Tunables

    /// How often the observer wakes up to inspect the frontmost app. 1s is
    /// the upper bound called out in ARCHITECTURE.md §4.1.
    private let tickIntervalSeconds: TimeInterval = 1.0

    /// How long the screen content must be stable (frame-to-frame hash
    /// unchanged) before we fire /coach. Aggressively short (0.4s) so the
    /// human-perceived latency from "pause typing" → "bubble appears" is
    /// dominated by the Claude round-trip, not by us waiting for stability.
    /// ARCHITECTURE.md §4.1 explicitly allows tightening this when the
    /// screen-diff signal is reliable.
    private let stableScreenSecondsBeforeCoach: TimeInterval = 0.4

    /// Minimum gap between two /coach calls regardless of signals. Set
    /// to 12s = nudge auto-dismiss (7s) + a 5s read-and-act buffer, so
    /// the user has time to absorb advice + change their prompt before
    /// the next round-trip fires. Without this gap, a still screen kept
    /// firing /coach every tick, producing the model-coaches-its-own-
    /// past-advice loop we saw in the wild.
    private let minimumSecondsBetweenCoachCalls: TimeInterval = 12.0

    /// Maximum nudge hashes remembered for dedupe. Sized so a user cycling
    /// through 3-4 prompts in a session doesn't see the same advice twice.
    private let recentNudgeHashCapacity = 5

    /// JPEG compression quality for the screenshot sent to /coach. Low
    /// enough to keep upload fast, high enough that Claude can still read
    /// prompt text. 0.5 is the sweet spot for screen text content.
    private let screenshotJPEGQuality: CGFloat = 0.5

    /// Downscale the captured CGImage to this max long-edge before
    /// encoding. 720px is enough for Haiku to read prompt + visible
    /// code text reliably, and shaves vision tokens ~20% versus 900px.
    /// For Haiku on coaching-style tasks, this is the sweet spot
    /// between legibility and latency.
    private let screenshotMaxLongEdgePixels: CGFloat = 720

    // MARK: - Allow-lists (mirror worker/src/triggers.ts)

    /// Apps where coaching is welcome. We poll only when the frontmost app
    /// matches one of these — outside this list we do nothing.
    /// Bundle IDs are preferred (immune to rename); names are a fallback.
    private let allowedAppBundleIDs: Set<String> = [
        // AI chat / IDE-with-AI
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.anthropic.claudefordesktop",  // Claude desktop
        "com.openai.chat",                 // ChatGPT desktop (if installed)
        "dev.zed.Zed",                     // Zed
        "com.codeium.windsurf",            // Windsurf
        // Editors that often have AI chat panes
        "com.microsoft.VSCode",            // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.apple.dt.Xcode",
        // Terminals (for error_first_cause)
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        // Browsers (for chatgpt.com / claude.ai / etc.)
        "com.google.Chrome",
        "company.thebrowser.Browser",       // Arc
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]
    private let allowedAppNames: Set<String> = [
        "Cursor", "Claude", "ChatGPT", "Codex", "Windsurf", "Zed", "Continue",
        "Visual Studio Code", "VS Code", "Code", "Xcode",
        "Terminal", "iTerm2", "iTerm", "Warp", "Ghostty", "Alacritty", "Hyper",
        "Kitty", "WezTerm",
        "Google Chrome", "Chrome", "Safari", "Arc", "Microsoft Edge", "Brave Browser",
    ]

    // MARK: - State

    private weak var companionManager: CompanionManager?
    private let coachAPIClient: CoachAPIClient
    private let nudgeBubbleWindow = NudgeBubbleWindow()
    /// Tab key intercept — when the bubble has a rewrite, Tab copies it
    /// to the pasteboard instead of being delivered to the user's app.
    private lazy var tabKeyInterceptor = TabKeyInterceptor(nudgeBubbleWindow: nudgeBubbleWindow)
    private var tickTimer: Timer?

    /// Last screenshot's content hash. Used to detect "screen unchanged".
    private var previousScreenshotHash: Int?
    /// When the screen first hit the current hash (i.e. when it became
    /// stable). nil until we see two identical hashes in a row.
    private var screenStableSinceTimestamp: Date?
    /// When the last /coach call started, to enforce the minimum gap.
    private var lastCoachCallTimestamp: Date?
    /// Whether a /coach round-trip is currently in flight (we only allow one
    /// at a time — if one is taking 30s, we don't pile a second on top).
    private var coachCallInFlight: Bool = false
    /// Ring buffer of recent nudge hashes for dedupe (§4.2).
    private var recentNudgeHashes: [Int] = []

    // MARK: - Init

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        // Resolve the worker base URL once from Info.plist. Falls back to
        // localhost so wrangler dev works out of the box.
        let resolvedWorkerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
            ?? "http://localhost:8787"
        self.coachAPIClient = CoachAPIClient(workerBaseURL: resolvedWorkerBaseURL)
    }

    // MARK: - Lifecycle

    func start() {
        guard tickTimer == nil else { return }
        // Timer rather than DispatchSourceTimer so we stay on the main
        // RunLoop and don't need extra @MainActor hops.
        tickTimer = Timer.scheduledTimer(
            withTimeInterval: tickIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.observeOnce()
            }
        }
        // Start the Tab-key interceptor alongside the observer. The
        // interceptor only consumes Tab when a copyable rewrite is on
        // screen — outside of that, Tab passes through to the user's
        // editor / chat app as normal.
        tabKeyInterceptor.start()
        print("🧠 AutoCoachObserver started (tick=\(tickIntervalSeconds)s, stable=\(stableScreenSecondsBeforeCoach)s)")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        tabKeyInterceptor.stop()
        nudgeBubbleWindow.dismiss()
        coachCallInFlight = false
    }

    // MARK: - The tick

    private func observeOnce() {
        guard let companionManager else { return }
        // Hard kill-switch from the panel UI.
        guard companionManager.isAutoCoachEnabled else { return }
        // The user hasn't granted screen recording yet — we can't do
        // anything useful. Bail silently rather than spamming logs.
        guard companionManager.hasScreenRecordingPermission else { return }
        // Don't even ask about other apps if a /coach call is already
        // running. The result will land in a moment.
        guard coachCallInFlight == false else { return }
        // Don't pile new nudges on top of one the user is still reading.
        // The bubble auto-dismisses after 7s; until then we stay silent.
        guard nudgeBubbleWindow.isShowingBubble == false else { return }

        // Step 1: cheap allow-list gate on the frontmost app.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        guard isAllowedFrontApp(frontApp) else {
            // Reset stability tracking when the user navigates away from a
            // coachable app, so when they come back we wait for a fresh
            // pause rather than firing instantly.
            previousScreenshotHash = nil
            screenStableSinceTimestamp = nil
            return
        }

        // Step 2: cheap rate limiter.
        if let lastCoachCallTimestamp,
           Date().timeIntervalSince(lastCoachCallTimestamp) < minimumSecondsBetweenCoachCalls {
            return
        }

        // Step 3: snapshot the focused screen. We do this every tick so we
        // can diff successive frames — without a snapshot we can't tell if
        // the screen has been stable. Capture is on the order of 30ms on
        // modern Macs, well under our 1s budget.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshotJPEG = await self.captureCurrentScreenAsJPEG(frontApp: frontApp) else { return }

            // Hash content rather than comparing raw bytes — a single pixel
            // difference shouldn't reset stability. Bucket to the nearest
            // ~512 bytes so JPEG entropy noise doesn't keep flipping.
            let currentHash = self.coarseHashOfJPEG(snapshotJPEG)

            if self.previousScreenshotHash == currentHash {
                // Screen unchanged since last tick.
                if self.screenStableSinceTimestamp == nil {
                    self.screenStableSinceTimestamp = Date()
                }
            } else {
                // Screen changed — restart the stability clock.
                self.previousScreenshotHash = currentHash
                self.screenStableSinceTimestamp = Date()
                return
            }

            // Step 4: stability budget met?
            guard let stableSince = self.screenStableSinceTimestamp,
                  Date().timeIntervalSince(stableSince) >= self.stableScreenSecondsBeforeCoach
            else {
                return
            }

            // Step 5: fire /coach. We arm the rate limiter *before* the
            // call so a fresh tick mid-call doesn't double-fire, and we
            // intentionally don't reset stability — we want the very next
            // change on screen (user starts typing again) to be the next
            // stability anchor.
            self.lastCoachCallTimestamp = Date()
            self.coachCallInFlight = true
            print("🧠 firing /coach — capture-time front=\(frontApp.localizedName ?? "?") bundleID=\(frontApp.bundleIdentifier ?? "?")")
            await self.callCoachAndRenderBubble(
                snapshotJPEG: snapshotJPEG,
                frontApp: frontApp
            )
            self.coachCallInFlight = false
        }
    }

    private func isAllowedFrontApp(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, allowedAppBundleIDs.contains(bundleID) {
            return true
        }
        if let name = app.localizedName, allowedAppNames.contains(name) {
            return true
        }
        return false
    }

    // MARK: - Screen capture

    /// Captures the frontmost coachable app's display as a JPEG. Crucially,
    /// excludes our own windows (bubble overlay, menu bar panel, Where-to-vibe
    /// cursor overlay) from the capture so we never feed our own bubble
    /// back into /coach — that path produced the "model coaches its own
    /// past advice" feedback loop.
    ///
    /// Returns nil on permission denial or capture failure (we never throw
    /// — the loop just skips this tick).
    private func captureCurrentScreenAsJPEG(frontApp: NSRunningApplication) async -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            return nil
        }

        // Decide which display to capture. Prefer the display where the
        // frontmost app's *key window* lives — the user is actively
        // editing there. Fall back to the mouse's display, then to the
        // main display. This avoids capturing a different monitor than
        // the one Claude/Cursor is on.
        let targetScreen = screenContainingFrontAppKeyWindow(frontApp: frontApp)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen,
              let displayIDNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(displayIDNumber.uint32Value)

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let scDisplay = availableContent.displays.first(where: { $0.displayID == displayID })
                ?? availableContent.displays.first
            else { return nil }

            // Exclude all of OUR app's windows so the model never sees the
            // bubble, the menu bar panel, or the upstream Where-to-vibe cursor
            // overlay. Identifying by owning PID is robust against window
            // titles changing.
            let ourProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
            let ourOwnWindows = availableContent.windows.filter { $0.owningApplication?.processID == ourProcessID }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(scDisplay.width)
            configuration.height = Int(scDisplay.height)
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let filter = SCContentFilter(display: scDisplay, excludingWindows: ourOwnWindows)

            let capturedCGImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            return encodeAsDownscaledJPEG(capturedCGImage)
        } catch {
            // ScreenCaptureKit throws on permission denial too — we just
            // give up for this tick.
            return nil
        }
    }

    /// Find the NSScreen containing the frontmost app's currently key
    /// window. We can't ask another app directly for its key window
    /// (cross-app AX), but we CAN ask CGWindowList for the on-screen
    /// windows owned by that PID and pick the first one's center. Returns
    /// nil when we can't determine it (e.g. app has no on-screen window),
    /// in which case the caller falls back to other heuristics.
    private func screenContainingFrontAppKeyWindow(frontApp: NSRunningApplication) -> NSScreen? {
        let frontPID = frontApp.processIdentifier
        let cfWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for windowInfo in cfWindowList {
            guard let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowOwnerPID == frontPID,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // Skip tiny utility windows (toolbars, tooltips, < 200pt wide).
            if boundsRect.width < 200 || boundsRect.height < 200 { continue }

            // CGWindow uses top-left origin; NSScreen uses bottom-left.
            // Convert by mirroring Y around the union frame height.
            let unionScreensHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
            let windowCenterInAppKitCoords = CGPoint(
                x: boundsRect.midX,
                y: unionScreensHeight - boundsRect.midY
            )

            if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(windowCenterInAppKitCoords) }) {
                return containingScreen
            }
        }
        return nil
    }

    /// Downscale + JPEG encode. We deliberately downscale because:
    /// (a) Claude vision charges per pixel; (b) the worker has size limits;
    /// (c) the model only needs to read prompt text, not antialiased fonts.
    private func encodeAsDownscaledJPEG(_ image: CGImage) -> Data? {
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let longEdge = max(originalWidth, originalHeight)
        let downscale = min(1.0, screenshotMaxLongEdgePixels / longEdge)
        let targetWidth = Int(originalWidth * downscale)
        let targetHeight = Int(originalHeight * downscale)

        let bitsPerComponent = 8
        let bytesPerRow = 0  // let CG pick optimal stride
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resizedImage = context.makeImage() else { return nil }

        let nsImage = NSImage(cgImage: resizedImage, size: NSSize(width: targetWidth, height: targetHeight))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: screenshotJPEGQuality]
        )
    }

    /// Coarse content hash — folds JPEG bytes into a single Int. Tiny entropy
    /// noise (cursor blink, antialiasing jitter) typically doesn't change
    /// the result because JPEG compression is block-based. Cheap and good
    /// enough for "is this the same screen".
    private func coarseHashOfJPEG(_ data: Data) -> Int {
        var hasher = Hasher()
        // Use first 4KB + length so we don't hash megabytes per tick. The
        // first JPEG block captures most of the perceptual content.
        hasher.combine(data.prefix(4096))
        hasher.combine(data.count)
        return hasher.finalize()
    }

    // MARK: - /coach call + bubble render

    private func callCoachAndRenderBubble(
        snapshotJPEG: Data,
        frontApp: NSRunningApplication
    ) async {
        let hints = CoachClientHints(
            frontmostBundleID: frontApp.bundleIdentifier,
            typingPaused: true
        )

        let frontAppNameForCue = frontApp.localizedName ?? "the foreground app"
        let coachingFocusCue = """
        Context: the user just paused typing inside \(frontAppNameForCue). \
        If there's draft text in an AI-chat input field (usually at the \
        bottom or in a right sidebar), that text is what they want \
        coaching on — read it carefully and coach about THAT specifically, \
        not about other code or output also visible on screen.
        """

        // Streaming round-trip. We open the bubble immediately (empty),
        // then update its nudge text as each token arrives, then
        // finalize with rewrite/mode when the JSON completes. Drops to
        // silent if the final mode is "none" or if dedupe matches.
        var hasOpenedStreamingBubble = false
        var lastSeenNudgeForDedupeCheck = ""

        let eventStream = coachAPIClient.requestCoachAdviceStreaming(
            screenshotsJPEG: [(jpegData: snapshotJPEG, label: frontApp.localizedName)],
            userText: coachingFocusCue,
            hints: hints
        )

        for await event in eventStream {
            switch event {
            case .partialNudge(let nudgeSoFar):
                // First token: open the bubble now so the user sees
                // *something* the instant streaming begins.
                if !hasOpenedStreamingBubble {
                    hasOpenedStreamingBubble = true
                    print("🧠 stream opened — showing bubble.")
                    nudgeBubbleWindow.showStreamingBubbleAtCurrentCursor(modeLabelHint: nil)
                }
                lastSeenNudgeForDedupeCheck = nudgeSoFar
                nudgeBubbleWindow.appendStreamedNudgeText(nudgeSoFar)

            case .partialRewrite(let rewriteSoFar):
                // rewrite tokens can start arriving before nudge is
                // technically done (the model writes nudge → rewrite in
                // the JSON, but each is just a string field). Open the
                // bubble if we somehow got here without a nudge event
                // first, so the rewrite text doesn't go to /dev/null.
                if !hasOpenedStreamingBubble {
                    hasOpenedStreamingBubble = true
                    print("🧠 stream opened (rewrite-first) — showing bubble.")
                    nudgeBubbleWindow.showStreamingBubbleAtCurrentCursor(modeLabelHint: nil)
                }
                nudgeBubbleWindow.appendStreamedRewriteText(rewriteSoFar)

            case .completed(let response):
                print("🧠 /coach-stream OK — mode=\(response.mode) nudge=\"\(response.nudge.prefix(160))\" rewrite=\(response.rewrite != nil)")

                // mode:"none" — model decided nothing actionable.
                // Tear down whatever streaming bubble we opened.
                if response.mode == "none" {
                    print("🧠 mode=none — dismissing partial bubble.")
                    nudgeBubbleWindow.dismiss()
                    return
                }

                // Dedupe: skip identical nudges to keep noise low.
                let nudgeHash = hashOfNudgeForDedupe(response)
                if recentNudgeHashes.contains(nudgeHash) {
                    print("🧠 deduped — dismissing partial bubble.")
                    nudgeBubbleWindow.dismiss()
                    return
                }
                pushNudgeHashForDedupe(nudgeHash)

                // If we never opened the streaming bubble (the nudge
                // field was empty during streaming for some reason),
                // open it now so the user still sees the final result.
                if !hasOpenedStreamingBubble {
                    print("🧠 stream completed without partials — opening bubble for final.")
                    nudgeBubbleWindow.showStreamingBubbleAtCurrentCursor(modeLabelHint: response.mode)
                    nudgeBubbleWindow.appendStreamedNudgeText(response.nudge)
                }
                nudgeBubbleWindow.finalizeStreamedBubble(with: response)
                return

            case .failed(let error):
                print("🧠 /coach-stream failed: \(error) — partialNudgeSoFar=\"\(lastSeenNudgeForDedupeCheck.prefix(80))\"")
                if hasOpenedStreamingBubble {
                    nudgeBubbleWindow.handleStreamFailure(error: error)
                }
                return
            }
        }
    }

    private func hashOfNudgeForDedupe(_ response: CoachResponse) -> Int {
        var hasher = Hasher()
        hasher.combine(response.mode)
        hasher.combine(response.nudge)
        hasher.combine(response.rewrite ?? "")
        return hasher.finalize()
    }

    private func pushNudgeHashForDedupe(_ hash: Int) {
        recentNudgeHashes.append(hash)
        if recentNudgeHashes.count > recentNudgeHashCapacity {
            recentNudgeHashes.removeFirst(recentNudgeHashes.count - recentNudgeHashCapacity)
        }
    }
}
