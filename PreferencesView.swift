import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement

@MainActor
struct PreferencesView: View {
    @ObservedObject private var runner = Runner.shared
    @State private var prowlApiKey    = ""
    @State private var dashboardURLStr = ""
    @State private var sabnzbdApiKey  = ""
    @State private var sonarrApiKey   = ""
    @State private var radarrApiKey   = ""
    @State private var lidarrApiKey   = ""
    @State private var prowlarrApiKey = ""
    @State private var overseerrApiKey = ""
    @State private var tautulliApiKey  = ""
    @State private var jellyfinApiKey  = ""
    @State private var bazarrApiKey    = ""
    @State private var qbitUser        = ""
    @State private var qbitPass        = ""
    @State private var synologyUser   = ""
    @State private var nasMountUser   = ""
    @State private var synologyPass   = ""
    @State private var piholePassword = ""
    @State private var piholeSshTarget = ""
    @State private var piholeSshKey    = ""
    @State private var inventoryEnabled = false
    @State private var inventoryDays    = "7"
    @State private var cloudKeyHost      = ""
    @State private var cloudKeySshKey   = ""
    @State private var diskAlertPct          = "90"
    @State private var svcDownMinStr         = "5"
    @State private var upsBatteryLowPctStr   = "20"
    @State private var swapAlertPctStr       = "25"
    @State private var alertNASOffline       = true
    @State private var alertServiceDown      = true
    @State private var alertUpdatesAvailable = true
    @State private var alertDiskSpace        = true
    @State private var alertUPSOnBattery     = true
    @State private var alertUPSLowBattery    = true
    @State private var alertMemoryPressure   = true
    @State private var alertSwapHigh         = true
    @State private var alertExternalIPChange = true
    @State private var alertZombieProcess    = true
    @State private var alertNTPDrift         = true
    @State private var alertSMARTFailure     = true
    @State private var alertSMARTReallocated = true
    @State private var alertTimeMachineError  = true
    @State private var ghostMonitorEnabled    = true
    // Notification category master gates (true gate; individual toggles preserved).
    @State private var notifyServices = true
    @State private var notifyStorage  = true
    @State private var notifyHost     = true
    @State private var notifSelection: String? = "services"   // "services" / "storage" / "host"
    // Infrastructure
    @State private var nasUnits:    [NASUnit]     = []
    @State private var localVolumes: [LocalVolume] = []
    @State private var svcLocalURLs: [String: String] = [:]   // id → health-check url
    @State private var svcOpenURLs:  [String: String] = [:]   // id → open url
    @State private var disabledServices: Set<String> = []     // services the user turned off
    @State private var actionPlacementsState: [String: String] = [:]   // id → none/menu/main (v4.66)
    @State private var mainCapHit = false                              // flashed when the 6-slot main-window cap blocks a change
    @State private var apiBindMode = "loopback"                 // API server bind: loopback / tailscale / all
    @State private var tokenJustRotated = false                 // transient confirmation after Rotate API Token…
    @State private var showRotateTokenAlert = false
    @State private var showForgetCertsAlert = false            // confirm before dropping pinned TLS certs
    @State private var certsRevision = 0                       // bumped to re-read CertPinStore after a reset
    @State private var storageSelection:  String? = nil   // "nas:<id>" or "vol:<id>"
    @State private var servicesSelection: String? = nil   // service id, or "synology"/"prowl"
    enum TopTab { case notifications, storage, services }
    @State private var topTab: TopTab = .services   // open on the first (leftmost) tab
    @State private var savePending: DispatchWorkItem? = nil
    /// True until one runloop turn after load() finishes populating @State, so the
    /// initial onAppear mutations don't trip the change detector — opening Settings
    /// must not write config.json (a spurious save used to drop unmanaged keys).
    @State private var suppressSave = true

    private var configURL: URL { runner.configFileURL }   // native location (Application Support)

    @ViewBuilder private var notificationsPane: some View {
        HStack(spacing: 0) {
            // Left: alert categories
            List(selection: $notifSelection) {
                Section("Alerts") {
                    notifCategoryRow("services", "Services", "bell.badge").tag("services")
                    notifCategoryRow("storage",  "Storage",  "externaldrive").tag("storage")
                    notifCategoryRow("host",     "Host",     "desktopcomputer").tag("host")
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            // Right: the selected category's alerts
            notificationsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var notificationsDetail: some View {
        switch notifSelection {
        case "storage": storageAlertsDetail
        case "host":    hostAlertsDetail
        default:        servicesAlertsDetail
        }
    }

    @ViewBuilder
    private var servicesAlertsDetail: some View {
        notifCategory("Services", "bell.badge", .red,
                      subtitle: "Apps and daemons Charopos polls", master: $notifyServices) {
            Section {
                Group {
                    alertRow("bolt.horizontal.fill", .orange, "Service unreachable",
                             "Push when a service stays down", isOn: $alertServiceDown,
                             threshold: ($svcDownMinStr, 1...120, " min"))
                    alertRow("arrow.down.circle.fill", .blue, "Updates available",
                             "Daily digest of available updates", isOn: $alertUpdatesAvailable)
                    alertRow("ant.fill", .purple, "Zombie / hung processes",
                             "A process hangs or goes defunct", isOn: $alertZombieProcess)
                }
                .disabled(!notifyServices)
                .opacity(notifyServices ? 1 : 0.5)
            } footer: {
                Text("Turn the category switch off to mute every Services alert without losing each toggle's setting.")
            }
        }
    }

    @ViewBuilder
    private var storageAlertsDetail: some View {
        notifCategory("Storage", "externaldrive.fill", .blue,
                      subtitle: "Disks and backups", master: $notifyStorage) {
            Section {
                Group {
                    alertRow("externaldrive.fill", .red, "NAS offline",
                             "A NAS stops responding", isOn: $alertNASOffline)
                    alertRow("internaldrive.fill", .red, "SMART health failure",
                             "A drive reports a SMART failure", isOn: $alertSMARTFailure)
                    alertRow("exclamationmark.triangle.fill", .orange, "SMART reallocated sectors",
                             "Reallocated sector count climbs", isOn: $alertSMARTReallocated)
                    alertRow("clock.arrow.circlepath", .indigo, "Time Machine stalled",
                             "A backup stalls or errors out", isOn: $alertTimeMachineError)
                    alertRow("chart.pie.fill", .green, "Disk space low",
                             "Free space below the threshold", isOn: $alertDiskSpace,
                             threshold: ($diskAlertPct, 50...99, " %"))
                }
                .disabled(!notifyStorage)
                .opacity(notifyStorage ? 1 : 0.5)
            }
            Section {
                HStack(spacing: 10) {
                    rowLabel("eye.fill", .teal, "Monitor Ghosts",
                             runner.states["watch"] == .running ? "Running" : "Stopped")
                    Spacer()
                    Toggle("", isOn: $ghostMonitorEnabled).labelsHidden().toggleStyle(.switch)
                }
                .onChange(of: ghostMonitorEnabled) { enabled in
                    guard !suppressSave else { return }   // load() populating state, not a user action
                    scheduleSave()
                    guard let item = Runner.items.first(where: { $0.id == "watch" }) else { return }
                    if enabled { runner.run(item) } else { runner.stop(item) }
                }
            } header: {
                Text("Monitoring")
            } footer: {
                Text("The Ghost monitor is a running process, so the category switch above doesn't stop it.")
            }
        }
    }

    @ViewBuilder
    private var hostAlertsDetail: some View {
        notifCategory("Host", "desktopcomputer", .indigo,
                      subtitle: "Health of the Mac itself", master: $notifyHost) {
            Section {
                Group {
                    alertRow("clock.fill", .blue, "NTP clock drift",
                             "System clock drifts more than 500 ms", isOn: $alertNTPDrift)
                    alertRow("memorychip.fill", .pink, "Swap usage high",
                             "Large relative to RAM \(swapThresholdHint)", isOn: $alertSwapHigh,
                             threshold: ($swapAlertPctStr, 5...300, " %"))
                    alertRow("memorychip", .red, "Memory pressure critical",
                             "The system hits critical memory pressure", isOn: $alertMemoryPressure)
                    alertRow("globe", .cyan, "External IP changed",
                             "Your public IP address changes", isOn: $alertExternalIPChange)
                    alertRow("powerplug.fill", .yellow, "UPS on battery",
                             "Mains power lost and the UPS engages", isOn: $alertUPSOnBattery)
                    alertRow("battery.25", .red, "UPS battery low",
                             "UPS charge below the threshold", isOn: $alertUPSLowBattery,
                             threshold: ($upsBatteryLowPctStr, 5...95, " %"))
                }
                .disabled(!notifyHost)
                .opacity(notifyHost ? 1 : 0.5)
            }
        }
    }

    // MARK: Notification building blocks

    /// Sidebar category row: icon + name, dimmed when that category's master is off.
    @ViewBuilder
    private func notifCategoryRow(_ id: String, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(label).foregroundStyle(notifMaster(id).wrappedValue ? .primary : .secondary)
        }
    }

    /// Detail scaffold for an alert category: header (icon, title, subtitle, master switch) + grouped form.
    @ViewBuilder
    private func notifCategory<Rows: View>(_ title: String, _ symbol: String, _ color: Color,
                                           subtitle: String, master: Binding<Bool>,
                                           @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconTile(symbol, color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: master).labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Divider()
            Form { rows() }.formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func notifMaster(_ id: String) -> Binding<Bool> {
        switch id {
        case "storage": return $notifyStorage
        case "host":    return $notifyHost
        default:        return $notifyServices
        }
    }

    // MARK: Notification rows (icon tile + title/subtitle + inline threshold + switch)

    /// Colored rounded icon tile, System-Settings style.
    @ViewBuilder
    private func iconTile(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    /// Row label: icon tile + bold title over a secondary subtitle.
    @ViewBuilder
    private func rowLabel(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            iconTile(symbol, color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// An alert row: icon + title/subtitle, an optional inline threshold stepper, and a trailing switch.
    @ViewBuilder
    private func alertRow(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String,
                          isOn: Binding<Bool>,
                          threshold: (value: Binding<String>, range: ClosedRange<Int>, unit: String)? = nil) -> some View {
        HStack(spacing: 10) {
            rowLabel(symbol, color, title, subtitle)
            Spacer(minLength: 8)
            if let t = threshold {
                HStack(spacing: 4) {
                    Text("\(t.value.wrappedValue)\(t.unit)").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: intBinding(t.value, clampedTo: t.range), in: t.range).labelsHidden()
                }
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.4)
            }
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    /// Bridge a String-backed numeric field to an Int Stepper, clamped to range.
    private func intBinding(_ s: Binding<String>, clampedTo range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { min(max(Int(s.wrappedValue) ?? range.lowerBound, range.lowerBound), range.upperBound) },
            set: { s.wrappedValue = String($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Safari-style toolbar tab strip: icon over label, selected item tinted.
            HStack(spacing: 4) {
                TopTabButton(title: "Services", systemImage: "square.stack.3d.up",
                             isSelected: topTab == .services) { topTab = .services }
                TopTabButton(title: "Storage", systemImage: "externaldrive",
                             isSelected: topTab == .storage) { topTab = .storage }
                TopTabButton(title: "Notifications", systemImage: "bell",
                             isSelected: topTab == .notifications) { topTab = .notifications }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch topTab {
                case .notifications: notificationsPane
                case .storage:       storagePane
                case .services:      servicesPane
                }
            }
            .frame(minHeight: 460)
        }
        .frame(width: 640)
        .onAppear { load() }
        .onChange(of: prefsSaveKey) { _ in scheduleSave() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingSave()
        }
    }

    /// Live "≈ N GB" hint for the swap-percent field — shows what the chosen
    /// percent of *this machine's* RAM works out to, so the self-sizing is visible.
    private var swapThresholdHint: String {
        guard let pct = Double(swapAlertPctStr), pct > 0 else { return "" }
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return String(format: "(≈ %.0f GB)", ramGB * pct / 100.0)
    }

    /// Composite key over all prefs fields — single onChange watcher avoids
    /// deeply-nested generic types that time out the Swift type checker.
    private var prefsSaveKey: String {
        // Split into sub-expressions so the Swift type-checker doesn't time out on
        // one long `+` chain of interpolated literals.
        let keys  = "\(prowlApiKey)\(dashboardURLStr)\(sabnzbdApiKey)\(sonarrApiKey)\(radarrApiKey)\(lidarrApiKey)\(prowlarrApiKey)\(overseerrApiKey)\(tautulliApiKey)\(jellyfinApiKey)\(bazarrApiKey)"
        let creds = "\(synologyUser)\(nasMountUser)\(synologyPass)\(piholePassword)\(piholeSshTarget)\(piholeSshKey)\(cloudKeyHost)\(cloudKeySshKey)\(qbitUser)\(qbitPass)"
        let nums  = "\(inventoryEnabled)\(inventoryDays)\(diskAlertPct)\(svcDownMinStr)\(swapAlertPctStr)\(upsBatteryLowPctStr)"
        let alerts = "\(alertNASOffline)\(alertServiceDown)\(alertUpdatesAvailable)\(alertDiskSpace)\(alertUPSOnBattery)\(alertUPSLowBattery)\(alertMemoryPressure)\(alertSwapHigh)\(alertExternalIPChange)\(alertZombieProcess)\(alertNTPDrift)\(alertSMARTFailure)\(alertSMARTReallocated)\(alertTimeMachineError)\(ghostMonitorEnabled)\(notifyServices)\(notifyStorage)\(notifyHost)\(apiBindMode)"
        let nas  = nasUnits.map { "\($0.id)\($0.label)\($0.checkURL)\($0.openURL)\($0.mountPoint)\($0.mountSource)\($0.suppressSpaceAlert)" }.joined()
        let vols = localVolumes.map { "\($0.id)\($0.label)\($0.mountPoint)\($0.suppressSpaceAlert)" }.joined()
        let places = actionPlacementsState.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let svcURLs = Runner.serviceDefaults.map { "\(svcLocalURLs[$0.id] ?? "")\(svcOpenURLs[$0.id] ?? "")" }.joined()
        let svcs = svcURLs + disabledServices.sorted().joined(separator: ",") + "|" + places
        return keys + creds + nums + alerts + nas + vols + svcs
    }

    private func makeNASID(from label: String) -> String {
        let slug = label.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(16)
        let base = slug.isEmpty ? "nas" : String(slug)
        if !nasUnits.contains(where: { $0.id == base }) { return base }
        return base + "-" + String(UUID().uuidString.prefix(4).lowercased())
    }

    private func makeVolID(from label: String) -> String {
        let slug = label.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(16)
        let base = slug.isEmpty ? "vol" : String(slug)
        if !localVolumes.contains(where: { $0.id == base }) { return base }
        return base + "-" + String(UUID().uuidString.prefix(4).lowercased())
    }

    @ViewBuilder
    private var storagePane: some View {
        HStack(spacing: 0) {
            // Left: master list of NAS units + local volumes
            List(selection: $storageSelection) {
                Section("NAS Units") {
                    ForEach($nasUnits) { $nas in
                        storageRow(nas.label, symbol: "externaldrive.connected.to.line.below")
                            .tag("nas:\(nas.id)")
                    }
                    addRow("Add NAS") {
                        let unit = NASUnit(id: makeNASID(from: ""),
                                           label: "", checkURL: "", openURL: "", mountPoint: "")
                        nasUnits.append(unit)
                        storageSelection = "nas:\(unit.id)"
                    }
                }
                Section("Local Volumes") {
                    ForEach($localVolumes) { $vol in
                        storageRow(vol.label, symbol: "internaldrive")
                            .tag("vol:\(vol.id)")
                    }
                    addRow("Add Volume") {
                        let vol = LocalVolume(id: makeVolID(from: ""), label: "", mountPoint: "")
                        localVolumes.append(vol)
                        storageSelection = "vol:\(vol.id)"
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            // Right: detail editor for the selected item
            ScrollView { storageDetail }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var storageDetail: some View {
        if let sel = storageSelection, sel.hasPrefix("nas:"),
           let binding = nasBinding(String(sel.dropFirst(4))) {
            detailScaffold(binding.wrappedValue.label, symbol: "externaldrive.connected.to.line.below",
                           subtitle: "Network-attached storage",
                           onRemove: { nasUnits.removeAll { $0.id == binding.wrappedValue.id }; storageSelection = nil }) {
                infraField("Label",        binding.label)
                infraField("Health URL",   binding.checkURL,   placeholder: "https://nas.local:5001")
                infraField("Web URL",      binding.openURL,    placeholder: "http://QuickConnect.to/…")
                infraField("Mount Point",  binding.mountPoint, placeholder: "/Volumes/…")
                infraField("Mount Source", binding.mountSource, placeholder: "smb://nas.local/Share (optional — for NAS Refresh)")
                Toggle("Suppress space alerts", isOn: binding.suppressSpaceAlert)
                    .controlSize(.small)
                    .help("Exempt this NAS from the disk-space Prowl alert even when usage is above the threshold.")
            }
        } else if let sel = storageSelection, sel.hasPrefix("vol:"),
                  let binding = volBinding(String(sel.dropFirst(4))) {
            detailScaffold(binding.wrappedValue.label, symbol: "internaldrive",
                           subtitle: "Local volume",
                           onRemove: { localVolumes.removeAll { $0.id == binding.wrappedValue.id }; storageSelection = nil }) {
                infraField("Label",       binding.label)
                infraField("Mount Point", binding.mountPoint, placeholder: "/Volumes/…")
                Toggle("Suppress space alerts", isOn: binding.suppressSpaceAlert)
                    .controlSize(.small)
                    .help("For drives expected to stay full: keep the light green (don't turn orange or raise the overall status) even when usage is above the disk-alert threshold.")
            }
        } else {
            noSelection
        }
    }

    @ViewBuilder
    private var servicesPane: some View {
        HStack(spacing: 0) {
            // Left: master list of services + integrations
            List(selection: $servicesSelection) {
                Section("Media") {
                    ForEach(Runner.serviceDefaults.filter { Self.mediaServiceIDs.contains($0.id) }, id: \.id) { svc in
                        serviceRow(svc.id, svc.label).tag(svc.id)
                    }
                }
                Section("Network") {
                    ForEach(Runner.serviceDefaults.filter { Self.networkServiceIDs.contains($0.id) }, id: \.id) { svc in
                        serviceRow(svc.id, svc.label).tag(svc.id)
                    }
                }
                Section("Integrations") {
                    integrationRow("synology", "Synology").tag("synology")
                    integrationRow("prowl",    "Prowl").tag("prowl")
                    integrationRow("remote",   "Remote Access").tag("remote")
                    integrationRow("certs",    "Certificates").tag("certs")
                    integrationRow("actions",  "Actions").tag("actions")
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            // Right: detail editor for the selected service / integration
            ScrollView { servicesDetail }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var servicesDetail: some View {
        if let sel = servicesSelection {
            if sel == "synology" {
                synologyDetail
            } else if sel == "prowl" {
                prowlDetail
            } else if sel == "remote" {
                remoteAccessDetail
            } else if sel == "certs" {
                certificatesDetail
            } else if sel == "actions" {
                actionsDetail
            } else if let svc = Runner.serviceDefaults.first(where: { $0.id == sel }) {
                serviceDetail(svc)
            } else {
                noSelection
            }
        } else {
            noSelection
        }
    }

    private static let mediaServiceIDs:   Set<String> = ["sab", "sonarr", "radarr", "prowlarr", "lidarr", "plex", "jellyfin", "bazarr", "overseerr", "tautulli", "qbittorrent"]
    private static let networkServiceIDs: Set<String> = ["tailscale", "pihole", "cloudkey"]

    // MARK: Sidebar rows

    /// A service row: enable checkbox + icon + name (dimmed when disabled), Safari-style.
    @ViewBuilder
    private func serviceRow(_ id: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabledBinding(id)).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: serviceSymbol(id)).foregroundStyle(.tint).frame(width: 18)
            Text(label).foregroundStyle(disabledServices.contains(id) ? .secondary : .primary)
        }
    }

    /// An integration row (Synology / Prowl): icon + name, no enable checkbox.
    @ViewBuilder
    private func integrationRow(_ id: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: serviceSymbol(id)).foregroundStyle(.tint).frame(width: 18)
            Text(label)
        }
    }

    /// A storage row (NAS / volume): icon + label.
    @ViewBuilder
    private func storageRow(_ label: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(label.isEmpty ? "(unnamed)" : label)
        }
    }

    /// A non-selectable "+ Add …" row that lives at the bottom of a sidebar section.
    @ViewBuilder
    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    // MARK: Detail editors

    /// Shared header + framing for a detail editor: icon, title, subtitle, optional Remove.
    @ViewBuilder
    private func detailScaffold<Content: View>(_ title: String, symbol: String, subtitle: String,
                                               trailing: AnyView? = nil,
                                               onRemove: (() -> Void)? = nil,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? "(unnamed)" : title)
                        .font(.title3).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let trailing { trailing }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) { content() }
            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Detail editor for one polled service (API key, host/SSH where relevant, Health/Open URLs).
    @ViewBuilder
    private func serviceDetail(_ svc: (id: String, label: String, url: String?, openURL: String?)) -> some View {
        detailScaffold(svc.label, symbol: serviceSymbol(svc.id), subtitle: serviceSubtitle(svc.id),
                       trailing: AnyView(Toggle("Enabled", isOn: enabledBinding(svc.id)).toggleStyle(.checkbox))) {
            if let keyBinding = apiKeyBinding(for: svc.id) {
                infraField("API Key", keyBinding)   // API keys are not masked
            }
            if svc.id == "overseerr" {
                Text("API key from Overseerr/Jellyseerr \u{2192} Settings \u{2192} General. Enables the pending-requests badge and update detection. Jellyseerr-compatible \u{2014} point the URL at either.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if svc.id == "tautulli" {
                Text("API key from Tautulli \u{2192} Settings \u{2192} Web Interface. Enables update detection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if svc.id == "jellyfin" {
                Text("API key from Jellyfin \u{2192} Dashboard \u{2192} API Keys. Enables the active-stream spinner. The health URL uses Jellyfin's /health endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if svc.id == "cloudkey" {
                infraField("Host IP", $cloudKeyHost, placeholder: "192.168.1.2")
                infraField("SSH Key Path", $cloudKeySshKey)
            }
            if svc.id == "qbittorrent" {
                field("WebUI username", $qbitUser)
                SecretField(label: "WebUI password", text: $qbitPass)
                Text("Used for the download-count badge (qBittorrent's WebUI API needs a session login). The health light works without credentials. Stock WebUI port is 8080 \u{2014} the placeholder uses 8085 to avoid colliding with SABnzbd's default.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if svc.url != nil {
                infraField("Health URL", Binding(
                    get: { svcLocalURLs[svc.id] ?? "" },
                    set: { svcLocalURLs[svc.id] = $0 }
                ), placeholder: svc.url ?? "")
            }
            infraField("Open URL", Binding(
                get: { svcOpenURLs[svc.id] ?? "" },
                set: { svcOpenURLs[svc.id] = $0 }
            ), placeholder: svc.openURL ?? "(none)")
            if svc.id == "pihole" {
                Divider().padding(.vertical, 2)
                secretField("App password", $piholePassword)
                Text("PiHole v6 API. Create under the PiHole UI \u{2192} Settings \u{2192} API. Lets Charopos read block status (the orange \u{201C}disabled\u{201D} warning) and detect available updates (blue light).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 2)
                field("Update SSH host", $piholeSshTarget)
                field("Update SSH key", $piholeSshKey)
                Text("For click-to-update (\u{201C}pihole -up\u{201D} over SSH). Needs key auth + a NOPASSWD sudo entry for pihole on the host. Leave as-is if you only want the status light.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var synologyDetail: some View {
        detailScaffold("Synology", symbol: serviceSymbol("synology"),
                       subtitle: "DSM API & file mounting") {
            field("DSM user", $synologyUser)
            secretField("DSM password", $synologyPass)
            field("NAS mount user", $nasMountUser)
            Text("DSM user/password = Synology API (health, DSM updates). NAS mount user = AFP/SMB file mounting for NAS Refresh — often a different account; injected into each NAS's Mount Source.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $inventoryEnabled) {
                HStack(spacing: 6) {
                    Text("Log inventory every")
                    TextField("", text: $inventoryDays)
                        .frame(width: 45)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!inventoryEnabled)
                    Text("days").foregroundStyle(.secondary)
                }
            }
            .help("Write a text log of every file on every NAS on this schedule. Keeps the 10 most recent. Run on demand via the \u{201C}Run Inventory\u{201D} action.")
        }
    }

    @ViewBuilder
    private var prowlDetail: some View {
        detailScaffold("Prowl", symbol: serviceSymbol("prowl"),
                       subtitle: "Push notifications") {
            infraField("API Key", $prowlApiKey)   // API key is not masked
            infraField("Dashboard link", $dashboardURLStr, placeholder: Runner.shared.dashboardURL)
            Text("Attached to alerts as a tappable link. Blank = this Mac's name; set a Tailscale IP if .local doesn't resolve where you read alerts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Send test notification") {
                Runner.shared.testProwlNotification(apiKey: prowlApiKey)
            }
            .disabled(prowlApiKey.isEmpty)
        }
    }

    @ViewBuilder
    private var remoteAccessDetail: some View {
        detailScaffold("Remote Access", symbol: serviceSymbol("remote"),
                       subtitle: "Web dashboard & Remote app reachability") {
            HStack(spacing: 6) {
                Text("Allow remote access")
                Spacer()
                Picker("", selection: $apiBindMode) {
                    Text("This Mac only").tag("loopback")
                    Text("Tailscale only").tag("tailscale")
                    Text("All interfaces (LAN)").tag("all")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            Text(bindModeCaption)
                .font(.caption)
                .foregroundStyle(apiBindMode == "all" ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            Text("Remote clients authenticate with the API token — click the token line under the version number in the main Charopos window to copy it. (It's stored in launcher-remote-token.txt beside the app, readable only by you.) Dashboard address: \(Runner.shared.dashboardURL.isEmpty ? "unavailable" : Runner.shared.dashboardURL). Prefer Tailscale over exposing the raw LAN port.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            Button("Rotate API Token…") { showRotateTokenAlert = true }
                .alert("Rotate the API token?", isPresented: $showRotateTokenAlert) {
                    Button("Rotate", role: .destructive) {
                        Runner.shared.rotateAPIToken()
                        tokenJustRotated = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All connected clients (the Remote app and any web dashboards) will be signed out until you paste in the new token.")
                }
            if tokenJustRotated {
                Text("Token rotated — copy the new token from the main window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var certificatesDetail: some View {
        let pins = { _ = certsRevision; return CertPinStore.shared.summary }()
        detailScaffold("Certificates", symbol: serviceSymbol("certs"),
                       subtitle: "Remembered TLS identities of your local hosts") {
            Text("NAS and Pi-hole boxes usually serve a certificate no public authority has signed, so Charopos remembers the one each host presents the first time it connects and refuses that host if it later presents a different one. That keeps the DSM and Pi-hole passwords from being handed to whatever is answering at that address.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            if pins.isEmpty {
                Text("No certificates remembered yet — nothing has been reached over HTTPS since the last reset.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(pins, id: \.host) { pin in
                    let label = Runner.shared.labelForPinnedHost(pin.host)
                    HStack(spacing: 6) {
                        Image(systemName: pin.mode == "system" ? "checkmark.seal" : "lock.shield")
                            .foregroundStyle(pin.mode == "system" ? .green : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            // Lead with the name this host goes by everywhere else in
                            // the app; the host:port is what's actually pinned, so it
                            // stays visible either way.
                            if let label {
                                HStack(spacing: 6) {
                                    Text(label)
                                    Text(pin.host).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(pin.host)
                            }
                            Text(pin.mode == "system"
                                 ? "Publicly trusted certificate — validated normally"
                                 : "Self-signed, trusted on first use\(pin.firstSeen.isEmpty ? "" : ", \(pin.firstSeen)") · key \(CertPinStore.short(pin.fingerprint))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") {
                            CertPinStore.shared.forget(pin.host)
                            certsRevision += 1
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this host's certificate — the next connection will trust what it presents")
                    }
                }
            }
            Divider().padding(.vertical, 2)
            Button("Forget Pinned Certificates…") { showForgetCertsAlert = true }
                .alert("Forget every remembered certificate?", isPresented: $showForgetCertsAlert) {
                    Button("Forget", role: .destructive) {
                        CertPinStore.shared.forgetAll()
                        certsRevision += 1
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Charopos will trust whatever certificate each host presents the next time it connects. Do this after you deliberately replace a certificate — not to clear a warning you weren't expecting.")
                }
            Text("A certificate that changes without you changing it is worth investigating before you clear it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Explanatory caption under the Remote Access bind-mode picker, keyed to the selected mode.
    private var bindModeCaption: String {
        switch apiBindMode {
        case "tailscale":
            return "Bound to this Mac's Tailscale address (100.x). Traffic is end-to-end encrypted by WireGuard. If Tailscale is offline at launch, Charopos falls back to loopback and rebinds automatically when the tailnet comes up."
        case "all":
            return "⚠️ Trusted networks only. The API uses unencrypted HTTP — anyone on the network who captures the token can control this server. Prefer Tailscale only if the Mac is on a shared LAN."
        default:
            return "The dashboard and API are reachable only from this Mac."
        }
    }

    /// Metadata for the hideable action rows (shared with onboarding's Actions step).
    static let actionInfo: [(id: String, title: String, symbol: String, desc: String)] = [
        ("mount",     "NAS Refresh",    "arrow.triangle.2.circlepath", "Remount NAS shares and relaunch media apps. Also runs automatically at boot."),
        ("iperf",     "iperf3 Server",  "speedometer",                 "Built-in network throughput test server."),
        ("inventory", "Run Inventory",  "list.bullet.rectangle",       "Log every file on every NAS, on demand or on a schedule."),
        ("kickstart", "Kickstart Plex", "bolt",                        "Cleanly restart the media stack (Plex + the arr apps + SABnzbd)."),
        ("kickstart-jellyfin", "Kickstart Jellyfin", "bolt.horizontal.circle", "Cleanly restart the Jellyfin media server."),
        ("scan-libraries",     "Scan Libraries",        "books.vertical",  "Ask Plex and Jellyfin to rescan their libraries now."),
        ("clear-transcode",    "Clear Transcode Cache", "trash",           "Delete Plex/Jellyfin transcode temp files to reclaim space."),
        ("check-updates",      "Check for Updates",     "arrow.clockwise", "Refresh every update badge now instead of waiting for the hourly check."),
        ("pause-downloads",    "Pause / Resume Downloads", "pause.circle", "Toggle pause on SABnzbd and qBittorrent in one tap."),
        ("bazarr-search",      "Search Subtitles",      "captions.bubble", "Ask Bazarr to search for missing subtitles (needs a Bazarr API key)."),
        ("backup",             "Back Up Now",           "externaldrive.badge.timemachine", "Start a Time Machine backup immediately (a destination must already be set up)."),
        ("pihole-gravity",     "Update Pi-hole Gravity","shield.lefthalf.filled", "SSH to Pi-hole and rebuild its blocklist database (pihole -g)."),
        ("reboot",    "Reboot Server",  "power",                       "Restart this Mac from any surface."),
    ]

    @ViewBuilder
    private var actionsDetail: some View {
        detailScaffold("Actions", symbol: serviceSymbol("actions"),
                       subtitle: "Where each action appears") {
            ForEach(Self.actionInfo, id: \.id) { a in
                HStack(spacing: 10) {
                    Image(systemName: a.symbol).foregroundStyle(.tint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title)
                        Text(a.desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text("Add to:").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: placementBinding(a.id)) {
                            Text("None").tag("none")
                            Text("Menu Only").tag("menu")
                            Text("Main Window").tag("main")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("**None** hides the action everywhere. **Menu Only** shows it in the menu-bar and Actions menu. **Main Window** also adds it to the desktop window's action column (max \(Runner.maxMainWindowActions)). The web dashboard shows every action that isn't None. Hiding NAS Refresh (None) also disables its automatic run at boot; internal automation (e.g. Kickstart remounting drives) is unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if mainCapHit {
                    Label("Main Window is full (\(Runner.maxMainWindowActions) max) — set another action to None or Menu Only first.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// How many actions are currently assigned to the main window (for the 6-slot cap).
    private var mainPlacementCount: Int {
        Self.actionInfo.reduce(0) { $0 + ((actionPlacementsState[$1.id] ?? "none") == "main" ? 1 : 0) }
    }

    /// Placement picker binding. Refuses a move to Main Window once the cap is reached
    /// (flashes `mainCapHit`), so the invariant holds without disabling a Picker row.
    private func placementBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { actionPlacementsState[id] ?? "none" },
            set: { newValue in
                if newValue == "main",
                   (actionPlacementsState[id] ?? "none") != "main",
                   mainPlacementCount >= Runner.maxMainWindowActions {
                    mainCapHit = true
                    return   // reject — binding get() snaps the Picker back
                }
                mainCapHit = false
                actionPlacementsState[id] = newValue
            }
        )
    }

    /// Shown in the detail pane when nothing is selected in the sidebar.
    @ViewBuilder
    private var noSelection: some View {
        VStack {
            Spacer()
            Text("No Selection").font(.title3).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bindings & lookups

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledServices.contains(id) },
            set: { on in if on { disabledServices.remove(id) } else { disabledServices.insert(id) } }
        )
    }

    // Id-based bindings that re-resolve the element on every access. An index-captured
    // binding ($array[idx]) freezes the index at render time — a focused TextField
    // flushing its edit after Remove shrinks the array could write out of range (crash)
    // or into the wrong element. These degrade to a harmless no-op instead.
    private func nasBinding(_ id: String) -> Binding<NASUnit>? {
        guard let current = nasUnits.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { nasUnits.first(where: { $0.id == id }) ?? current },
            set: { new in
                if let i = nasUnits.firstIndex(where: { $0.id == id }) { nasUnits[i] = new }
            }
        )
    }

    private func volBinding(_ id: String) -> Binding<LocalVolume>? {
        guard let current = localVolumes.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { localVolumes.first(where: { $0.id == id }) ?? current },
            set: { new in
                if let i = localVolumes.firstIndex(where: { $0.id == id }) { localVolumes[i] = new }
            }
        )
    }

    private func serviceSymbol(_ id: String) -> String {
        switch id {
        case "sab":       return "arrow.down.circle"
        case "sonarr":    return "tv"
        case "radarr":    return "film"
        case "lidarr":    return "music.note"
        case "prowlarr":  return "magnifyingglass"
        case "plex":      return "play.rectangle.fill"
        case "jellyfin":  return "play.tv"
        case "bazarr":    return "captions.bubble"
        case "overseerr": return "tray.full"
        case "tautulli":  return "chart.bar"
        case "qbittorrent": return "arrow.down.square"
        case "tailscale": return "network"
        case "pihole":    return "shield.lefthalf.filled"
        case "cloudkey":  return "wifi"
        case "synology":  return "externaldrive.connected.to.line.below"
        case "prowl":     return "bell.badge"
        case "remote":    return "antenna.radiowaves.left.and.right"
        case "certs":     return "lock.shield"
        case "actions":   return "play.square.stack"
        default:          return "square.stack.3d.up"
        }
    }

    private func serviceSubtitle(_ id: String) -> String {
        switch id {
        case "sab":       return "Download client"
        case "sonarr":    return "TV automation"
        case "radarr":    return "Movie automation"
        case "lidarr":    return "Music automation"
        case "prowlarr":  return "Indexer manager"
        case "plex":      return "Media server"
        case "jellyfin":  return "Media server"
        case "bazarr":    return "Subtitle automation"
        case "overseerr": return "Request management (Jellyseerr-compatible)"
        case "tautulli":  return "Plex statistics"
        case "qbittorrent": return "Torrent client"
        case "tailscale": return "Mesh VPN"
        case "pihole":    return "Network ad-blocker"
        case "cloudkey":  return "UniFi console (CloudKey / UDM / UDR)"
        case "certs":     return "Remembered TLS certificates"
        default:          return "Service"
        }
    }

    private func apiKeyBinding(for id: String) -> Binding<String>? {
        switch id {
        case "sab":      return $sabnzbdApiKey
        case "sonarr":   return $sonarrApiKey
        case "radarr":   return $radarrApiKey
        case "lidarr":   return $lidarrApiKey
        case "prowlarr": return $prowlarrApiKey
        case "overseerr": return $overseerrApiKey
        case "tautulli":  return $tautulliApiKey
        case "jellyfin":  return $jellyfinApiKey
        case "bazarr":    return $bazarrApiKey
        default:         return nil
        }
    }

    @ViewBuilder
    private func infraField(_ label: String, _ binding: Binding<String>,
                            placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity)
        }
    }

    private func scheduleSave() {
        guard !suppressSave else { return }   // ignore the initial load()'s mutations
        savePending?.cancel()
        let work = DispatchWorkItem { self.savePending = nil; self.save() }
        savePending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Flush a pending debounced save immediately (app quit / reboot) so an edit
    /// made within the 0.5 s debounce window isn't silently lost.
    private func flushPendingSave() {
        guard savePending != nil else { return }
        savePending?.cancel()
        savePending = nil
        save()
    }

    @ViewBuilder
    private func field(_ label: String, _ binding: Binding<String>,
                       placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func secretField(_ label: String, _ binding: Binding<String>) -> some View {
        SecretField(label: label, text: binding)
    }

    private func load() {
        // Release the save suppression one runloop turn after load() returns (covers the
        // early-return fresh-install path too) — the mutations below fire onChange during
        // the current view-update cycle, so by the time the async block runs, they're done.
        defer { DispatchQueue.main.async { suppressSave = false } }
        // Mirror Runner's live arrays into local @State so edits don't affect Runner until saved
        nasUnits     = Runner.shared.nasUnits
        disabledServices = Runner.shared.disabledServices
        actionPlacementsState = Runner.shared.actionPlacements
        localVolumes = Runner.shared.localVolumes
        for svc in Runner.shared.services {
            svcLocalURLs[svc.id] = svc.url     ?? ""
            svcOpenURLs[svc.id]  = svc.openURL ?? ""
        }
        // Default the master-detail panes to their first item so they don't open blank.
        if servicesSelection == nil {
            servicesSelection = Runner.serviceDefaults.first?.id ?? "synology"
        }
        if storageSelection == nil {
            if let nas = nasUnits.first { storageSelection = "nas:\(nas.id)" }
            else if let vol = localVolumes.first { storageSelection = "vol:\(vol.id)" }
        }

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        prowlApiKey    = json["prowlApiKey"]    as? String ?? ""
        dashboardURLStr = json["dashboardURL"]  as? String ?? ""
        sabnzbdApiKey  = json["sabnzbdApiKey"]  as? String ?? ""
        sonarrApiKey   = json["sonarrApiKey"]   as? String ?? ""
        radarrApiKey   = json["radarrApiKey"]   as? String ?? ""
        lidarrApiKey   = json["lidarrApiKey"]   as? String ?? ""
        prowlarrApiKey = json["prowlarrApiKey"] as? String ?? ""
        overseerrApiKey = json["overseerrApiKey"] as? String ?? ""
        tautulliApiKey  = json["tautulliApiKey"]  as? String ?? ""
        jellyfinApiKey  = json["jellyfinApiKey"]  as? String ?? ""
        bazarrApiKey    = json["bazarrApiKey"]    as? String ?? ""
        qbitUser        = json["qbitUser"]        as? String ?? ""
        qbitPass        = json["qbitPass"]        as? String ?? ""
        synologyUser   = json["synologyUser"]   as? String ?? ""
        nasMountUser   = json["nasMountUser"]    as? String ?? ""
        synologyPass   = json["synologyPass"]   as? String ?? ""
        piholePassword = json["piholePassword"] as? String ?? ""
        piholeSshTarget = json["piholeSshTarget"] as? String ?? "pi@pihole.local"
        piholeSshKey   = json["piholeSshKey"]   as? String ?? (NSHomeDirectory() + "/.ssh/pihole_ed25519")
        inventoryEnabled = (json["inventoryEnabled"] as? String) == "true"
        inventoryDays    = json["inventoryDays"] as? String ?? "7"
        cloudKeyHost   = json["cloudKeyHost"]   as? String ?? ""
        let rawSshKey = json["cloudKeySshKey"] as? String ?? ""
        cloudKeySshKey = rawSshKey.isEmpty ? (NSHomeDirectory() + "/.ssh/cloudkey_ed25519") : rawSshKey
        diskAlertPct        = json["diskAlertThreshold"] as? String ?? "90"
        svcDownMinStr       = json["svcDownMinutes"]     as? String ?? "5"
        upsBatteryLowPctStr = json["upsBatteryLowPct"]  as? String ?? "20"
        swapAlertPctStr     = json["swapAlertPct"]       as? String ?? "25"
        alertNASOffline       = (json["alertNASOffline"]       as? String) != "false"
        alertServiceDown      = (json["alertServiceDown"]      as? String) != "false"
        alertUpdatesAvailable = (json["alertUpdatesAvailable"] as? String) != "false"
        alertDiskSpace        = (json["alertDiskSpace"]        as? String) != "false"
        alertUPSOnBattery     = (json["alertUPSOnBattery"]     as? String) != "false"
        alertUPSLowBattery    = (json["alertUPSLowBattery"]    as? String) != "false"
        alertMemoryPressure   = (json["alertMemoryPressure"]   as? String) != "false"
        alertSwapHigh         = (json["alertSwapHigh"]         as? String) != "false"
        alertExternalIPChange = (json["alertExternalIPChange"] as? String) != "false"
        alertZombieProcess    = (json["alertZombieProcess"]    as? String) != "false"
        alertNTPDrift         = (json["alertNTPDrift"]         as? String) != "false"
        alertSMARTFailure     = (json["alertSMARTFailure"]     as? String) != "false"
        alertSMARTReallocated = (json["alertSMARTReallocated"] as? String) != "false"
        alertTimeMachineError = (json["alertTimeMachineError"] as? String) != "false"
        ghostMonitorEnabled   = (json["ghostMonitorEnabled"]   as? String) != "false"
        notifyServices        = (json["notifyServices"]        as? String) != "false"
        notifyStorage         = (json["notifyStorage"]         as? String) != "false"
        notifyHost            = (json["notifyHost"]            as? String) != "false"
        // Prefer the 3-mode key; fall back to the legacy Bool for configs written before it existed.
        apiBindMode = (json["apiBindMode"] as? String).flatMap { ["loopback", "tailscale", "all"].contains($0) ? $0 : nil }
            ?? (((json["allowRemoteAccess"] as? String) == "true") ? "all" : "loopback")   // default loopback (secure)
    }

    private func save() {
        // Read-modify-write: merge over the existing file so keys this view doesn't
        // manage (probedVersion, future additions) survive a save. apiBindMode and its
        // legacy allowRemoteAccess mirror are managed below.
        // Rebuilding from scratch used to drop allowRemoteAccess — loadConfig()'s
        // missing-key heuristic then re-seeded it TRUE, silently flipping a fresh
        // install's API server from loopback-only to all-interfaces.
        var json: [String: Any] = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let managed: [String: Any] = [
            "prowlApiKey":    prowlApiKey,
            "dashboardURL":   dashboardURLStr,
            "sabnzbdApiKey":  sabnzbdApiKey,
            "sonarrApiKey":   sonarrApiKey,
            "radarrApiKey":   radarrApiKey,
            "lidarrApiKey":   lidarrApiKey,
            "prowlarrApiKey": prowlarrApiKey,
            "overseerrApiKey": overseerrApiKey,
            "tautulliApiKey":  tautulliApiKey,
            "jellyfinApiKey":  jellyfinApiKey,
            "bazarrApiKey":    bazarrApiKey,
            "qbitUser":        qbitUser,
            "qbitPass":        qbitPass,
            "synologyUser":   synologyUser,
            "nasMountUser":   nasMountUser,
            "synologyPass":   synologyPass,
            "piholePassword": piholePassword,
            "piholeSshTarget": piholeSshTarget,
            "piholeSshKey":   piholeSshKey,
            "inventoryEnabled": inventoryEnabled ? "true" : "false",
            "inventoryDays":    inventoryDays,
            "cloudKeyHost":       cloudKeyHost,
            "cloudKeySshKey":     cloudKeySshKey,
            "diskAlertThreshold":  diskAlertPct,
            "svcDownMinutes":      svcDownMinStr,
            "upsBatteryLowPct":    upsBatteryLowPctStr,
            "swapAlertPct":        swapAlertPctStr,
            "alertNASOffline":       alertNASOffline       ? "true" : "false",
            "alertServiceDown":      alertServiceDown      ? "true" : "false",
            "alertUpdatesAvailable": alertUpdatesAvailable ? "true" : "false",
            "alertDiskSpace":        alertDiskSpace        ? "true" : "false",
            "alertUPSOnBattery":     alertUPSOnBattery     ? "true" : "false",
            "alertUPSLowBattery":    alertUPSLowBattery    ? "true" : "false",
            "alertMemoryPressure":   alertMemoryPressure   ? "true" : "false",
            "alertSwapHigh":         alertSwapHigh         ? "true" : "false",
            "alertExternalIPChange": alertExternalIPChange ? "true" : "false",
            "alertZombieProcess":    alertZombieProcess    ? "true" : "false",
            "alertNTPDrift":         alertNTPDrift         ? "true" : "false",
            "alertSMARTFailure":     alertSMARTFailure     ? "true" : "false",
            "alertSMARTReallocated": alertSMARTReallocated ? "true" : "false",
            "alertTimeMachineError": alertTimeMachineError ? "true" : "false",
            "ghostMonitorEnabled":   ghostMonitorEnabled   ? "true" : "false",
            "notifyServices":        notifyServices        ? "true" : "false",
            "notifyStorage":         notifyStorage         ? "true" : "false",
            "notifyHost":            notifyHost            ? "true" : "false",
            "apiBindMode":           apiBindMode,
            "allowRemoteAccess":     apiBindMode != "loopback" ? "true" : "false",   // back-compat mirror
            "hideDockIcon":          Runner.shared.hideDockIcon        ? "true" : "false",
            "showWindowAtStartup":   Runner.shared.showWindowAtStartup ? "true" : "false",
        ]
        json.merge(managed) { _, new in new }
        // Infrastructure arrays
        json["nasUnits"] = nasUnits.map { [
            "id": $0.id, "label": $0.label,
            "checkURL": $0.checkURL, "openURL": $0.openURL, "mountPoint": $0.mountPoint,
            "mountSource": $0.mountSource,
            "suppressSpaceAlert": $0.suppressSpaceAlert
        ] as [String: Any] }
        json["localVolumes"] = localVolumes.map { [
            "id": $0.id, "label": $0.label, "mountPoint": $0.mountPoint,
            "suppressSpaceAlert": $0.suppressSpaceAlert
        ] as [String: Any] }
        // Service URL overrides — only keep entries that differ from defaults.
        // Assigned unconditionally (even when empty) so reverting a URL to its
        // default actually clears the old override in the merged file.
        var serviceURLs: [String: [String: String]] = [:]
        for def in Runner.serviceDefaults {
            var entry: [String: String] = [:]
            let localURL = svcLocalURLs[def.id] ?? ""
            let openURL  = svcOpenURLs[def.id]  ?? ""
            if localURL != (def.url ?? "")     { entry["url"]     = localURL }
            if openURL  != (def.openURL ?? "") { entry["openURL"] = openURL }
            if !entry.isEmpty { serviceURLs[def.id] = entry }
        }
        json["serviceURLs"] = serviceURLs
        json["disabledServices"] = Array(disabledServices)
        json["actionPlacements"] = actionPlacementsState
        // Keep the legacy disabledActions in sync (none-placed = hidden) so an older
        // build reading this config still hides the right rows. Array(...) because
        // optionalActionIDs is a Set and Set.filter returns a Set (invalid JSON type).
        json["disabledActions"]  = Array(Runner.optionalActionIDs.filter { (actionPlacementsState[$0] ?? "none") == "none" })
        json["knownServices"] = Runner.serviceDefaults.map(\.id)   // roster-migration marker (see Runner.loadConfig)

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        let bindWas = Runner.shared.apiBindMode
        try? data.write(to: configURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        Runner.shared.loadConfig()
        // Rebind the API listener when the bind mode actually changed
        // (loopback ⇄ tailscale ⇄ all interfaces takes effect immediately, no relaunch).
        if Runner.shared.apiBindMode != bindWas {
            Runner.shared.restartAPI()
        }
        // Menubar action items are built once — refresh them if the hidden set changed.
        AppDelegate.shared?.rebuildMenuBarMenu()
    }
}

// MARK: - Preferences

/// Safari-preferences-style top tab: icon over label, tinted + highlighted when selected.
private struct TopTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(title).font(.caption)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 90)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15)
                                     : (hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
        // focusEffectDisabled is macOS 14+; on Ventura .focusable(false) alone
        // already keeps this decorative row out of the focus ring.
        .modifier(NoFocusEffect())
        .onHover { hovering = $0 }
    }
}

/// Suppresses the focus ring where the API exists (macOS 14+); a no-op on
/// Ventura, where `.focusable(false)` is already sufficient here.
private struct NoFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct SecretField: View {
    let label: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
