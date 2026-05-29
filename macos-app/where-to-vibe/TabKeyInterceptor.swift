//
//  TabKeyInterceptor.swift
//  where-to-vibe
//
//  System-wide CGEventTap that consumes Tab keypresses ONLY when the
//  nudge bubble is currently showing a rewrite the user might want to
//  copy. In every other situation Tab passes through untouched, so the
//  user's editor / chat input field behaves normally.
//
//  Behaviour:
//  - User is typing in Cursor/Claude/etc, no bubble visible → Tab inserts
//    indentation as usual. We don't even see the event.
//  - Auto-coach bubble is visible with a `rewrite` block (vague_build_me,
//    spec_rewrite, etc.) → Tab is intercepted. We copy the rewrite to the
//    pasteboard, show a brief "Copied — paste with ⌘V" confirmation in
//    place of the bubble, and dismiss. The Tab character is never
//    delivered to the user's app.
//  - Bubble is visible but has no rewrite (pure nudge, no copyable spec)
//    → Tab passes through. There's nothing to copy.
//
//  Same CGEventTap mechanism as GlobalPushToTalkShortcutMonitor.swift, but
//  with `.defaultTap` (not `.listenOnly`) so we can actually consume the
//  event by returning nil from the callback.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class TabKeyInterceptor {

    /// Hardcoded keycode for Tab. The constant lives in Carbon
    /// (kVK_Tab = 0x30) which we don't want to import.
    private let tabKeyCode: Int64 = 0x30

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// The bubble whose `availableRewriteForCopy` we read on Tab. Held
    /// weakly so the interceptor doesn't keep the bubble alive past its
    /// natural lifecycle.
    private weak var nudgeBubbleWindow: NudgeBubbleWindow?

    init(nudgeBubbleWindow: NudgeBubbleWindow) {
        self.nudgeBubbleWindow = nudgeBubbleWindow
    }

    deinit {
        // deinit runs on whatever thread releases us; CGEvent tap APIs are
        // thread-safe so this is fine to call here.
        if let globalEventTap {
            CGEvent.tapEnable(tap: globalEventTap, enable: false)
            CFMachPortInvalidate(globalEventTap)
        }
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        }
    }

    func start() {
        // Idempotent: don't re-create the tap if it's already running.
        guard globalEventTap == nil else { return }

        // We only care about key-downs (and key-ups, so we can suppress the
        // pair cleanly). Mouse events aren't filtered here.
        let monitoredEventTypes: [CGEventType] = [.keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let tabEventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let tabKeyInterceptor = Unmanaged<TabKeyInterceptor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return tabKeyInterceptor.handleEventFromTap(
                eventType: eventType,
                event: event
            )
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // not .listenOnly — we want to consume
            eventsOfInterest: eventMask,
            callback: tabEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ TabKeyInterceptor: couldn't create CGEvent tap (Accessibility permission missing?)")
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            createdEventTap,
            0
        ) else {
            CFMachPortInvalidate(createdEventTap)
            print("⚠️ TabKeyInterceptor: couldn't create run loop source")
            return
        }

        self.globalEventTap = createdEventTap
        self.globalEventTapRunLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        print("⌨️ TabKeyInterceptor: started (will consume Tab only when bubble has a rewrite).")
    }

    func stop() {
        if let globalEventTap {
            CGEvent.tapEnable(tap: globalEventTap, enable: false)
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
    }

    /// CGEvent tap callback. Runs on the main run loop. Decides per-event
    /// whether to swallow it (return nil) or pass it through (return the
    /// unmanaged event).
    private func handleEventFromTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // First, re-arm the tap if the OS disabled it (timeout / user
        // toggled Accessibility off). Otherwise our app silently goes
        // deaf to Tab without any obvious signal.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard eventType == .keyDown || eventType == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let pressedKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard pressedKeyCode == tabKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Don't intercept Tab if it has modifiers (Cmd+Tab for app switch,
        // Ctrl+Tab for tab switching, etc.). We only want a plain Tab.
        let modifierFlags = event.flags
        let consequentialModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if modifierFlags.intersection(consequentialModifierMask).rawValue != 0 {
            return Unmanaged.passUnretained(event)
        }

        // Read the bubble's current rewrite. The interceptor runs on the
        // main thread (CFRunLoopGetMain) so direct property access is fine.
        guard let nudgeBubbleWindow,
              nudgeBubbleWindow.isShowingBubble,
              let rewrite = nudgeBubbleWindow.availableRewriteForCopy,
              !rewrite.isEmpty
        else {
            // No bubble or nothing to copy — let Tab pass through as a
            // normal Tab into whatever app the user is in.
            return Unmanaged.passUnretained(event)
        }

        // Bubble is up AND has a rewrite. Consume the Tab.
        // Only the keyDown actually triggers copy; the keyUp is silently
        // swallowed too so the user's app never sees the pair.
        if eventType == .keyDown {
            _ = nudgeBubbleWindow.copyAvailableRewriteToPasteboardAndShowConfirmation()
        }
        return nil  // consume the event
    }
}
