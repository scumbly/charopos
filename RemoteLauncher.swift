import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - Model

struct RemoteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let info: String
    let status: String
    let color: String     // "green" | "red" | "blue" | "secondary"
    let action: String    // "run" | "stop" | "progress"
    let placement: String // "none" | "menu" | "main" (v4.66; defaults "main" for older servers)
}

struct RemoteService: Identifiable, Equatable {
    let id: String
    let label: String
    let ok: Bool
    let warn: Bool
    let url: String?
    let badge: Int?
    let update: Bool
    let streaming: Bool
}

struct RemoteNASUnit: Identifiable, Equatable {
    let id: String
    let label: String
    let state: String   // "green" | "orange" | "red" | "grey" — health only
    var update: Bool = false   // DSM update pending (independent of health)
    let url: String?    // nil for volume lights that have no web UI
    var mountable: Bool = false   // local volume — tapping toggles mount/unmount
}

@MainActor
final class RemoteModel: ObservableObject {
    static let logChoices: [(id: String, label: String, tabLabel: String)] = [
        ("auto",     "Latest",          "Latest"),
        ("charopos", "Charopos Events", "Charopos"),
        ("updater",  "Updater",         "Updater"),
        ("mount",     "Volume Refresh",  "Mounts"),
        ("iperf",     "iperf3 Server",   "iperf3"),
        ("inventory", "NAS Inventory",   "Inventory"),
        ("sonarr",    "Sonarr",          "Sonarr"),
        ("radarr",    "Radarr",          "Radarr"),
        ("lidarr",    "Lidarr",          "Lidarr"),
        ("prowlarr",  "Prowlarr",        "Prowlarr"),
        ("sab",       "SABnzbd",         "SABnzbd"),
        ("jellyfin",    "Jellyfin",    "Jellyfin"),
        ("bazarr",      "Bazarr",      "Bazarr"),
        ("overseerr",   "Overseerr",   "Overseerr"),
        ("tautulli",    "Tautulli",    "Tautulli"),
        ("qbittorrent", "qBittorrent", "qBit"),
    ]
    /// v4.52 service log ids — shown in the picker only when the server reports a
    /// log file present for them (payload `availableLogs`). The rest always show.
    static let newServiceLogIDs: Set<String> = ["jellyfin", "bazarr", "overseerr", "tautulli", "qbittorrent"]

    @Published var items: [RemoteItem] = []
    @Published var services: [RemoteService] = []
    @Published var logTail: [String] = []
    @Published var logTailSource = ""
    @Published var logChoice = "auto" {
        didSet { refreshLog() }
    }
    @Published var anyScriptRunning = false
    @Published var nasUnits: [RemoteNASUnit] = []
    @Published var serverVersion = ""
    @Published var osUpdate = false   // host has a pending macOS update (shown under the version)
    @Published var availableLogs: Set<String> = []   // new-service log ids the server found (payload)
    @Published var connected = false
    @Published var lastError = ""
    @Published var downloadingUpdate = false
    /// Set when a self-update was refused for being off-tailnet; surfaced as an
    /// alert so the refusal is explained rather than looking like a dead button.
    @Published var updateBlockedReason: String?

    var updateAvailable: Bool { connected && !serverVersion.isEmpty && Self.isNewer(serverVersion, than: appVersion) }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let ap = a.split(separator: ".").compactMap { Int($0) }
        let bp = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(ap.count, bp.count) {
            let av = i < ap.count ? ap[i] : 0
            let bv = i < bp.count ? bp[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private var pollTimer: Timer?
    private var consecutiveErrors = 0
    private var nextPollTime = Date()
    /// Tolerate this many consecutive failed polls before declaring the connection
    /// lost. A single blip (mDNS re-resolution of a `.local` host, a dropped/slow
    /// poll, the server momentarily busy) shouldn't flap the UI back to the Connect
    /// screen — only a sustained outage (~grace × 2s poll interval) should.
    private static let disconnectGrace = 3
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        return URLSession(configuration: cfg)
    }()

    // Persisted connection settings
    var host: String {
        // Empty default: a fresh install starts unconfigured (polling is guarded on
        // !host.isEmpty) and the user enters their server in Settings.
        get { UserDefaults.standard.string(forKey: "host") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "host") }
    }
    var token: String {
        get { UserDefaults.standard.string(forKey: "token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "token") }
    }
    let port = 8787

    func startPolling() {
        guard pollTimer == nil else { return }
        refresh()
        refreshLog()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.refreshLog()
            }
        }
    }

    private func request(_ method: String, _ path: String) -> URLRequest? {
        guard !host.isEmpty,
              let url = URL(string: "http://\(host):\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Token")
        return req
    }

    func refresh() {
        guard Date() >= nextPollTime else { return }
        guard let req = request("GET", "/status") else { return }
        session.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.handlePollFailure(error.localizedDescription)
                    return
                }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.handlePollFailure((resp as? HTTPURLResponse)?.statusCode == 401
                        ? "Wrong token" : "Bad response from server")
                    return
                }
                self.consecutiveErrors = 0
                self.nextPollTime = Date()
                self.connected = true
                self.lastError = ""
                self.anyScriptRunning = json["anyScriptRunning"] as? Bool ?? false
                self.items = (json["items"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let id = d["id"] as? String,
                          let title = d["title"] as? String else { return nil }
                    return RemoteItem(id: id,
                                      title: title,
                                      info: d["info"] as? String ?? "",
                                      status: d["status"] as? String ?? "",
                                      color: d["color"] as? String ?? "secondary",
                                      action: d["action"] as? String ?? "run",
                                      placement: d["placement"] as? String ?? "main")
                }
                self.services = (json["services"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let id = d["id"] as? String,
                          let label = d["label"] as? String else { return nil }
                    return RemoteService(id: id, label: label,
                                         ok: d["ok"] as? Bool ?? false,
                                         warn: d["warn"] as? Bool ?? false,
                                         url: d["url"] as? String,
                                         badge: d["badge"] as? Int,
                                         update: d["update"] as? Bool ?? false,
                                         streaming: d["streaming"] as? Bool ?? false)
                }
                self.nasUnits = (json["nasUnits"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let id    = d["id"]    as? String,
                          let label = d["label"] as? String else { return nil }
                    return RemoteNASUnit(id: id, label: label,
                                         state: d["state"] as? String ?? "red",
                                         update: d["update"] as? Bool ?? false,
                                         url: d["url"] as? String,
                                         mountable: d["mountable"] as? Bool ?? false)
                }
                self.serverVersion = json["version"] as? String ?? ""
                self.osUpdate = json["osUpdate"] as? Bool ?? false
                self.availableLogs = Set((json["availableLogs"] as? [String]) ?? [])
                // If the selected new-service log tab vanished (service disabled or log
                // gone), fall back to Latest so the picker doesn't show a blank selection.
                if RemoteModel.newServiceLogIDs.contains(self.logChoice),
                   !self.availableLogs.contains(self.logChoice) {
                    self.logChoice = "auto"
                }
            }
        }.resume()
    }

    /// Force an immediate reconnect, clearing any backoff — used by the manual
    /// "Connect" button so a retry isn't swallowed by an in-progress backoff delay.
    func reconnect() {
        consecutiveErrors = 0
        nextPollTime = Date()
        refresh()
        refreshLog()
    }

    /// A poll failed. Tolerate brief blips: keep the last-known connected state and
    /// retry on the normal cadence until `disconnectGrace` consecutive failures, then
    /// declare the connection lost and back off so we don't hammer a down server.
    private func handlePollFailure(_ message: String) {
        lastError = message
        consecutiveErrors += 1
        guard consecutiveErrors >= Self.disconnectGrace else {
            nextPollTime = Date()   // still within grace — retry next tick (no flap, no backoff)
            return
        }
        connected = false
        let n = consecutiveErrors - Self.disconnectGrace + 1   // backoff counts from the disconnect
        nextPollTime = Date().addingTimeInterval(min(2.0 * pow(2.0, Double(n - 1)), 30.0))
    }

    func refreshLog() {
        guard connected, let req = request("GET", "/log/\(logChoice)") else { return }
        session.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self = self, error == nil,
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let lines = json["lines"] as? [String] ?? []
                let source = json["source"] as? String ?? ""
                if lines != self.logTail { self.logTail = lines }
                if source != self.logTailSource { self.logTailSource = source }
            }
        }.resume()
    }

    func send(_ path: String) {
        guard let req = request("POST", path) else { return }
        session.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }.resume()
    }

    func downloadUpdate() {
        guard !downloadingUpdate else { return }
        downloadingUpdate = true
        let hostCopy = host, tokenCopy = token
        guard let url = URL(string: "http://\(hostCopy):\(port)/update/remote-app") else {
            downloadingUpdate = false; return
        }
        // This replaces our own app bundle with whatever the server sends, and
        // under ad-hoc signing there's no signature to check it against. The
        // transport is therefore the only thing standing between an update and
        // arbitrary code execution — so allow it only over the tailnet, where
        // WireGuard has already authenticated and encrypted the connection.
        // Over a plain LAN the same request is trivially spoofable.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard Self.isTailnetHost(hostCopy) else {
                DispatchQueue.main.async {
                    self?.downloadingUpdate = false
                    self?.updateBlockedReason =
                        "Updating over the network is only allowed when you're connected to the server through Tailscale, because the update isn't signed and a plain LAN connection can be impersonated. Connect via the server's Tailscale address, or rebuild Charopos Remote from source."
                }
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.setValue(tokenCopy, forHTTPHeaderField: "X-Token")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                guard let data, error == nil else {
                    DispatchQueue.main.async { self?.downloadingUpdate = false }
                    return
                }
                let ok = RemoteModel.applyUpdate(zip: data)
                DispatchQueue.main.async {
                    if ok { NSApp.terminate(nil) } else { self?.downloadingUpdate = false }
                }
            }.resume()
        }
    }

    /// True when `host` resolves into Tailscale's CGNAT range, 100.64.0.0/10.
    /// Resolving rather than string-matching so MagicDNS names work too.
    /// Blocking — call off the main thread.
    private nonisolated static func isTailnetHost(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return false }
        defer { freeaddrinfo(res) }
        var cur = res
        while let node = cur {
            if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                if (UInt32(bigEndian: raw) & 0xFFC0_0000) == 0x6440_0000 { return true }
            }
            cur = node.pointee.ai_next
        }
        return false
    }

    private nonisolated static func applyUpdate(zip: Data) -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let zipURL = tmp.appendingPathComponent("charopos-remote-update.zip")
        let extractDir = tmp.appendingPathComponent("charopos-update-extract")
        do {
            try zip.write(to: zipURL)
            try? FileManager.default.removeItem(at: extractDir)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch { return false }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        guard (try? ditto.run()) != nil else { return false }
        ditto.waitUntilExit()
        let newApp = extractDir.appendingPathComponent("Charopos Remote.app")
        let targetApp = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Charopos Remote.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { return false }
        let script = """
        sleep 1
        rm -rf '\(targetApp.path)'
        cp -R '\(newApp.path)' '\(targetApp.path)'
        open '\(targetApp.path)'
        """
        let scriptURL = tmp.appendingPathComponent("charopos-update.sh")
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil
        else { return false }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup /bin/sh '\(scriptURL.path)' >/dev/null 2>&1 &"]
        guard (try? launcher.run()) != nil else { return false }
        launcher.waitUntilExit()
        return true
    }
}

// MARK: - UI

private struct RemoteUpdateAction: Identifiable {
    let id: String
    let label: String
    let url: String?
    let runPath: String
    let singleRunPath: String?  // non-nil for NAS updates; triggers 4-button dialog
}

/// Inline wrapping layout (mirrors the server app's): children flow and wrap,
/// each sized to its content. Used for the drive lights.
///
/// `justified`: when true, each line's items are spread so the line's gaps grow
/// to fill the full available width — matching the web view's CSS
/// `justify-content: space-between`. `spacing` is always the FLOOR gap;
/// justification only adds extra on top. A single-item line is never stretched.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4
    var justified: Bool = false

    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> [[(size: CGSize, index: Int)]] {
        var result: [[(size: CGSize, index: Int)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                result.append([])
                x = 0
            }
            result[result.count - 1].append((s, i))
            x += s.width + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .greatestFiniteMagnitude
        let ls = lines(subviews, maxWidth: maxW)
        var y: CGFloat = 0, widest: CGFloat = 0
        for line in ls where !line.isEmpty {
            let lineW = line.reduce(CGFloat(0)) { $0 + $1.size.width } + CGFloat(line.count - 1) * spacing
            widest = max(widest, lineW)
            y += (line.map { $0.size.height }.max() ?? 0) + lineSpacing
        }
        if !ls.isEmpty { y -= lineSpacing }
        return CGSize(width: min(maxW, widest), height: max(0, y))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let ls = lines(subviews, maxWidth: bounds.width)
        var y: CGFloat = bounds.minY
        for line in ls where !line.isEmpty {
            let lineH = line.map { $0.size.height }.max() ?? 0
            let gapCount = line.count - 1
            var gap = spacing
            if justified && gapCount > 0 {
                let contentW = line.reduce(CGFloat(0)) { $0 + $1.size.width }
                let extra = max(0, bounds.width - (contentW + CGFloat(gapCount) * spacing))
                gap = spacing + extra / CGFloat(gapCount)
            }
            var x = bounds.minX
            for (size, index) in line {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            y += lineH + lineSpacing
        }
    }
}

struct RemoteContentView: View {
    @EnvironmentObject var model: RemoteModel
    @State private var hostField = ""
    @State private var tokenField = ""
    @State private var showSettings = false
    @State private var confirmReboot = false
    @State private var logFilter = ""
    @State private var hoveredLightId: String? = nil
    @State private var pendingUpdate: RemoteUpdateAction? = nil
    @State private var pendingVolume: RemoteNASUnit? = nil
    /// Respect the system Reduce Motion setting (streaming arc renders static).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Copy a URL string to the pasteboard as both URL and plain-text types
    /// (mirrors ContentView.copyToPasteboard on the server).
    static func copyURL(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [s as NSString]
        if let u = URL(string: s), u.scheme != nil { objects.insert(u as NSURL, at: 0) }
        pb.writeObjects(objects)
    }

    static let headerIcon: NSImage = {
        for name in ["AppIconArtwork", "AppIcon"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) { return img }
        }
        return NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        VStack(spacing: 0) {

            // ── Top row: logo+status | lights (connected) ────────────
            HStack(alignment: .top, spacing: 16) {

                // Top-left: logo + connection status
                VStack(spacing: 10) {
                    Image(nsImage: Self.headerIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 160, height: 160)
                        .padding(.bottom, -36)

                    HStack(spacing: 5) {
                        if model.downloadingUpdate {
                            Text("v\(appVersion)")
                                .font(.caption).foregroundColor(.secondary)
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        } else if model.updateAvailable {
                            Button { model.downloadUpdate() } label: {
                                HStack(spacing: 6) {
                                    Text("v\(appVersion)")
                                        .font(.caption).foregroundColor(.secondary)
                                    Text("Update")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Server is v\(model.serverVersion) — click to download and install")
                        } else {
                            Text("v\(appVersion)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if model.connected && model.osUpdate {
                        Text("macOS update available")
                            .font(.caption2).foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                }
                .frame(width: 200)

                // Top-right: lights (grey when disconnected). Gate on services OR NAS
                // units — a server with every service disabled still reports its
                // NAS/volume lights, and hiding those too would blank the grid.
                if (!model.services.isEmpty || !model.nasUnits.isEmpty) && !showSettings {
                    let lightsConnected = model.connected
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.services.isEmpty {
                          HStack(alignment: .center, spacing: 8) {
                            sectionGlyph("square.stack.3d.up")
                            // Fixed 3-column grid, snugged to just fit the widest service
                            // label ("qBittorrent") + its dot + a little cushion — mirrors
                            // the server app (not stretched like the old adaptive grid).
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(90), spacing: 8, alignment: .leading), count: 3),
                                      spacing: 6) {
                                ForEach(model.services) { service in
                                    let b = lightsConnected ? (service.badge ?? 0) : 0
                                    let isAction    = remoteServiceUpdateIsAction(service.id)
                                    let isStreaming  = lightsConnected && service.streaming
                                    let hasUpdate    = lightsConnected && service.update
                                    let dotColor: Color = !lightsConnected ? .secondary
                                        : !service.ok ? .red
                                        : service.warn ? .orange
                                        : b > 0 ? .blue
                                        : .green
                                    let statusWord = !lightsConnected ? "disconnected"
                                        : !service.ok ? "down"
                                        : service.warn ? "warning"
                                        : "running"
                                    let a11y = "\(service.label), \(statusWord)"
                                        + (hasUpdate ? ", update available" : "")
                                        + (b > 0 ? ", \(b) queued" : "")
                                        + (isStreaming ? ", streaming" : "")
                                    let svcURL = service.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                                    // Real Button (mirrors the server app): keyboard-operable + a proper
                                    // VoiceOver control, replacing the old onTapGesture.
                                    let pill = Button {
                                        if hasUpdate && isAction {
                                            pendingUpdate = RemoteUpdateAction(id: service.id, label: service.label, url: service.url, runPath: "/run/\(remoteServiceUpdateScriptId(service.id))", singleRunPath: nil)
                                        } else if let url = svcURL {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                    HStack(spacing: 4) {
                                        if isStreaming {
                                            if reduceMotion {
                                                Circle()
                                                    .trim(from: 0, to: 0.75)
                                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                                                    .frame(width: 8, height: 8)
                                                    .rotationEffect(.degrees(-90))
                                                    .frame(width: 10, height: 10)
                                            } else {
                                            TimelineView(.animation) { tl in
                                                let angle = tl.date.timeIntervalSinceReferenceDate
                                                    .truncatingRemainder(dividingBy: 2) / 2 * 360
                                                Circle()
                                                    .trim(from: 0, to: 0.75)
                                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                                                    .frame(width: 8, height: 8)
                                                    .rotationEffect(.degrees(angle - 90))
                                            }
                                            .frame(width: 10, height: 10)
                                            }
                                        } else if b > 0 && !service.warn {
                                            ZStack {
                                                Circle().fill(hasUpdate ? Color.white.opacity(0.9) : Color.blue)
                                                Text("\(b)")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundColor(hasUpdate ? Color.blue : Color.white)
                                            }
                                            .frame(width: 16, height: 16)
                                        } else {
                                            // Shape varies with state (mirrors the server app) so
                                            // status survives grayscale / color-blind viewing.
                                            ZStack {
                                                if lightsConnected && !service.ok {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundStyle(.red)
                                                } else if lightsConnected && service.warn {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(.orange)
                                                } else {
                                                    Circle().fill(dotColor).frame(width: 8, height: 8)
                                                    if hasUpdate {
                                                        Circle().stroke(Color.white, lineWidth: 1.5)
                                                            .frame(width: 8, height: 8)
                                                    }
                                                }
                                            }
                                            .frame(width: 10, height: 10)
                                        }
                                        Text(service.label)
                                            .font(.system(size: 13))
                                            .foregroundColor(hasUpdate ? .white : .secondary)
                                            .underline(hoveredLightId == service.id)
                                    }
                                    .padding(hasUpdate
                                        ? EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 7)
                                        : EdgeInsets())
                                    .background(
                                        Group {
                                            if hasUpdate {
                                                RoundedRectangle(cornerRadius: 8).fill(Color.blue)
                                            }
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredLightId = $0 ? service.id : nil }
                                    .help(service.url ?? "")
                                    .contextMenu {
                                        if let url = svcURL {
                                            Button("Open \(service.label)") { NSWorkspace.shared.open(url) }
                                            Button("Copy URL") { Self.copyURL(service.url ?? "") }
                                        }
                                        if hasUpdate && isAction {
                                            Button("Run Update\u{2026}") {
                                                pendingUpdate = RemoteUpdateAction(id: service.id, label: service.label, url: service.url, runPath: "/run/\(remoteServiceUpdateScriptId(service.id))", singleRunPath: nil)
                                            }
                                        }
                                    }
                                    .accessibilityLabel(a11y)
                                    if let url = svcURL { pill.draggable(url) } else { pill }
                                }
                            }
                          }
                        }

                        // Hairline between the two pill sections, spanning only the grid
                        // width (286 = 3 fixed 90-wide columns + 2 gaps) — not the glyph column.
                        if !model.services.isEmpty && !model.nasUnits.isEmpty {
                            Divider()
                                .frame(width: 286)   // v4.78: matches the tighter 90-wide columns (was 322)
                                .padding(.leading, 42)   // glyph width (34) + section HStack spacing (8)
                        }

                        if !model.nasUnits.isEmpty {
                          HStack(alignment: .center, spacing: 8) {
                            sectionGlyph("externaldrive")
                            // Drives flow inline, each pill sized to its name (like the web view).
                            FlowLayout(spacing: 16, lineSpacing: 6, justified: true) {
                                ForEach(model.nasUnits) { nas in
                                    let nasHasUpdate = lightsConnected && nas.update
                                    // Dot shows the unit's health color; the blue pill signals the
                                    // update independently, so an update can show on any base color.
                                    let nasColor: Color = lightsConnected ? nasStateColor(nas.state) : .secondary
                                    let nasWord = !lightsConnected ? "disconnected"
                                        : nas.state == "green" ? "online"
                                        : nas.state == "orange" ? "degraded"
                                        : nas.state == "grey" ? (nas.mountable ? "not mounted" : "idle")
                                        : "offline"
                                    let nasURL = nas.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                                    let pill = Button {
                                        if nasHasUpdate {
                                            pendingUpdate = RemoteUpdateAction(id: nas.id, label: nas.label, url: nas.url, runPath: "/run/dsm-update", singleRunPath: "/run/dsm-update-single/\(nas.id)")
                                        } else if nas.mountable, lightsConnected {
                                            pendingVolume = nas
                                        } else if let url = nasURL {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                    HStack(spacing: 4) {
                                        // Same grayscale-safe shape family as the server app.
                                        ZStack {
                                            if lightsConnected && nas.state == "red" {
                                                Image(systemName: "xmark.square.fill")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(.red)
                                            } else if lightsConnected && nas.state == "orange" {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.orange)
                                            } else if lightsConnected && nas.state == "grey" {
                                                RoundedRectangle(cornerRadius: 1)
                                                    .stroke(Color.secondary, lineWidth: 1.2)
                                                    .frame(width: 7, height: 7)
                                            } else {
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(nasColor)
                                                    .frame(width: 8, height: 8)
                                                if nasHasUpdate {
                                                    RoundedRectangle(cornerRadius: 1).stroke(Color.white, lineWidth: 1.5)
                                                        .frame(width: 8, height: 8)
                                                }
                                            }
                                        }
                                        .frame(width: 10, height: 10)
                                        Text(nas.label)
                                            .font(.system(size: 13))
                                            .foregroundColor(nasHasUpdate ? .white : .secondary)
                                            .underline(hoveredLightId == nas.id && (nas.url != nil || (nas.mountable && lightsConnected)))
                                    }
                                    .padding(nasHasUpdate
                                        ? EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 7)
                                        : EdgeInsets())
                                    .background(
                                        Group {
                                            if nasHasUpdate {
                                                RoundedRectangle(cornerRadius: 8).fill(Color.blue)
                                            }
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredLightId = $0 ? nas.id : nil }
                                    .help(nas.url ?? "")
                                    .contextMenu {
                                        if let url = nasURL {
                                            Button("Open \(nas.label)") { NSWorkspace.shared.open(url) }
                                            Button("Copy URL") { Self.copyURL(nas.url ?? "") }
                                        }
                                        if nasHasUpdate {
                                            Button("Update DSM\u{2026}") {
                                                pendingUpdate = RemoteUpdateAction(id: nas.id, label: nas.label, url: nas.url, runPath: "/run/dsm-update", singleRunPath: "/run/dsm-update-single/\(nas.id)")
                                            }
                                        }
                                        if nas.mountable, lightsConnected {
                                            Button(nas.state == "grey" ? "Mount\u{2026}" : "Unmount\u{2026}") { pendingVolume = nas }
                                        }
                                    }
                                    .accessibilityLabel("\(nas.label), \(nasWord)" + (nasHasUpdate ? ", update available" : ""))
                                    if let url = nasURL { pill.draggable(url) } else { pill }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                          }
                        }
                    }
                    .frame(width: 364, height: 160, alignment: .center)
                    .padding(.top, -10)
                    .alert(pendingVolume.map { ($0.state == "grey" ? "Mount " : "Unmount ") + $0.label + "?" } ?? "",
                           isPresented: Binding(get: { pendingVolume != nil },
                                                set: { if !$0 { pendingVolume = nil } }),
                           presenting: pendingVolume) { vol in
                        Button(vol.state == "grey" ? "Mount" : "Unmount") {
                            model.send(vol.state == "grey" ? "/mount/\(vol.id)" : "/unmount/\(vol.id)")
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { vol in
                        Text(vol.state == "grey"
                             ? "Charopos will attempt to mount \(vol.label)."
                             : "Charopos will unmount \(vol.label).")
                    }
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 16)

            if model.connected && !showSettings {
                Divider()

                // ── Bottom row: actions | logs ───────────────────────
                HStack(alignment: .top, spacing: 16) {

                    // Bottom-left: script rows
                    VStack(alignment: .leading, spacing: 14) {
                        let desktopOrder = ["mount", "iperf", "inventory", "kickstart", "kickstart-jellyfin",
                                            "scan-libraries", "clear-transcode", "check-updates",
                                            "pause-downloads", "bazarr-search", "backup", "pihole-gravity", "reboot"]
                    ForEach(model.items
                        .filter { desktopOrder.contains($0.id) && $0.placement == "main" }
                        .sorted { (desktopOrder.firstIndex(of: $0.id) ?? 99) < (desktopOrder.firstIndex(of: $1.id) ?? 99) }
                    ) { item in
                        row(for: item)
                    }

                        if model.anyScriptRunning {
                            Divider()
                            ProgressView()
                                .progressViewStyle(.linear)
                                .padding(.top, 4)
                        }
                    }
                    .frame(width: 240)   // v4.66: Actions +20% (200→240)
                    .fixedSize(horizontal: false, vertical: true)

                    // Bottom-right: log dropdown + filter + scroll
                    VStack(alignment: .leading, spacing: 4) {
                        // Dropdown log selector (like the web). The "Latest" entry names
                        // the log it currently resolves to (e.g. "Latest: sonarr.txt").
                        Picker("", selection: $model.logChoice) {
                            ForEach(RemoteModel.logChoices.filter {
                                !RemoteModel.newServiceLogIDs.contains($0.id) || model.availableLogs.contains($0.id)
                            }, id: \.id) { choice in
                                Text(choice.id == "auto"
                                     ? (model.logChoice == "auto" ? "Latest: \(model.logTailSource)" : "Latest")
                                     : choice.tabLabel)
                                    .tag(choice.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption)
                        .frame(width: 324, alignment: .leading)
                        HStack(spacing: 6) {
                            TextField("Filter…", text: $logFilter)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                let displayedLines = logFilter.isEmpty
                                    ? model.logTail
                                    : model.logTail.filter { $0.localizedCaseInsensitiveContains(logFilter) }
                                Text(displayedLines.isEmpty ? "—" : displayedLines.joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .id("logText")
                            }
                            .frame(height: 170)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                            .onAppear { DispatchQueue.main.async { proxy.scrollTo("logText", anchor: .bottom) } }
                            .onChange(of: model.logTail) { _ in proxy.scrollTo("logText", anchor: .bottom) }
                            .onChange(of: model.logChoice) { _ in proxy.scrollTo("logText", anchor: .bottom) }
                        }
                    }
                    .frame(width: 324)   // v4.66: Logs narrowed 40px to offset the wider Actions column
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            } else {
                // Not connected / settings: show settings below logo+status
                settings
                    .padding(.horizontal, 20)
            }

            // ── Footer: connection status + Edit/Done ────────────────
            Divider()
            HStack(spacing: 6) {
                Spacer()
                Circle()
                    .fill(model.connected ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(model.connected
                     ? "Connected to \(model.host)"
                     : "Not connected\(model.lastError.isEmpty ? "" : " — \(model.lastError)")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button(showSettings ? "Done" : "Edit") { showSettings.toggle() }
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

        } // end VStack
        .onAppear {
            hostField = model.host
            tokenField = model.token
            model.startPolling()
        }
        .confirmationDialog("Update Available", isPresented: Binding(
            get: { pendingUpdate != nil },
            set: { if !$0 { pendingUpdate = nil } }
        ), presenting: pendingUpdate) { action in
            if let singlePath = action.singleRunPath {
                Button("Update All DSMs") { model.send(action.runPath) }
                Button("Update \(action.label)") { model.send(singlePath) }
            } else {
                Button("Run Update") { model.send(action.runPath) }
            }
            if let urlStr = action.url, let url = URL(string: urlStr) {
                Button("Open \(action.label)") { NSWorkspace.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("\(action.label) has an update available.")
        }
        .alert("Can't update over this connection", isPresented: Binding(
            get: { model.updateBlockedReason != nil },
            set: { if !$0 { model.updateBlockedReason = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.updateBlockedReason ?? "")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server connection")
                .font(.headline)
            TextField("Server address (e.g. MyMac.local)", text: $hostField)
                .textFieldStyle(.roundedBorder)
            TextField("Token (from launcher-remote-token.txt)", text: $tokenField)
                .textFieldStyle(.roundedBorder)
            Button("Connect") {
                model.host = hostField.trimmingCharacters(in: .whitespaces)
                model.token = tokenField.trimmingCharacters(in: .whitespaces)
                model.reconnect()
            }
            .controlSize(.large)
        }
    }

    /// A round, icon-only action button — circular, no color tint, in a fixed slot.
    @ViewBuilder
    private func actionIconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.bordered)
            // .circle is macOS 14+ (so is .capsule); on Ventura fall back to the
            // rounded rectangle, which macOS 13 does have. Slightly squarer there.
            // Keeps LSMinimumSystemVersion 13.0 honest rather than aspirational.
            .modifier(RoundButtonShape())
            .controlSize(.large)
            .fixedSize()
            .frame(width: 44)   // v4.77: snug slot (was 56) — trims slack right of the round button
            .accessibilityLabel(label)
            .help(label)
    }

    @ViewBuilder
    private func row(for item: RemoteItem) -> some View {
        HStack(spacing: 3.6) {   // v4.78: gap trimmed a further 10% (was 4)
            if item.id == "pause-downloads" && item.action != "progress" {
                // Toggle: both states POST /run (which flips pause). action "stop" = active
                // (tap to pause → pause icon), "run" = paused (tap to resume → play icon).
                let active = (item.action == "stop")
                actionIconButton(active ? "pause.fill" : "play.fill", active ? "Pause" : "Resume") {
                    model.send("/run/\(item.id)")
                }
            } else {
            switch item.action {
            case "stop":
                actionIconButton("stop.fill", "Stop") { model.send("/stop/\(item.id)") }
            case "force":
                Button("Force") { model.send("/run/reboot-force") }
                    .controlSize(.large)
                    .frame(width: 56)
                    .tint(.red)
            case "progress":
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44)   // match the icon slot so titles don't shift when running
            default:
                if item.id == "reboot" {
                    actionIconButton("play.fill", "Reboot") { confirmReboot = true }
                        .alert("Reboot the server?", isPresented: $confirmReboot) {
                            Button("Reboot", role: .destructive) {
                                model.send("/run/reboot")
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                } else {
                    actionIconButton("play.fill", "Run") { model.send("/run/\(item.id)") }
                }
            }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.status)
                    .font(.caption)
                    .foregroundColor(color(item.color))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "red":   return .red
        case "blue":  return .blue
        default:      return .secondary
        }
    }

    private func remoteServiceUpdateIsAction(_ id: String) -> Bool {
        switch id {
        case "sonarr", "radarr", "lidarr", "prowlarr", "sab",
             "cloudkey", "plex", "pihole": return true
        default: return false
        }
    }

    /// Maps a service id to the POST /run/<path> that triggers its update.
    private func remoteServiceUpdateScriptId(_ id: String) -> String {
        switch id {
        case "sonarr", "radarr", "lidarr", "prowlarr": return "arr"
        case "sab":      return "sab-update"
        case "cloudkey": return "cloudkey-update"
        case "plex":     return "plex-update"
        case "pihole":   return "pihole-update"
        default: return id
        }
    }

    private func nasStateColor(_ state: String) -> Color {
        switch state {
        case "green":  return .green
        case "orange": return .orange
        case "grey":   return .secondary   // idle local volume (unmounted) — not a fault
        default:       return .red
        }
    }

    /// Faint leading glyph marking a status-grid section (globe = services,
    /// external drive = storage) — mirrors the server app. Decorative; tertiary
    /// grey in a fixed gutter so the two sections share a left rail. VoiceOver-hidden.
    @ViewBuilder
    private func sectionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .frame(width: 34)
            .accessibilityHidden(true)
    }

}


// MARK: - Help window
//
// Lighter than the server app's Help (no local Settings/Storage/Services to
// document — those live on the server). Its "Actions" descriptions come from
// the live payload (`model.items[].info`, the same text the old per-row (i)
// popover showed) rather than a duplicated static copy, so they can never
// drift from what the server actually sends.

private struct RemoteHelpTopic: Identifiable {
    let id: String
    let section: String
    let title: String
    let symbol: String
    let body: String
}

private struct RemoteHelpView: View {
    @ObservedObject var model: RemoteModel
    @State private var selection: String?

    private var staticTopics: [RemoteHelpTopic] {
        [
            RemoteHelpTopic(id: "connecting", section: "Getting Started", title: "Connecting to a Server", symbol: "antenna.radiowaves.left.and.right",
                body: "Charopos Remote polls a Charopos server over your network. In Settings, enter the server's **address** (its hostname or IP — e.g. `MyMac.local`) and the **token** shown under the version number (top-left) of the server's main window (click its \"token: click to copy\" line to copy the current value).\n\nThe server must have **Remote Access** turned on (Settings → Services → Integrations → Remote Access on the server) — it's off by default on a fresh install, so a server you just set up may need that flipped on first."),
            RemoteHelpTopic(id: "status-grid", section: "Getting Started", title: "Reading the Status Grid", symbol: "square.stack.3d.up",
                body: "Services show as circular dots, storage (NAS/volumes) as square dots — this mirrors the server app exactly, since both read the same status payload.\n\n**Green** = healthy, **orange** = warning, **red** = down, **grey** = idle/not yet checked. Shape carries the same information as color (triangle = warning, ✕ = down, hollow = idle), so status is never color-only. **Blue** means an update is available or a queue is active, independent of health. A spinning green arc means that service (Plex or Jellyfin) is actively streaming."),
            RemoteHelpTopic(id: "troubleshooting", section: "Troubleshooting", title: "Can't Connect", symbol: "wifi.exclamationmark",
                body: "Confirm the server has **Remote Access** turned on — Remote can't reach a loopback-only server. Confirm the **token** matches exactly what the server's main window currently shows (tokens don't expire, but a re-copy rules out a typo). If the hostname doesn't resolve, try the server's IP address or Tailscale address instead."),
        ]
    }

    private var actionsTopics: [RemoteHelpTopic] {
        model.items.map {
            RemoteHelpTopic(id: "action-\($0.id)", section: "Actions", title: $0.title, symbol: "bolt", body: $0.info)
        }
    }

    private var topics: [RemoteHelpTopic] { staticTopics + actionsTopics }
    private static let sectionOrder = ["Getting Started", "Actions", "Troubleshooting"]

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Self.sectionOrder, id: \.self) { section in
                    let sectionTopics = topics.filter { $0.section == section }
                    if !sectionTopics.isEmpty {
                        Section(section) {
                            ForEach(sectionTopics) { topic in
                                Label(topic.title, systemImage: topic.symbol).tag(topic.id).lineLimit(1)
                            }
                        }
                    } else if section == "Actions" {
                        Section(section) {
                            Text("Connect to a server to see action descriptions here.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 240)

            Divider()

            ScrollView {
                if let topic = topics.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: topic.symbol).font(.title2).foregroundStyle(.tint).frame(width: 28)
                            Text(topic.title).font(.title2).fontWeight(.semibold)
                        }
                        Text(LocalizedStringKey(topic.body))
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a topic").foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 480)
        .onAppear { if selection == nil { selection = topics.first?.id } }
    }
}

// MARK: - About window

struct RemoteAboutView: View {
    let model: RemoteModel
    @State private var tokenCopied = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: RemoteContentView.headerIcon)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            Text("Charopos Remote")
                .font(.title2).fontWeight(.semibold)
            Text("v\(appVersion)")
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("A companion to Charopos that shows live server status and provides remote control over the local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            if !model.host.isEmpty {
                Text("\(model.host):\(String(format: "%d", model.port))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.token.isEmpty {
                Text(tokenCopied ? "Copied!" : "token: click to copy")
                    .font(.caption2)
                    .foregroundStyle(tokenCopied ? Color.green : Color.secondary)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.token, forType: .string)
                        tokenCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                    }
                    .help("Click to copy token")
            }
            Divider().padding(.vertical, 4)
            Text("© Jesse Holden \(String(format: "%d", Calendar.current.component(.year, from: Date())))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 300)
    }
}

// MARK: - App

@MainActor
final class RemoteAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = RemoteModel()
    private var statusItem: NSStatusItem?
    private var menuBarCancellable: AnyCancellable?
    private var connectionCancellable: AnyCancellable?
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var openAtLoginItem: NSMenuItem?
    private var showWindowItem: NSMenuItem?
    private var hideDockItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var actionMenuItems: [(NSMenuItem, String)] = []
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var windowVisibleBeforeSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        model.startPolling()
        setupMenuBar()
        // Create main window via NSHostingController so SwiftUI's WindowGroup
        // cannot spawn a blank duplicate when the menubar icon is clicked.
        let controller = NSHostingController(
            rootView: RemoteContentView().environmentObject(model))
        // Pin the window to the content's natural size ONCE and never auto-resize.
        // Content-driven sizing (.preferredContentSize) recomputes the window frame
        // via Auto Layout inside the display cycle; when polled content churns,
        // NSHostingView re-invalidates constraints mid-cycle → re-entrant
        // _postWindowNeedsUpdateConstraints NSException → SIGABRT on macOS 26.
        // Do NOT restore .preferredContentSize here. (Same fix as the server app.)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "Charopos Remote"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
        window.center()
        if UserDefaults.standard.bool(forKey: "showWindowAtStartup") {
            window.makeKeyAndOrderFront(nil)
        }
        mainWindow = window

        // RemoteContentView changes size with connection state (narrow single column when
        // disconnected, full 4-quadrant once connected). The window can't auto-size —
        // .preferredContentSize crashes on macOS 26 — so re-pin it to fit whenever the
        // connection state flips. (The server's window doesn't need this; ContentView is
        // always the fixed 4-quadrant layout.)
        connectionCancellable = model.$connected
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer so SwiftUI applies the new layout before we measure fittingSize.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.repinMainWindow() }
            }

        // Hide window before sleep so the window server doesn't push a restored
        // frame back to us during wake, which causes re-entrant constraint layout
        // inside NSHostingView and crashes with EXC_CRASH / SIGABRT.
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowVisibleBeforeSleep = self?.mainWindow?.isVisible ?? false
                self?.mainWindow?.orderOut(nil)
                self?.settingsWindow?.orderOut(nil)
                self?.aboutWindow?.orderOut(nil)
                self?.helpWindow?.orderOut(nil)
            }
        }
        wakeObserver = ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.windowVisibleBeforeSleep == true { self?.mainWindow?.makeKeyAndOrderFront(nil) }
            }
        }
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let controller = NSHostingController(rootView: RemoteAboutView(model: model))
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26 (_postWindowNeedsUpdateConstraints), esp. with no other window open
            let w = NSPanel(contentViewController: controller)
            w.title = "About Charopos Remote"
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

    @objc func showHelp() {
        if helpWindow == nil {
            let controller = NSHostingController(rootView: RemoteHelpView(model: model))
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26
            let w = NSWindow(contentViewController: controller)
            w.title = "Charopos Remote Help"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            w.center()
            helpWindow = w
        }
        helpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { mainWindow?.makeKeyAndOrderFront(nil) }
        return false
    }

    /// Resize the main window to fit the current content (used when the connection state
    /// changes the layout). Explicit setContentSize from outside the display cycle — safe,
    /// unlike .preferredContentSize auto-sizing which crashes on macOS 26.
    private func repinMainWindow() {
        guard let window = mainWindow, let view = window.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        let showItem = NSMenuItem(title: "Open Charopos Remote", action: #selector(openWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let aboutItem = NSMenuItem(title: "About Charopos Remote", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        // Self-update entry: shown (in menuWillOpen) only when a newer Remote build
        // is available on the server. No trailing separator so it leaves no gap when hidden.
        let updateItem = NSMenuItem(title: "Update Charopos Remote", action: #selector(updateRemoteApp), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateItem.isHidden = true
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        menu.addItem(.separator())
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
        for (id, title, icon) in actionOrder {
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Charopos Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        updateMenuBarIcon()
        menuBarCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateMenuBarIcon() } }
    }

    func menuWillOpen(_ menu: NSMenu) {
        openAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showWindowItem?.state = UserDefaults.standard.bool(forKey: "showWindowAtStartup") ? .on : .off
        hideDockItem?.state = UserDefaults.standard.bool(forKey: "hideDockIcon") ? .on : .off
        let connected = model.connected
        for (item, id) in actionMenuItems {
            item.isEnabled = connected
            // Hide actions the server didn't send — the payload omits rows the user
            // disabled (or that predate a connection), so the menu mirrors the server.
            item.isHidden = connected && !model.items.contains { $0.id == id }
            if id == "iperf" {
                let running = model.items.first(where: { $0.id == "iperf" })?.action == "stop"
                item.title = running ? "Stop iPerf3" : "Start iPerf3"
            }
            if id == "pause-downloads" {
                // action "stop" = downloads active (offer Pause); else offer Resume.
                let active = model.items.first(where: { $0.id == "pause-downloads" })?.action == "stop"
                item.title = active ? "Pause Downloads" : "Resume Downloads"
            }
        }
        if let u = updateMenuItem {
            u.isHidden = !(model.updateAvailable || model.downloadingUpdate)
            u.isEnabled = !model.downloadingUpdate
            u.title = model.downloadingUpdate ? "Updating Charopos Remote\u{2026}" : "Update Charopos Remote"
        }
    }

    @objc private func updateRemoteApp() { model.downloadUpdate() }

    @objc private func actionItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switch id {
        case "iperf":
            let running = model.items.first(where: { $0.id == "iperf" })?.action == "stop"
            model.send(running ? "/stop/iperf" : "/run/iperf")
        case "reboot":
            let alert = NSAlert()
            alert.messageText = "Reboot the server?"
            alert.informativeText = "Force Reboot skips save dialogs and force-quits any app blocking shutdown. Unsaved work in other apps will be lost."
            alert.addButton(withTitle: "Reboot")
            alert.addButton(withTitle: "Force Reboot")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { model.send("/run/reboot") }
            else if response == .alertSecondButtonReturn { model.send("/run/reboot-force") }
        default:
            model.send("/run/\(id)")
        }
    }

    @objc private func toggleOpenAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func toggleShowWindowAtStartup() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "showWindowAtStartup"), forKey: "showWindowAtStartup")
    }

    @objc private func toggleHideDockIcon() {
        let d = UserDefaults.standard
        let hide = !d.bool(forKey: "hideDockIcon")
        d.set(hide, forKey: "hideDockIcon")
        NSApplication.shared.setActivationPolicy(hide ? .accessory : .regular)
    }

    @objc private func openWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: RemotePreferencesView())
            controller.sizingOptions = []   // NOT .preferredContentSize — content-sized NSHosting windows crash on macOS 26
            let w = NSPanel(contentViewController: controller)
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            controller.view.layoutSubtreeIfNeeded()
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { w.setContentSize(fitting) }
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMenuBarIcon() {
        statusItem?.button?.image = dotImage(name: overallIconName(model))
    }

    private func overallIconName(_ model: RemoteModel) -> String {
        guard model.connected else { return "grey" }

        let anyRed = model.services.contains { !$0.ok }
            || model.nasUnits.contains { $0.state == "red" }
        if anyRed { return "red" }

        let anyOrange = model.services.contains { $0.warn }
            || model.nasUnits.contains { $0.state == "orange" }
        if anyOrange { return "orange" }

        let anyBlue = model.services.contains { ($0.badge ?? 0) > 0 || $0.update }
            || model.nasUnits.contains { $0.update }
            || model.updateAvailable
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
struct CharoposRemoteApp: App {
    @NSApplicationDelegateAdaptor(RemoteAppDelegate.self) var appDelegate

    var body: some Scene {
        // Window lifecycle is managed by RemoteAppDelegate via NSHostingController.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings\u{2026}") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .appInfo) {
                    Button("About Charopos Remote") { appDelegate.showAbout() }
                }
                CommandGroup(replacing: .help) {
                    Button("Charopos Remote Help") { appDelegate.showHelp() }
                        .keyboardShortcut("?", modifiers: .command)
                }
            }
    }
}

// MARK: - Preferences

private struct RemotePreferencesView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Display Options")
                .font(.headline)
            Text("“Show Window at Startup” and “Hide Dock Icon” are now in the menu-bar icon’s menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
        .padding(24)
    }
}

/// Circular border shape where the OS has it (macOS 14+), rounded-rect on Ventura.
/// Isolated in a ViewModifier because `.buttonBorderShape` returns a different
/// concrete type per branch, which an inline `if #available` in a modifier chain
/// can't express.
private struct RoundButtonShape: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.buttonBorderShape(.circle)
        } else {
            content.buttonBorderShape(.roundedRectangle)
        }
    }
}
