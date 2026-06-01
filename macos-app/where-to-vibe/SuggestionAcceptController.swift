import AppKit
import CoreGraphics
import Foundation

enum ObservedKeyInput {
    case text(String)
    case backspace
    case deleteForward
    case commit
}

@MainActor
final class SuggestionAcceptController {
    private let tabKeyCode: Int64 = 0x30
    private let escapeKeyCode: Int64 = 0x35
    private let leftArrowKeyCode: Int64 = 0x7B
    private let rightArrowKeyCode: Int64 = 0x7C

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isConsumingTabPress = false
    private var isConsumingEscapePress = false
    private var isConsumingArrowPress = false

    var shouldHandleKeys: (() -> Bool)?
    var shouldObserveKeys: (() -> Bool)?
    var canAcceptWithTab: (() -> Bool)?
    var accept: (() -> Void)?
    var dismiss: (() -> Void)?
    var observeKeyInput: ((ObservedKeyInput) -> Void)?
    /// True when the advice card has more than one page, so ←/→ should flip it
    /// (and be consumed) instead of passing through to the user's app.
    var canNavigatePages: (() -> Bool)?
    /// Flip the advice card by `delta` pages (+1 = right, -1 = left).
    var navigatePage: ((Int) -> Void)?

    /// Creates the Tab/Esc CGEvent tap. Returns true if the tap is up (newly
    /// created or already running), false if creation failed. The caller MUST
    /// use this result to decide whether key handling is really active —
    /// otherwise a transient failure (e.g. a TCC trust race right after launch
    /// or a rebuild) leaves us thinking we're handling keys when no tap exists,
    /// and we never retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }  // already running

        let monitoredTypes: [CGEventType] = [.keyDown, .keyUp]
        let eventMask = monitoredTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SuggestionAcceptController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return controller.handle(eventType: eventType, event: event)
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("PromptCoach: could not create key event tap (will retry). Accessibility may not be ready yet.")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            CFMachPortInvalidate(createdTap)
            return false
        }

        eventTap = createdTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        print("PromptCoach: key event tap created — Tab-to-copy is active.")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard eventType == .keyDown || eventType == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if eventType == .keyDown,
           shouldObserveKeys?() == true,
           let observedInput = observedInput(from: event, keyCode: keyCode) {
            DispatchQueue.main.async { [weak self] in
                self?.observeKeyInput?(observedInput)
            }
        }

        guard shouldHandleKeys?() == true else {
            return Unmanaged.passUnretained(event)
        }

        let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard event.flags.intersection(modifierMask).isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        switch keyCode {
        case tabKeyCode:
            if eventType == .keyDown {
                let canAccept = canAcceptWithTab?() == true
                print("⌨️[TabCopy] Tab keydown reached the tap — canAcceptWithTab=\(canAccept)")
                guard canAccept else {
                    isConsumingTabPress = false
                    return Unmanaged.passUnretained(event)
                }
                isConsumingTabPress = true
                DispatchQueue.main.async { [weak self] in
                    self?.accept?()
                }
                return nil
            }
            if isConsumingTabPress {
                isConsumingTabPress = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        case escapeKeyCode:
            if eventType == .keyDown {
                isConsumingEscapePress = true
                DispatchQueue.main.async { [weak self] in
                    self?.dismiss?()
                }
                return nil
            }
            if isConsumingEscapePress {
                isConsumingEscapePress = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        case leftArrowKeyCode, rightArrowKeyCode:
            // Flip the advice card's page. Only consume the arrow (so the user's
            // app doesn't move its cursor) when the card actually has a 2nd page;
            // otherwise let the arrow pass through normally.
            if eventType == .keyDown {
                guard canNavigatePages?() == true else {
                    isConsumingArrowPress = false
                    return Unmanaged.passUnretained(event)
                }
                isConsumingArrowPress = true
                let delta: Int = (keyCode == rightArrowKeyCode) ? 1 : -1
                DispatchQueue.main.async { [weak self] in
                    self?.navigatePage?(delta)
                }
                return nil
            }
            if isConsumingArrowPress {
                isConsumingArrowPress = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func observedInput(from event: CGEvent, keyCode: Int64) -> ObservedKeyInput? {
        let nonTextModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.intersection(nonTextModifierMask).isEmpty else { return nil }

        switch keyCode {
        case 0x33:
            return .backspace
        case 0x75:
            return .deleteForward
        case 0x24, 0x4C:
            return .commit
        case tabKeyCode, escapeKeyCode:
            return nil
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: chars.count,
            actualStringLength: &length,
            unicodeString: &chars
        )

        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        guard string.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return .text(string)
    }
}
