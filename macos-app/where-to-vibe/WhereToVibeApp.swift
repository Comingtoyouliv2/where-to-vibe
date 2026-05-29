//
//  WhereToVibeApp.swift
//  where-to-vibe
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct WhereToVibeApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the prompt coach lifecycle: creates the menu bar controller and
/// starts the focused-text observer on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var companionManager: CompanionManager?
    private var menuBarPanelManager: MenuBarPanelManager?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("PromptCoach: Starting...")
        print("PromptCoach: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()

        WhereToVibeAnalytics.configure()
        WhereToVibeAnalytics.trackAppOpened()

        // Wire up the LIVE system. CompanionManager owns the auto-coach loop
        // (screenshot → worker /coach → NudgeBubbleWindow → Tab-to-copy via
        // TabKeyInterceptor). MenuBarPanelManager hosts the settings panel.
        //
        // The old PromptCoachController + MenuBarController MVP is intentionally
        // no longer started: it installed a SECOND CGEvent tap on Tab that
        // conflicted with TabKeyInterceptor, spammed the console with poll
        // logs, and used local/OpenAI suggestions instead of the worker /coach
        // endpoint. Those types still compile but are now dead code.
        let companionManager = CompanionManager()
        self.companionManager = companionManager
        let menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        self.menuBarPanelManager = menuBarPanelManager
        companionManager.start()
        menuBarPanelManager.showPanelOnLaunch()

        // Identity + permission diagnostics. TabKeyInterceptor (Tab → copy the
        // rewrite) needs the ACCESSIBILITY permission specifically, and it
        // creates its CGEvent tap once at startup. The nudge bubble itself only
        // needs Screen Recording — so a bubble can appear while Tab still does
        // nothing if Accessibility is missing. In that case: grant it, then
        // QUIT AND RELAUNCH so the Tab tap is created with permission present.
        let bundleId = Bundle.main.bundleIdentifier ?? "(no bundle id)"
        let executablePath = Bundle.main.executablePath ?? "(no executable path)"
        print("[Where-to-vibe/Identity] bundleID=\(bundleId)")
        print("[Where-to-vibe/Identity] executablePath=\(executablePath)")
        if !companionManager.hasAccessibilityPermission {
            print("[Where-to-vibe/Boot] Accessibility MISSING — Tab interception is inactive until granted. Prompting now; grant in System Settings → Privacy & Security → Accessibility, then quit and relaunch.")
            _ = WindowPositionManager.requestAccessibilityPermission()
        }

        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager?.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("PromptCoach: Registered as login item")
            } catch {
                print("PromptCoach: Failed to register as login item: \(error)")
            }
        }
    }

    private func installApplicationMenu() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Where-to-vibe"

        let appMenu = NSMenu(title: appName)
        let quitMenuItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitMenuItem.target = NSApp
        appMenu.addItem(quitMenuItem)

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Where-to-vibe: Sparkle updater failed to start: \(error)")
        }
    }
}
