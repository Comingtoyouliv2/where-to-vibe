import AppKit
import ApplicationServices

enum TextInsertionMode: Equatable {
    case replaceAll
    case insertAtCaret
}

struct FocusedTextSnapshot: Equatable {
    let text: String
    let caretFrame: CGRect?
}

final class AccessibilityTextReader {
    static func hasPermission(prompt: Bool) -> Bool {
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func readFocusedText(allowEmpty: Bool = false) -> FocusedTextSnapshot? {
        guard let element = focusedElement() else { return nil }
        guard let readableElement = bestReadableElement(startingAt: element, allowEmpty: allowEmpty) else { return nil }

        let text = stringAttribute(kAXValueAttribute, from: readableElement)
            ?? stringAttribute(kAXSelectedTextAttribute, from: readableElement)

        guard let text else {
            return allowEmpty
                ? FocusedTextSnapshot(text: "", caretFrame: caretFrame(in: readableElement))
                : nil
        }

        guard allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return FocusedTextSnapshot(
            text: text,
            caretFrame: caretFrame(in: readableElement)
        )
    }

    func insert(_ suggestion: PromptSuggestion, replacing currentText: String?) -> Bool {
        guard let focused = focusedElement() else {
            return pasteWithClipboard(suggestion.text, mode: suggestion.insertionMode)
        }
        guard !isSensitiveTextInput(focused) else { return false }
        let element = bestWritableElement(startingAt: focused) ?? focused

        switch suggestion.insertionMode {
        case .replaceAll:
            if setValue(suggestion.text, on: element) {
                setCaret(offset: suggestion.text.utf16.count, on: element)
                return true
            }
            return pasteWithClipboard(suggestion.text, mode: .replaceAll)

        case .insertAtCaret:
            if insertAtSelectedRange(suggestion.text, in: element) {
                return true
            }
            return pasteWithClipboard(suggestion.text, mode: .insertAtCaret)
        }
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    private func bestReadableElement(startingAt element: AXUIElement, allowEmpty: Bool) -> AXUIElement? {
        if isLikelyTextInput(element), allowEmpty || hasUsefulText(element) {
            return element
        }

        if let descendant = firstDescendant(
            from: element,
            maxDepth: 5,
            maxVisited: 80,
            matching: { self.isLikelyTextInput($0) && (allowEmpty || self.hasUsefulText($0)) }
        ) {
            return descendant
        }

        return firstAncestor(
            from: element,
            maxDepth: 4,
            matching: { self.isLikelyTextInput($0) && (allowEmpty || self.hasUsefulText($0)) }
        )
    }

    private func bestWritableElement(startingAt element: AXUIElement) -> AXUIElement? {
        if isLikelyTextInput(element), isValueSettable(element) {
            return element
        }

        if let descendant = firstDescendant(
            from: element,
            maxDepth: 5,
            maxVisited: 80,
            matching: { self.isLikelyTextInput($0) && self.isValueSettable($0) }
        ) {
            return descendant
        }

        return firstAncestor(
            from: element,
            maxDepth: 4,
            matching: { self.isLikelyTextInput($0) && self.isValueSettable($0) }
        )
    }

    private func isLikelyTextInput(_ element: AXUIElement) -> Bool {
        guard !isSensitiveTextInput(element) else { return false }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute, from: element)?.lowercased()
        let allowedRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ]

        if let role, allowedRoles.contains(role) {
            return true
        }

        if subrole == "AXSearchField" {
            return true
        }

        if let roleDescription,
           roleDescription.contains("text") || roleDescription.contains("edit") {
            return true
        }

        return false
    }

    private func isSensitiveTextInput(_ element: AXUIElement) -> Bool {
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)?.lowercased()
        if subrole == "axsecuretextfield" {
            return true
        }

        let searchableAttributes = [
            stringAttribute(kAXRoleDescriptionAttribute, from: element),
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute("AXPlaceholderValue", from: element)
        ]
        let sensitiveTerms = ["password", "passcode", "secret", "token", "api key", "apikey", "비밀번호", "암호", "토큰"]

        return searchableAttributes
            .compactMap { $0?.lowercased() }
            .contains { attribute in
                sensitiveTerms.contains { attribute.contains($0) }
            }
    }

    private func hasUsefulText(_ element: AXUIElement) -> Bool {
        guard let value = stringAttribute(kAXValueAttribute, from: element)
            ?? stringAttribute(kAXSelectedTextAttribute, from: element)
        else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        return result == .success && settable.boolValue
    }

    private func firstAncestor(
        from element: AXUIElement,
        maxDepth: Int,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<maxDepth {
            guard let parent = parent(of: current) else { return nil }
            if predicate(parent) { return parent }
            current = parent
        }
        return nil
    }

    private func firstDescendant(
        from element: AXUIElement,
        maxDepth: Int,
        maxVisited: Int,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0

        while let (candidate, depth) = queue.first, visited < maxVisited {
            queue.removeFirst()
            visited += 1

            if depth > 0, predicate(candidate) {
                return candidate
            }

            guard depth < maxDepth else { continue }
            for child in children(of: candidate).prefix(20) {
                queue.append((child, depth + 1))
            }
        }

        return nil
    }

    private func parent(of element: AXUIElement?) -> AXUIElement? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func selectedRange(in element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success else {
            return nil
        }

        guard let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        let axRangeValue = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axRangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func caretFrame(in element: AXUIElement) -> CGRect? {
        guard var range = selectedRange(in: element) else { return nil }
        range.length = 0

        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )

        guard result == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        let axBoundsValue = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axBoundsValue, .cgRect, &rect) else { return nil }
        return rect.isEmpty ? nil : rect
    }

    private func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    private func setCaret(offset: Int, on element: AXUIElement) {
        var range = CFRange(location: offset, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
    }

    private func insertAtSelectedRange(_ insertion: String, in element: AXUIElement) -> Bool {
        guard let existingText = stringAttribute(kAXValueAttribute, from: element),
              let range = selectedRange(in: element),
              range.location >= 0,
              range.location <= existingText.utf16.count,
              range.location + range.length <= existingText.utf16.count
        else {
            return false
        }

        let start = String.Index(utf16Offset: range.location, in: existingText)
        let end = String.Index(utf16Offset: range.location + range.length, in: existingText)
        var updatedText = existingText
        updatedText.replaceSubrange(start..<end, with: insertion)

        guard setValue(updatedText, on: element) else { return false }
        setCaret(offset: range.location + insertion.utf16.count, on: element)
        return true
    }

    private func pasteWithClipboard(_ text: String, mode: TextInsertionMode) -> Bool {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            if mode == .replaceAll {
                self.postKeyDownAndUp(keyCode: 0x00, flags: .maskCommand) // A
            }
            self.postKeyDownAndUp(keyCode: 0x09, flags: .maskCommand) // V
        }

        if let previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                pasteboard.clearContents()
                pasteboard.setString(previousString, forType: .string)
            }
        }
        return true
    }

    private func postKeyDownAndUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
