import AppKit
import Combine
import SwiftUI

private final class PromptCoachMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
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
            .frame(width: 330)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 330, height: 770)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let newPanel = PromptCoachMenuPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        let size = panel.contentView?.fittingSize ?? CGSize(width: 330, height: 310)
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
