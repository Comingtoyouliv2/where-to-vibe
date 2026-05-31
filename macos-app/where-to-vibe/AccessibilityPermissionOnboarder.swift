//
//  AccessibilityPermissionOnboarder.swift
//  where-to-vibe
//
//  Automates the first-launch Accessibility-permission flow so the user's only
//  action is a single click: flipping this app's toggle in the System Settings
//  Accessibility list. Everything else is automatic —
//
//   1. The app is silently registered into the Accessibility list (so a toggle
//      already exists for it; no modal alert, no "drag the app in" step).
//   2. System Settings is opened straight to the Accessibility pane.
//   3. We poll for the grant and, the moment the user flips the toggle on,
//      continue onboarding in place — no quit, no relaunch.
//

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityPermissionOnboarder {
    /// How often we re-check whether the user has flipped the toggle on.
    private let pollInterval: TimeInterval = 0.6

    private var pollTimer: Timer?
    /// Called exactly once, on the main actor, the instant permission is granted
    /// (or immediately if it was already granted when `start` was called).
    private var onGranted: (() -> Void)?

    /// True while we are actively waiting for the user to grant permission.
    private(set) var isWaitingForGrant = false

    /// Begins the guided flow. If permission is already granted this calls
    /// `onGranted` synchronously and does nothing else. Otherwise it registers
    /// the app, opens the Accessibility pane, and starts polling; `onGranted`
    /// fires later, once, when the toggle is switched on.
    func start(onGranted: @escaping () -> Void) {
        if WindowPositionManager.hasAccessibilityPermission() {
            onGranted()
            return
        }

        self.onGranted = onGranted
        isWaitingForGrant = true

        registerAndOpenSettings()
        startPolling()
    }

    /// Registers the app into the Accessibility list (so a ready-made toggle
    /// exists) and opens the System Settings Accessibility pane — without any
    /// polling. Use when the caller drives its own wait loop, e.g. the intro
    /// tutorial, which already runs an async sequence and just needs the pane
    /// opened with the app pre-listed.
    func registerAndOpenSettings() {
        registerAppInAccessibilityList()
        WindowPositionManager.openAccessibilitySettings()
    }

    /// Stops polling without firing the callback. Safe to call multiple times.
    func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        isWaitingForGrant = false
        onGranted = nil
    }

    // MARK: - Private

    /// Performs a real (read-only) Accessibility query. While the app is not yet
    /// trusted this call fails, but the attempt is what makes macOS add the app
    /// to Privacy & Security → Accessibility as an unchecked entry — so the user
    /// finds a ready-made toggle instead of an empty list. Unlike
    /// `AXIsProcessTrustedWithOptions(prompt: true)`, it does NOT pop the modal
    /// alert, which would cost the user an extra click.
    private func registerAppInAccessibilityList() {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        _ = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForGrant()
            }
        }
        // .common so polling continues even while the user is dragging/interacting
        // with other windows (e.g. the System Settings sheet).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func checkForGrant() {
        guard WindowPositionManager.hasAccessibilityPermission() else { return }

        let callback = onGranted
        cancel()

        // Pull our app back to the front so the user sees onboarding resume
        // right after they flip the toggle, instead of being left in Settings.
        NSApp.activate(ignoringOtherApps: true)

        callback?()
    }
}
