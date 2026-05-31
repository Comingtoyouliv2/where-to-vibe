import AppKit
import Combine
import SwiftUI

private final class PromptCoachMenuPanel: NSPanel {
    // A borderless window returns false for both by default, which blocks
    // keyboard focus — text fields (the API-key field) would never get a cursor.
    // Allowing key + main makes the panel fully interactive once the app is active.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        super.init()
        createStatusItem()
        observeLanguageChanges()
    }

    deinit {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Where-to-vibe")
        button.image?.isTemplate = true
        button.title = " \(appState.promptLanguage.menuTitle)"
        button.action = #selector(togglePanel)
        button.target = self
    }

    private func observeLanguageChanges() {
        appState.$promptLanguage
            .sink { [weak self] language in
                self?.statusItem?.button?.title = " \(language.menuTitle)"
            }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        ensurePanel()
        positionPanel()
        // Bring the app forward and make the panel the key window so its text
        // fields and controls actually receive focus and clicks. Without this,
        // an accessory (menu-bar-only) app's panel shows but cannot take
        // keyboard input — the OpenAI API-key field would never get a cursor and
        // toggles/buttons wouldn't respond.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        installClickOutsideMonitor()
    }

    /// Screen-space frame (AppKit, bottom-left origin) of the menu bar status
    /// item's button window. Used by the first-launch intro to fly a fake
    /// cursor to where the app lives in the menu bar. nil before the status
    /// item has been created / laid out.
    func menuBarButtonScreenFrame() -> CGRect? {
        return statusItem?.button?.window?.frame
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = SettingsView(appState: appState)
            .frame(width: 370)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 370, height: 770)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let newPanel = PromptCoachMenuPanel(
            // No .nonactivatingPanel here: this settings panel is opened
            // deliberately by the user and must be able to become the key window
            // so text fields (API key) and controls can take focus. (The
            // cursor-side suggestion panel stays non-activating separately.)
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isExcludedFromWindowsMenu = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = hostingView
        panel = newPanel
    }

    private func positionPanel() {
        guard let panel, let buttonWindow = statusItem?.button?.window else { return }
        let size = panel.contentView?.fittingSize ?? CGSize(width: 370, height: 520)
        let origin = CGPoint(
            x: buttonWindow.frame.midX - size.width / 2,
            y: buttonWindow.frame.minY - size.height - 6
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hidePanel()
                }
            }
        }
    }
}
