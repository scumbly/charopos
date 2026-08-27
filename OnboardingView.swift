import SwiftUI
import AppKit

// MARK: - Onboarding (first-run guided setup)
//
// Shown when `Runner.setupComplete` is false (no config file — a true first run).
// Principle: nothing should be red until the user says they run it — services
// start UNCHECKED and only checked ones join the polled roster (the rest go to
// `disabledServices`). Finish writes the config (0o600, merge-style), marks
// `setupComplete`, reloads Runner, and hands back to AppDelegate.
// Re-entry: menubar → "Run Setup Again…" (AppDelegate.showOnboarding).

@MainActor
struct OnboardingView: View {
    /// Called by Finish (and Skip on the welcome screen) after config is written.
    var onFinish: () -> Void = {}

    private enum Step: Int, CaseIterable {
        case welcome, services, storage, actions, notifications, remote, done
        var title: String {
            switch self {
            case .welcome:       return "Welcome"
            case .services:      return "Services"
            case .storage:       return "Storage"
            case .actions:       return "Actions"
            case .notifications: return "Notifications"
            case .remote:        return "Remote Access"
            case .done:          return "Done"
            }
        }
    }

    @State private var step: Step = .welcome

    // Services
    @State private var enabled: Set<String> = []                 // checked service ids
    @State private var svcURL:  [String: String] = [:]           // id → health URL (prefilled with defaults)
    @State private var svcKey:  [String: String] = [:]           // id → API key (keyed services)
    @State private var piholePassword = ""
    @State private var qbitUser = ""
    @State private var qbitPass = ""
    @State private var testState: [String: TestState] = [:]      // id → probe result
    private enum TestState { case testing, ok, fail }

    // Storage
    @State private var nasUnits: [NASUnit] = []
    @State private var localVolumes: [LocalVolume] = []
    @State private var synologyUser = ""
    @State private var synologyPass = ""
    @State private var nasMountUser = ""

    // Notifications
    @State private var prowlKey = ""
    @State private var dashboardURLStr = ""

    // Actions (iperf lives in the Services step but maps to the same setting)
    @State private var iperfEnabled = false
    @State private var chosenActions: Set<String> = ["reboot"]
    @State private var actionsSeeded = false

    // Remote access
    @State private var allowRemote = false

    private static let keyedServices: Set<String> = ["sab", "sonarr", "radarr", "lidarr", "prowlarr", "overseerr", "tautulli", "jellyfin"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .welcome:       welcomeStep
                case .services:      servicesStep
                case .storage:       storageStep
                case .actions:       actionsStep
                case .notifications: notificationsStep
                case .remote:        remoteStep
                case .done:          doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear {
            for def in Runner.serviceDefaults { svcURL[def.id] = def.url ?? "" }
        }
        .onChange(of: step) { new in
            // Smart-default the Actions step ONCE from earlier choices; after that the
            // user's checkmarks stick even if they go Back and change services.
            if new == .actions && !actionsSeeded {
                actionsSeeded = true
                if !nasUnits.isEmpty { chosenActions.insert("mount") }
                if enabled.contains("plex") { chosenActions.insert("kickstart") }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: ContentView.headerIcon)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Charopos Setup").font(.title3).fontWeight(.semibold)
                Text(step.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Step dots
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Skip Setup") { finish() }
                Button("Get Started") { step = .services }.keyboardShortcut(.defaultAction)
            case .done:
                Button("Start Monitoring") { finish() }.keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .done }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: ContentView.headerIcon)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text("Welcome to Charopos").font(.title2).fontWeight(.semibold)
            Text("Charopos monitors the services and storage on this Mac and your homelab — with a menu-bar light, a web dashboard, and a companion Remote app.\n\nNothing is monitored until you add it. Let's pick what you run.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("Skipping starts with an empty roster — everything here is also in Settings.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private var servicesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check the services you run. Unchecked services stay off the grid (no red lights for things you don't have). URLs default to this Mac — adjust host/port if a service lives elsewhere. The roster now covers the media stack (the arr apps, Plex/Jellyfin, Overseerr, Tautulli, Bazarr, SABnzbd/qBittorrent) plus network services.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Runner.serviceDefaults, id: \.id) { def in
                        serviceRow(def)
                    }
                    // iperf3 is a service Charopos PROVIDES rather than monitors — it has
                    // no URL/key to configure, so it gets a bespoke row here and maps to
                    // the action-visibility setting under the hood.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $iperfEnabled).toggleStyle(.checkbox).labelsHidden()
                            Text("iperf3 Server").fontWeight(iperfEnabled ? .medium : .regular)
                                .foregroundStyle(iperfEnabled ? .primary : .secondary)
                            Spacer()
                        }
                        Text("Built-in network throughput test server, hosted by Charopos on this Mac (measure with \u{201C}iperf3 -c <this Mac>\u{201D} from any device).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 26)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func serviceRow(_ def: (id: String, label: String, url: String?, openURL: String?)) -> some View {
        let isOn = enabled.contains(def.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { enabled.contains(def.id) },
                    set: { on in if on { enabled.insert(def.id) } else { enabled.remove(def.id) } }
                )).toggleStyle(.checkbox).labelsHidden()
                Text(def.label).fontWeight(isOn ? .medium : .regular)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Spacer()
                if isOn, def.url != nil {
                    testButton(def.id)
                }
            }
            if isOn {
                VStack(alignment: .leading, spacing: 4) {
                    if def.url != nil {
                        TextField("Health URL", text: Binding(
                            get: { svcURL[def.id] ?? "" },
                            set: { svcURL[def.id] = $0; testState[def.id] = nil }
                        ), prompt: Text(def.url ?? ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    }
                    if Self.keyedServices.contains(def.id) {
                        TextField("API key (from the app's settings — needed for queue counts & updates)",
                                  text: Binding(get: { svcKey[def.id] ?? "" }, set: { svcKey[def.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if def.id == "pihole" {
                        SecureField("App password (PiHole UI → Settings → API)", text: $piholePassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    if def.id == "qbittorrent" {
                        TextField("WebUI username (for the download badge — optional)", text: $qbitUser).textFieldStyle(.roundedBorder)
                        SecureField("WebUI password", text: $qbitPass).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
    }

    @ViewBuilder
    private func testButton(_ id: String) -> some View {
        HStack(spacing: 5) {
            switch testState[id] {
            case .testing: ProgressView().controlSize(.small)
            case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .fail:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil:      EmptyView()
            }
            Button("Test") { testConnection(id) }
                .controlSize(.small)
                .disabled(testState[id] == .testing)
        }
    }

    private var storageStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional: add the NAS units and local volumes to watch (health, mount state, free space). Built-in NAS support is Synology-only — health checks, update detection, and DSM updates use Synology's DSM API. Local volumes can be any mounted disk. Skip and add them later in Settings → Storage.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("NAS Units").fontWeight(.medium)
                ForEach($nasUnits) { $nas in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Label", text: $nas.label).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { nasUnits.removeAll { $0.id == nas.id } } label: {
                                Image(systemName: "minus.circle").foregroundColor(.red)
                            }.buttonStyle(.plain)
                        }
                        TextField("Health URL (https://nas.local:5001)", text: $nas.checkURL)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        TextField("Mount point (/Volumes/…)", text: $nas.mountPoint)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        TextField("Mount source (smb://nas.local/Share — optional, for NAS Refresh)", text: $nas.mountSource)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                }
                Button { nasUnits.append(NASUnit(id: "nas-\(UUID().uuidString.prefix(4).lowercased())",
                                                 label: "", checkURL: "", openURL: "", mountPoint: "")) } label: {
                    Label("Add NAS", systemImage: "plus.circle")
                }.buttonStyle(.plain).foregroundColor(.accentColor)

                if !nasUnits.isEmpty {
                    Text("Synology credentials").fontWeight(.medium).padding(.top, 4)
                    TextField("DSM user (API: health, updates)", text: $synologyUser).textFieldStyle(.roundedBorder)
                    SecureField("DSM password", text: $synologyPass).textFieldStyle(.roundedBorder)
                    TextField("NAS mount user (AFP/SMB — often different)", text: $nasMountUser).textFieldStyle(.roundedBorder)
                }

                Text("Local Volumes").fontWeight(.medium).padding(.top, 4)
                ForEach($localVolumes) { $vol in
                    HStack {
                        TextField("Label", text: $vol.label).textFieldStyle(.roundedBorder)
                        TextField("/Volumes/…", text: $vol.mountPoint)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        Button(role: .destructive) { localVolumes.removeAll { $0.id == vol.id } } label: {
                            Image(systemName: "minus.circle").foregroundColor(.red)
                        }.buttonStyle(.plain)
                    }
                }
                Button { localVolumes.append(LocalVolume(id: "vol-\(UUID().uuidString.prefix(4).lowercased())",
                                                         label: "", mountPoint: "")) } label: {
                    Label("Add Volume", systemImage: "plus.circle")
                }.buttonStyle(.plain).foregroundColor(.accentColor)
            }
            .padding(20)
        }
    }

    private var actionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick the action buttons you want. Hidden actions disappear from every surface (desktop window, menu bar, web dashboard, Remote app) — nothing is assumed. iperf3 was offered in the Services step.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PreferencesView.actionInfo.filter { $0.id != "iperf" }, id: \.id) { a in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { chosenActions.contains(a.id) },
                        set: { on in if on { chosenActions.insert(a.id) } else { chosenActions.remove(a.id) } }
                    )).toggleStyle(.checkbox).labelsHidden()
                    Image(systemName: a.symbol).foregroundStyle(.tint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title)
                        Text(a.desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            }
            Text("NAS Refresh also runs automatically at boot when enabled. Changeable anytime in Settings → Services → Actions.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional: push alerts (service down, NAS offline, disk space, UPS…) via Prowl. All alert types start enabled and are tunable in Settings → Notifications.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Prowl API key", text: $prowlKey)
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Send test notification") { Runner.shared.testProwlNotification(apiKey: prowlKey) }
                    .disabled(prowlKey.isEmpty)
                Spacer()
            }
            Divider().padding(.vertical, 4)
            TextField("Dashboard link attached to alerts (blank = this Mac's .local name)", text: $dashboardURLStr)
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            Text("Set a Tailscale IP if .local doesn't resolve where you read alerts.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }

    private var remoteStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow remote access")
                    Text(allowRemote ? "Reachable from your LAN / tailnet" : "This Mac only (loopback)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $allowRemote).labelsHidden().toggleStyle(.switch)
            }
            Text("Off (secure default): the API and web dashboard bind to 127.0.0.1 — only this Mac can reach them. On: other devices on your network or tailnet can open the web dashboard and connect the Charopos Remote app, authenticated by the token in launcher-remote-token.txt (next to the app). Traffic is unencrypted HTTP, so only enable this on networks you trust.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Prefer a tailnet (e.g. Tailscale) over exposing the raw LAN port. On a shared network, prefer the \u{201C}Tailscale only\u{201D} mode — you can switch in Settings → Services → Remote Access.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("You're set").font(.title2).fontWeight(.semibold)
            Text(summaryText)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("Everything here can be changed in Settings. Re-run setup anytime from the menu-bar icon.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private var summaryText: String {
        var parts: [String] = []
        parts.append(enabled.isEmpty ? "No services yet" : "\(enabled.count) service\(enabled.count == 1 ? "" : "s")")
        if !nasUnits.isEmpty { parts.append("\(nasUnits.count) NAS unit\(nasUnits.count == 1 ? "" : "s")") }
        if !localVolumes.isEmpty { parts.append("\(localVolumes.count) volume\(localVolumes.count == 1 ? "" : "s")") }
        let actionCount = chosenActions.count + (iperfEnabled ? 1 : 0)
        parts.append("\(actionCount) action\(actionCount == 1 ? "" : "s")")
        parts.append(prowlKey.isEmpty ? "alerts off" : "Prowl alerts on")
        parts.append(allowRemote ? "remote access on" : "local-only")
        return "Monitoring: " + parts.joined(separator: " · ") + "."
    }

    // MARK: Test connection

    /// Reachability probe for a service's health URL: any HTTP response (even 401)
    /// counts as reachable; timeouts/refused = fail. Accepts self-signed certs.
    private func testConnection(_ id: String) {
        guard let str = (svcURL[id]?.isEmpty == false ? svcURL[id] : Runner.serviceDefaults.first(where: { $0.id == id })?.url),
              let url = URL(string: str) else { testState[id] = .fail; return }
        testState[id] = .testing
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: cfg, delegate: TrustAnyCert(), delegateQueue: nil)
        session.dataTask(with: url) { _, response, _ in
            DispatchQueue.main.async {
                testState[id] = (response is HTTPURLResponse) ? .ok : .fail
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    // MARK: Finish

    /// Write the config (merge over any existing file), mark setup complete,
    /// reload Runner, and hand control back to the app.
    private func finish() {
        let url = Runner.shared.configFileURL
        var json: [String: Any] = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        json["setupComplete"] = "true"
        json["allowRemoteAccess"] = allowRemote ? "true" : "false"
        json["apiBindMode"] = allowRemote ? "all" : "loopback"
        json["disabledServices"] = Runner.serviceDefaults.map(\.id).filter { !enabled.contains($0) }
        json["knownServices"] = Runner.serviceDefaults.map(\.id)  // roster-migration marker
        // Hidden action rows: everything optional the user didn't pick (iperf's
        // checkbox lives in the Services step but is the same setting).
        var keptActions = chosenActions
        if iperfEnabled { keptActions.insert("iperf") }
        json["disabledActions"] = Array(Runner.optionalActionIDs.subtracting(keptActions))
        // v4.66 placements: chosen actions go to the Main Window, the rest to None.
        // (Onboarding's checklist maps to Main Window; fine-grained Menu-Only routing
        // lives in Settings → Services → Actions afterward.)
        var placements: [String: String] = [:]
        for id in Runner.optionalActionIDs {
            placements[id] = keptActions.contains(id) ? "main" : "none"
        }
        json["actionPlacements"] = placements

        // URL overrides — only where the entered value differs from the default
        var serviceURLs: [String: [String: String]] = [:]
        for def in Runner.serviceDefaults {
            let entered = svcURL[def.id] ?? ""
            if !entered.isEmpty, entered != (def.url ?? "") { serviceURLs[def.id] = ["url": entered] }
        }
        if !serviceURLs.isEmpty { json["serviceURLs"] = serviceURLs }

        let keyMap = ["sab": "sabnzbdApiKey", "sonarr": "sonarrApiKey", "radarr": "radarrApiKey",
                      "lidarr": "lidarrApiKey", "prowlarr": "prowlarrApiKey",
                      "overseerr": "overseerrApiKey", "tautulli": "tautulliApiKey", "jellyfin": "jellyfinApiKey"]
        for (id, cfgKey) in keyMap where !(svcKey[id] ?? "").isEmpty { json[cfgKey] = svcKey[id] }
        if !piholePassword.isEmpty { json["piholePassword"] = piholePassword }
        if !qbitUser.isEmpty { json["qbitUser"] = qbitUser }
        if !qbitPass.isEmpty { json["qbitPass"] = qbitPass }

        if !nasUnits.isEmpty {
            json["nasUnits"] = nasUnits.map { [
                "id": $0.id, "label": $0.label, "checkURL": $0.checkURL, "openURL": $0.openURL,
                "mountPoint": $0.mountPoint, "mountSource": $0.mountSource,
                "suppressSpaceAlert": $0.suppressSpaceAlert
            ] as [String: Any] }
        }
        if !localVolumes.isEmpty {
            json["localVolumes"] = localVolumes.map { [
                "id": $0.id, "label": $0.label, "mountPoint": $0.mountPoint,
                "suppressSpaceAlert": $0.suppressSpaceAlert
            ] as [String: Any] }
        }
        if !synologyUser.isEmpty { json["synologyUser"] = synologyUser }
        if !synologyPass.isEmpty { json["synologyPass"] = synologyPass }
        if !nasMountUser.isEmpty { json["nasMountUser"] = nasMountUser }
        if !prowlKey.isEmpty { json["prowlApiKey"] = prowlKey }
        if !dashboardURLStr.isEmpty { json["dashboardURL"] = dashboardURLStr }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        Runner.shared.loadConfig()
        if allowRemote { Runner.shared.restartAPI() }   // rebind loopback → all interfaces
        AppLog.shared.write("Onboarding complete — \(enabled.count) service(s), \(nasUnits.count) NAS, \(localVolumes.count) volume(s)")
        onFinish()
    }
}

/// Accept-any-cert delegate for the onboarding reachability probe only
/// (NAS health URLs are typically self-signed).
private final class TrustAnyCert: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
