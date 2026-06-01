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
    private let appState = AppState()
    private var menuBarController: MenuBarController?
    private var promptCoachController: PromptCoachController?
    private var introSequenceController: IntroSequenceController?
    private var weeklyNoteController: WeeklyNoteController?
    private var answerSummaryController: AnswerSummaryController?
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    private let accessibilityOnboarder = AccessibilityPermissionOnboarder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("PromptCoach: Starting...")
        print("PromptCoach: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()

        WhereToVibeAnalytics.configure()
        WhereToVibeAnalytics.trackAppOpened()

        menuBarController = MenuBarController(appState: appState)
        promptCoachController = PromptCoachController(appState: appState)
        appState.refreshAccessibilityPermission()

        // Dump current coach state at launch so the user can see in Console.app
        // whether the panel can theoretically appear (the four conditions that
        // gate FloatingSuggestionPanel.show) without having to type anything.
        print("[Coach/Boot] isEnabled=\(appState.isEnabled) hasAccessibilityPermission=\(appState.hasAccessibilityPermission) suggestionMode=\(appState.suggestionMode.rawValue) provider=\(appState.selectedAICoachProvider.rawValue) hasCoachAPIKey=\(appState.hasCoachAPIKey) language=\(appState.promptLanguage.rawValue) idleCoachEnabled=\(appState.idleCoachEnabled)")

        // Identity dump — if the bundle ID or executable path here does not match
        // the entry the user enabled in System Settings → Accessibility, the
        // permission will silently NOT apply, even though the checkbox is on.
        let bundleId = Bundle.main.bundleIdentifier ?? "(no bundle id)"
        let executablePath = Bundle.main.executablePath ?? "(no executable path)"
        let processName = ProcessInfo.processInfo.processName
        print("[Coach/Identity] bundleID=\(bundleId)")
        print("[Coach/Identity] executablePath=\(executablePath)")
        print("[Coach/Identity] processName=\(processName)")
        print("[Coach/Identity] If System Settings → Accessibility shows a DIFFERENT app name (e.g. \"Where-to-vibe\" or \"where-to-vibe\") with a checkmark, that entry is for a different bundle ID and is NOT granting permission to THIS app. Remove old entries with the - button and re-add the currently running app.")
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()

        // Open the weekly prompt note (pros/cons + growth direction) when the
        // menu-bar panel asks. Computed locally from the on-disk habit log.
        NotificationCenter.default.addObserver(
            forName: .showWeeklyNote, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.weeklyNoteController == nil {
                    self.weeklyNoteController = WeeklyNoteController(appState: self.appState)
                }
                self.weeklyNoteController?.show()
            }
        }

        // "Summarize the AI's answer" — created at launch so its ⌃⌥S hotkey is
        // active immediately; the menu button posts a notification too.
        answerSummaryController = AnswerSummaryController(appState: appState)
        NotificationCenter.default.addObserver(
            forName: .summarizeAIAnswer, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.answerSummaryController?.summarizeFromMenu()
            }
        }

        // The first-launch tutorial walks the user all the way through granting
        // Accessibility permission as its final beat, so onboarding is one
        // continuous flow. Just start it — runIntroThenStartCoach handles the
        // no-intro fallback where the standalone onboarder guides the grant.
        runIntroThenStartCoach()
    }

    /// Plays the first-launch intro (which now also guides the Accessibility
    /// grant as its closing step) and then starts the live coach. Guarded to run
    /// at most once per launch.
    private func runIntroThenStartCoach() {
        guard introSequenceController == nil else { return }

        guard let menuBarController else {
            // No menu bar to host the tutorial — fall back to the standalone
            // onboarder, then start the coach once permission is granted.
            startCoachAfterAccessibilityGrant()
            return
        }

        // First-launch intro animation (currently plays every launch, for dev).
        // Small delay so the menu bar status item has been laid out before the
        // fake cursor flies to it. Purely additive — renders in its own
        // transparent overlay and doesn't touch the suggestion / Tab path.
        let introSequenceController = IntroSequenceController(
            menuBarController: menuBarController,
            accessibilityOnboarder: accessibilityOnboarder
        )
        introSequenceController.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appState.refreshAccessibilityPermission()
                self.promptCoachController?.start()
            }
        }
        self.introSequenceController = introSequenceController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !introSequenceController.play() {
                // Intro couldn't render — still guide the accessibility grant,
                // then start the coach.
                self.startCoachAfterAccessibilityGrant()
            }
        }
    }

    /// Fallback for when the tutorial can't run: guide the Accessibility grant
    /// with the standalone onboarder (auto-open the pane + poll) and start the
    /// live coach the instant permission is granted.
    private func startCoachAfterAccessibilityGrant() {
        menuBarController?.showPanel()
        accessibilityOnboarder.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appState.refreshAccessibilityPermission()
                self.promptCoachController?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        promptCoachController?.stop()
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

        // Standard Edit menu. Without it, ⌘C/⌘V/⌘X/⌘A do nothing in our text
        // fields: this app is an LSUIElement (menu-bar accessory), and macOS
        // routes those editing shortcuts through the main menu's Edit items
        // (via their key equivalents) to the first responder. With no Edit menu,
        // a focused SecureField/TextField accepts typed characters but can't
        // paste — which is why users couldn't paste their API key. The actions
        // use nil targets so they travel the responder chain to the field editor
        // (NSText), which implements cut:/copy:/paste:/selectAll:/undo:/redo:.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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
