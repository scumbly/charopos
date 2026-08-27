import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement

// MARK: - App

/// Startup happens here, NOT in the window's onAppear: when launched as a
/// Login Item, macOS may start the app without showing its window, and the
/// boot scripts / remote API must run regardless.
@MainActor
private struct ServerAboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: ContentView.headerIcon)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            Text("Charopos")
                .font(.title2).fontWeight(.semibold)
            Text("v\(appVersion)")
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Monitors Synology NAS health, media services, and system resources. Provides one-tap controls for mounting volumes, launching apps, and running maintenance tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Text("© Jesse Holden \(String(format: "%d", Calendar.current.component(.year, from: Date())))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 300)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?
    private var actionMenuItems: [(NSMenuItem, String)] = []
    private var openAtLoginItem: NSMenuItem?
    private var showWindowItem: NSMenuItem?
    private var hideDockItem: NSMenuItem?
    private var mainWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var windowVisibleBeforeSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let runner = Runner.shared
        // startPolling() loads the config first — setupComplete must be known before
        // deciding whether to auto-run the boot sequence (media-stack-specific; a
        // first-run machine must not fire it) or to show onboarding instead.
        runner.startPolling()
        if runner.setupComplete { runner.autoRunIfJustBooted() }
        runner.startAPI()
        setupMenuBar()
        // Create main window directly so it always exists regardless of whether
        // SwiftUI's WindowGroup decides to show it (it won't after a reboot with
        // Show Window at Startup = off, leaving mainWindow nil and Show Window broken).
        let controller = NSHostingController(rootView: ContentView().environmentObject(runner))
        // Pin the window to the content's natural size ONCE and never auto-resize.
        // Content-driven sizing (sizingOptions = .preferredContentSize) recomputes
        // the window frame via Auto Layout inside the display cycle; when the
        // content churns rapidly (e.g. Kickstart) NSHostingView re-invalidates
        // constraints mid-cycle, hitting a re-entrant _postWindowNeedsUpdateConstraints
        // NSException → SIGABRT on macOS 26. The 4-quadrant layout is fixed-size
        // (status 310x160, log 204 scroll, config-driven service/NAS rows), so a pinned
        // size clips nothing. Do NOT restore .preferredContentSize here.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "Charopos"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
        // Remember where the user left the window across launches; center only when
        // no saved frame exists. Size stays content-driven (layout can change between
        // builds), so re-apply the fitting size after restoring the position.
        window.setFrameAutosaveName("CharoposMain")
        if window.setFrameUsingName("CharoposMain") {
            if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
        } else {
            window.center()
        }
        if runner.showWindowAtStartup && runner.setupComplete {
            window.makeKeyAndOrderFront(nil)
        }
        mainWindow = window
        // First run (no config): guided setup instead of the main window.
        if !runner.setupComplete { showOnboarding() }
        // Same sleep/wake fix as the Remote app: hide before sleep so the window
        // server doesn't push a restored frame on wake, which causes re-entrant
        // constraint layout inside NSHostingView and crashes with EXC_CRASH.
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowVisibleBeforeSleep = self?.mainWindow?.isVisible ?? false
                self?.mainWindow?.orderOut(nil)
                self?.settingsWindow?.orderOut(nil)
                self?.aboutWindow?.orderOut(nil)
                self?.onboardingWindow?.orderOut(nil)
                self?.helpWindow?.orderOut(nil)
            }
        }
        wakeObserver = ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.windowVisibleBeforeSleep == true { self?.mainWindow?.makeKeyAndOrderFront(nil) }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Runner.shared.stopPolling()
        Runner.shared.api?.stop()
        // Hard backstop on a raw Thread — immune to GCD pool exhaustion.
        // If NSPersistentUIManager or anything else stalls the exit path,
        // this guarantees the process exits within 5 seconds regardless.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 5)
            exit(0)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // NEVER block termination. Reboot is driven by Runner.rebootServer(), which
        // quits the other apps first and only then self-terminates — so Charopos must
        // always quit promptly when asked. Returning .terminateLater here previously
        // deadlocked the restart (Charopos refused to quit, blocking the very restart
        // it had initiated). See rebootServer() in Runner.swift.
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { mainWindow?.makeKeyAndOrderFront(nil) }
        return false
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let controller = NSHostingController(rootView: ServerAboutView())
            controller.sizingOptions = []   // NOT .preferredContentSize — see the main-window note; content-sized NSHosting windows crash on macOS 26 (_postWindowNeedsUpdateConstraints)
            let w = NSPanel(contentViewController: controller)
            w.title = "About Charopos"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            aboutWindow = w
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenuBarMenu()
        updateMenuBarIcon()
        cancellable = Runner.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateMenuBarIcon() } }
    }

    /// (Re)build the status-item menu. Called at startup and again whenever the
    /// hidden-actions set may have changed (Settings save, onboarding finish) so
    /// the action items reflect the current roster.
    func rebuildMenuBarMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let showItem = NSMenuItem(title: "Open Charopos", action: #selector(openWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let aboutItem = NSMenuItem(title: "About Charopos", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        // Action items — same order as the ContentView action column, with leading icons
        let actionOrder: [(id: String, title: String, icon: String)] = [
            ("mount",              "NAS Refresh",           "arrow.triangle.2.circlepath"),
            ("iperf",              "Start iPerf3",          "speedometer"),   // title set dynamically in menuWillOpen
            ("inventory",          "Run Inventory",         "list.bullet.rectangle"),
            ("kickstart",          "Kickstart Plex",        "bolt"),
            ("kickstart-jellyfin", "Kickstart Jellyfin",    "bolt.horizontal.circle"),
            ("scan-libraries",     "Scan Libraries",        "books.vertical"),
            ("clear-transcode",    "Clear Transcode Cache", "trash"),
            ("check-updates",      "Check for Updates",     "arrow.clockwise"),
            ("pause-downloads",    "Pause Downloads",       "pause.circle"),   // title set dynamically in menuWillOpen
            ("bazarr-search",      "Search Subtitles",      "captions.bubble"),
            ("backup",             "Back Up Now",           "externaldrive.badge.timemachine"),
            ("pihole-gravity",     "Update Pi-hole Gravity","shield.lefthalf.filled"),
            ("reboot",             "Reboot Server",         "power"),
        ]
        actionMenuItems = []
        for (id, title, icon) in actionOrder where Runner.shared.showsInMenu(id) {
            let item = NSMenuItem(title: title, action: #selector(actionItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            menu.addItem(item)
            actionMenuItems.append((item, id))
        }
        menu.addItem(.separator())
        // Leading icons for the toggle rows + Settings. The explicit gearshape on
        // Settings also overrides the macOS-26 auto-gear (so it aligns like the rest).
        // Checkmarks still render in the state column to the left of the icon.
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        menu.addItem(loginItem)
        openAtLoginItem = loginItem
        let showWinItem = NSMenuItem(title: "Show Window at Startup", action: #selector(toggleShowWindowAtStartup), keyEquivalent: "")
        showWinItem.target = self
        showWinItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(showWinItem)
        showWindowItem = showWinItem
        let hideItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleHideDockIcon), keyEquivalent: "")
        hideItem.target = self
        hideItem.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: nil)
        menu.addItem(hideItem)
        hideDockItem = hideItem
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Run Setup Again\u{2026}", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        setupItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(setupItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Charopos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let runner = Runner.shared
        for (item, id) in actionMenuItems {
            switch id {
            case "iperf":           item.title = runner.iperfAlive ? "Stop iPerf3" : "Start iPerf3"
            case "pause-downloads": item.title = runner.downloadsPaused ? "Resume Downloads" : "Pause Downloads"
            default: break
            }
        }
        openAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showWindowItem?.state = runner.showWindowAtStartup ? .on : .off
        hideDockItem?.state = runner.hideDockIcon ? .on : .off
    }

    @objc private func toggleOpenAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func toggleShowWindowAtStartup() {
        let r = Runner.shared
        r.showWindowAtStartup.toggle()
        r.setConfigFlag("showWindowAtStartup", r.showWindowAtStartup)
    }

    @objc private func toggleHideDockIcon() {
        let r = Runner.shared
        r.hideDockIcon.toggle()
        r.setConfigFlag("hideDockIcon", r.hideDockIcon)
        NSApplication.shared.setActivationPolicy(r.hideDockIcon ? .accessory : .regular)
    }

    /// Confirm-then-reboot, shared by the menubar action item and the Actions menu.
    func promptReboot() {
        let alert = NSAlert()
        alert.messageText = "Reboot the server?"
        alert.informativeText = "Force Reboot skips save dialogs and force-quits any app blocking shutdown. Unsaved work in other apps will be lost."
        alert.addButton(withTitle: "Reboot")
        alert.addButton(withTitle: "Force Reboot")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { Runner.shared.rebootServer() }
        else if response == .alertSecondButtonReturn { Runner.shared.rebootServer(force: true) }
    }

    @objc private func actionItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let runner = Runner.shared
        switch id {
        case "iperf":
            if runner.iperfAlive { runner.stopIperf() }
            else if let item = Runner.items.first(where: { $0.id == "iperf" }) { runner.run(item) }
        case "reboot":
            promptReboot()   // shared with the Actions menu in CharoposApp.commands
        default:
            if let item = Runner.items.first(where: { $0.id == id }) { runner.run(item) }
        }
    }

    @objc private func openWindow() {
        let target = mainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) })
        target?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: PreferencesView())
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26
            let w = NSPanel(contentViewController: controller)
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false   // stay open when the app loses focus (NSPanel defaults to hiding)
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            // Same remember-position treatment as the main window.
            w.setFrameAutosaveName("CharoposSettings")
            if w.setFrameUsingName("CharoposSettings") {
                if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            } else {
                w.center()
            }
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Guided first-run setup. Shown automatically when no config exists
    /// (Runner.setupComplete == false); re-runnable from the menu bar.
    @objc func showOnboarding() {
        if onboardingWindow == nil {
            let controller = NSHostingController(rootView: OnboardingView(onFinish: { [weak self] in
                self?.onboardingFinished()
            }))
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26
            let w = NSWindow(contentViewController: controller)
            w.title = "Charopos Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            w.center()
            onboardingWindow = w
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func onboardingFinished() {
        onboardingWindow?.orderOut(nil)
        // Tear down so a later "Run Setup Again…" starts a fresh flow (state reset).
        onboardingWindow = nil
        rebuildMenuBarMenu()   // action items reflect the choices just written
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reference window replacing the old per-action (i) popovers. A plain,
    /// resizable NSWindow (not a fixed-size panel) — it's reference material a
    /// user may want to enlarge, unlike Settings/Setup's utility-panel sizing.
    @objc func showHelp() {
        if helpWindow == nil {
            let controller = NSHostingController(rootView: HelpView())
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26
            let w = NSWindow(contentViewController: controller)
            w.title = "Charopos Help"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            w.setFrameAutosaveName("CharoposHelp")
            if !w.setFrameUsingName("CharoposHelp") { w.center() }
            helpWindow = w
        }
        helpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMenuBarIcon() {
        statusItem?.button?.image = dotImage(name: overallIconName(Runner.shared))
    }

    private func overallIconName(_ runner: Runner) -> String {
        // Local volumes are intentionally excluded: an unmounted local drive is "grey"
        // (idle), not a fault — it must not turn the menubar icon red.
        let anyRed = runner.services.contains { runner.serviceHealth[$0.id] == false }
            || runner.nasUnits.contains { runner.nasHealthState(for: $0.id) == "red" }
        if anyRed { return "red" }

        let anyOrange = runner.services.contains { runner.serviceWarnings[$0.id] == true }
            || runner.nasUnits.contains { runner.nasHealthState(for: $0.id) == "orange" }
            || runner.localVolumes.contains { runner.volumeHealth[$0.id] == "orange" }
        if anyOrange { return "orange" }

        let anyBlue = (runner.sabQueueCount ?? 0) > 0
            || (runner.sonarrQueueCount ?? 0) > 0
            || (runner.radarrQueueCount ?? 0) > 0
            || !runner.arrUpdatesAvailable.isEmpty
            || runner.sabUpdateAvailable
            || runner.cloudKeyUpdateAvailable
            || runner.plexUpdateAvailable
            || runner.piholeUpdateAvailable
            || runner.nasUnits.contains { runner.nasHasUpdate(for: $0.id) }
            || (runner.overseerrPendingCount ?? 0) > 0
            || (runner.qbitDownloadCount ?? 0) > 0
            || runner.overseerrUpdateAvailable
            || runner.tautulliUpdateAvailable
        if anyBlue { return "blue" }

        return "green"
    }

    private var cachedIconName: String?
    private var cachedIconImage: NSImage?

    private func dotImage(name: String) -> NSImage {
        if name == cachedIconName, let img = cachedIconImage { return img }
        let img = Self.renderIcon(named: name)
        cachedIconName = name
        cachedIconImage = img
        return img
    }

    private static func renderIcon(named name: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        func load(_ suffix: String) -> NSImage? {
            guard let url = Bundle.main.url(forResource: "menubar-icon-\(name)\(suffix)", withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            img.size = size
            return img
        }
        let darkVariant  = load("")        // dark pixels — for light menu bar
        let lightVariant = load("-light")  // light pixels — for dark menu bar
        if darkVariant != nil || lightVariant != nil {
            return NSImage(size: size, flipped: false) { rect in
                let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                (isDark ? (lightVariant ?? darkVariant) : (darkVariant ?? lightVariant))?.draw(in: rect)
                return true
            }
        }
        // Fallback: bearing drawn procedurally in grey
        return NSImage(size: size, flipped: false) { _ in
            let cx: CGFloat = 8, cy: CGFloat = 8
            NSColor.secondaryLabelColor.setFill()
            NSColor.secondaryLabelColor.setStroke()
            let outerPath = NSBezierPath(ovalIn: NSRect(x: 0.7, y: 0.7, width: 14.6, height: 14.6))
            outerPath.lineWidth = 1.3; outerPath.stroke()
            let cagePath = NSBezierPath(ovalIn: NSRect(x: 2.15, y: 2.15, width: 11.7, height: 11.7))
            cagePath.lineWidth = 0.6; cagePath.stroke()
            let race1 = NSBezierPath(ovalIn: NSRect(x: 3.6, y: 3.6, width: 8.8, height: 8.8))
            race1.lineWidth = 0.9; race1.stroke()
            let race2 = NSBezierPath(ovalIn: NSRect(x: 4.8, y: 4.8, width: 6.4, height: 6.4))
            race2.lineWidth = 0.9; race2.stroke()
            let orbitR: CGFloat = 5.85, ballR: CGFloat = 1.35
            for i in 0..<4 {
                let a = CGFloat(i) * .pi / 2 + .pi / 4
                NSBezierPath(ovalIn: NSRect(x: cx + orbitR * cos(a) - ballR,
                                            y: cy + orbitR * sin(a) - ballR,
                                            width: 2 * ballR, height: 2 * ballR)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: cx - 1.8, y: cy - 1.8, width: 3.6, height: 3.6)).fill()
            return true
        }
    }
}

@main
struct CharoposApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runner = Runner.shared

    var body: some Scene {
        // Window lifecycle is managed by AppDelegate via NSHostingController.
        Settings { EmptyView() }
            .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Charopos") { appDelegate.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Charopos Help") { appDelegate.showHelp() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Toggle(isOn: Binding(
                    get: { runner.uiPreviewMode },
                    set: { on in
                        runner.uiPreviewMode = on
                        if on { runner.activateUIPreview() } else { runner.deactivateUIPreview() }
                    }
                )) {
                    Text("Preview UI States")
                }
            }
            // Keyboard-reachable mirror of the action rows (hidden actions excluded).
            // runner is a @StateObject, so the menu revalidates with app state.
            CommandMenu("Actions") {
                if runner.showsInMenu("mount"), let item = runner.item(withID: "mount") {
                    Button("NAS Refresh") { runner.run(item) }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("iperf") {
                    Button(runner.iperfAlive ? "Stop iPerf3" : "Start iPerf3") {
                        if runner.iperfAlive { runner.stopIperf() }
                        else if let item = runner.item(withID: "iperf") { runner.run(item) }
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("inventory"), let item = runner.item(withID: "inventory") {
                    Button("Run Inventory") { runner.run(item) }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("kickstart"), let item = runner.item(withID: "kickstart") {
                    Button("Kickstart Plex") { runner.run(item) }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("kickstart-jellyfin"), let item = runner.item(withID: "kickstart-jellyfin") {
                    Button("Kickstart Jellyfin") { runner.run(item) }
                        .keyboardShortcut("j", modifiers: [.command, .shift])
                }
                // v4.65 actions — each gets a ⇧⌘ mnemonic (L/T/U/D/S/B/G); none collide
                // with the existing R/P/I/K/J or the app-level ⌘, / ⌘?. The cue renders
                // automatically in the menu.
                if runner.showsInMenu("scan-libraries"), let item = runner.item(withID: "scan-libraries") {
                    Button("Scan Libraries") { runner.run(item) }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("clear-transcode"), let item = runner.item(withID: "clear-transcode") {
                    Button("Clear Transcode Cache") { runner.run(item) }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("check-updates"), let item = runner.item(withID: "check-updates") {
                    Button("Check for Updates") { runner.run(item) }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("pause-downloads"), let item = runner.item(withID: "pause-downloads") {
                    Button(runner.downloadsPaused ? "Resume Downloads" : "Pause Downloads") { runner.run(item) }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("bazarr-search"), let item = runner.item(withID: "bazarr-search") {
                    Button("Search Subtitles") { runner.run(item) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("backup"), let item = runner.item(withID: "backup") {
                    Button("Back Up Now") { runner.run(item) }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("pihole-gravity"), let item = runner.item(withID: "pihole-gravity") {
                    Button("Update Pi-hole Gravity") { runner.run(item) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
                if runner.showsInMenu("reboot") {
                    Divider()
                    // No shortcut — destructive; goes through the same confirm alert.
                    Button("Reboot Server\u{2026}") { appDelegate.promptReboot() }
                }
            }
        }
    }
}
