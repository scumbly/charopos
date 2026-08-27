import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement

// MARK: - UI

private struct ConfirmAction: Identifiable {
    enum Kind { case service, nas, localVolume }
    let id: String
    let label: String
    let kind: Kind
    var url: String? = nil    // service web URL, when available — offered as "Open URL"
    var mounted: Bool = false // local volume: true if currently mounted (→ Unmount, else Mount)

    var alertTitle: String {
        switch kind {
        case .service:     return "\(label) is unreachable"
        case .nas:         return "Remount \(label)?"
        case .localVolume: return mounted ? "Unmount \(label)?" : "Mount \(label)?"
        }
    }
    var alertMessage: String {
        switch kind {
        case .service:
            return url == nil
                ? "Charopos will attempt to restart \(label). The result will be written to the Charopos log."
                : "Open \(label)’s web interface, or have Charopos attempt to restart it (result written to the Charopos log)."
        case .nas:         return "Charopos will run the NAS Refresh script to remount \(label). The result will be written to the Charopos log."
        case .localVolume: return mounted
            ? "Charopos will unmount \(label)."
            : "Charopos will attempt to mount \(label). The result will be written to the Charopos log."
        }
    }
    var buttonLabel: String {
        switch kind {
        case .service:     return "Relaunch"
        case .nas:         return "Remount"
        case .localVolume: return mounted ? "Unmount" : "Mount"
        }
    }
}

private struct UpdateAction: Identifiable {
    let id: String
    let label: String
    let url: String?
    let scriptItem: ScriptItem?   // set for DSM (4-button dialog); nil for service updates
    let nasId: String?  // non-nil for NAS updates; triggers 4-button dialog
}


/// Inline wrapping layout: children flow left-to-right and wrap to the next line,
/// each sized to its own content (like the web status grid). Used for the drive
/// lights, whose names vary in length; services keep a fixed-column grid.
///
/// `justified`: when true, each line's items are spread so the line's gaps grow
/// to fill the full available width — matching the web view's CSS
/// `justify-content: space-between` (first pill flush left, last flush right).
/// `spacing` is always the FLOOR gap; justification only ever adds extra space
/// on top of it. A single-item line is never stretched (there's nothing to
/// space "between"), matching flexbox's own behavior.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4
    var justified: Bool = false

    /// Group children into wrapped lines using the floor spacing to decide breaks.
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

struct ContentView: View {
    @EnvironmentObject var runner: Runner
    @State private var confirmReboot = false
    @State private var confirmAction: ConfirmAction? = nil
    @State private var pendingUpdate: UpdateAction? = nil
    @State private var logFilter = ""
    @State private var tokenCopied = false
    @State private var hoveredLightId: String? = nil
    /// Respect the system Reduce Motion setting (streaming arc renders static).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Full-resolution header image: original artwork (transparent bg), falling
    /// back to the app icon PNG, then the system icon.
    static let headerIcon: NSImage = {
        for name in ["AppIconArtwork", "AppIcon"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) { return img }
        }
        return NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        VStack(spacing: 0) {

            // ── Top row: logo | lights ───────────────────────────────
            topRow
            Divider()

            // ── Bottom row: actions | logs ───────────────────────────
            bottomRow
        } // end VStack
        .onAppear {
            runner.autoRunIfJustBooted()
            runner.startPolling()
            runner.startAPI()
        }
        .alert(confirmAction?.alertTitle ?? "", isPresented: Binding(
            get: { confirmAction != nil },
            set: { if !$0 { confirmAction = nil } }
        ), presenting: confirmAction) { action in
            if action.kind == .service, let urlStr = action.url, let url = URL(string: urlStr) {
                Button("Open URL") { NSWorkspace.shared.open(url) }
            }
            Button(action.buttonLabel) { performConfirmed(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.alertMessage)
        }
        .confirmationDialog("Update Available", isPresented: Binding(
            get: { pendingUpdate != nil },
            set: { if !$0 { pendingUpdate = nil } }
        ), presenting: pendingUpdate) { action in
            if let nasId = action.nasId {
                Button("Update All DSMs") { if let item = action.scriptItem { runner.run(item) } }
                Button("Update \(action.label)") { runner.updateSingleNAS(nasId) }
            } else {
                Button("Run Update") { runner.runServiceUpdate(action.id) }
            }
            if let urlStr = action.url, let url = URL(string: urlStr) {
                Button("Open \(action.label)") { NSWorkspace.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("\(action.label) has an update available.")
        }
    }

    @ViewBuilder
    private func row(for item: ScriptItem) -> some View {
        switch item.id {
        case "watch":
            polledRow(item, alive: runner.watcherAlive) { runner.stopWatcher() }
        case "iperf":
            polledRow(item, alive: runner.iperfAlive) { runner.stopIperf() }
        default:
            standardRow(item)
        }
    }

    /// A round, icon-only action button. Circular (not pill), no color tint — sits in a
    /// fixed-width slot so every row's title column still lines up.
    @ViewBuilder
    private func actionIconButton(_ symbol: String, _ label: String,
                                  disabled: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.bordered)
            // .circle is macOS 14+ (so is .capsule); on Ventura fall back to the
            // rounded rectangle, which macOS 13 does have. Slightly squarer there.
            // Keeps LSMinimumSystemVersion 13.0 honest rather than aspirational.
            .modifier(RoundButtonShape())
            .controlSize(.large)
            .fixedSize()
            .frame(width: 44)   // v4.77: snug slot (was 56) — trims slack right of the round button
            .disabled(disabled)
            .accessibilityLabel(label)
            .help(label)
    }

    /// Row whose status reflects a live system process (polled via pgrep),
    /// since these can be started/stopped outside this app.
    @ViewBuilder
    private func polledRow(_ item: ScriptItem, alive: Bool,
                           stop: @escaping () -> Void) -> some View {
        HStack(spacing: 3.6) {   // v4.78: gap trimmed a further 10% (was 4)
            if alive {
                actionIconButton("stop.fill", "Stop", action: stop)
            } else {
                actionIconButton("play.fill", "Run") { runner.run(item) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(alive ? "Running" : "Not running")
                    .font(.caption)
                    .foregroundColor(alive ? .green : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func standardRow(_ item: ScriptItem) -> some View {
        let state = runner.state(of: item)
        let status = runner.displayStatus(for: item)
        HStack(spacing: 3.6) {   // v4.78: gap trimmed a further 10% (was 4)
            if status.action == "force" {
                // Force Reboot stays a labeled (red) button — an exceptional, destructive state.
                Button("Force") { runner.rebootServer(force: true) }
                    .controlSize(.large)
                    .frame(width: 56)
                    .tint(.red)
            } else if status.action == "progress" {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44)   // match the icon slot so titles don't shift when running
            } else if item.id == "pause-downloads" {
                // Toggle icon reflects state; run(item) flips it. No color tint.
                let paused = runner.downloadsPaused
                actionIconButton(paused ? "play.fill" : "pause.fill", paused ? "Resume" : "Pause") {
                    runner.run(item)
                }
            } else if item.id == "reboot" {
                actionIconButton("play.fill", "Reboot") { confirmReboot = true }
                    .alert("Reboot the server?", isPresented: $confirmReboot) {
                        Button("Reboot", role: .destructive) { runner.rebootServer() }
                        Button("Force Reboot", role: .destructive) { runner.rebootServer(force: true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Force Reboot skips save dialogs and force-quits any app blocking shutdown. Unsaved work in other apps will be lost.")
                    }
            } else {
                actionIconButton("play.fill", "Run", disabled: state == .running) { runner.run(item) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(status.text)
                    .font(.caption)
                    .foregroundColor(color(named: status.color))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(named name: String) -> Color {
        switch name {
        case "green": return .green
        case "red":   return .red
        case "blue":  return .blue
        default:      return .secondary
        }
    }

    private func serviceHasUpdate(_ id: String) -> Bool {
        switch id {
        case "sonarr", "radarr", "lidarr", "prowlarr": return runner.arrUpdatesAvailable.contains(id)
        case "sab":      return runner.sabUpdateAvailable
        case "cloudkey": return runner.cloudKeyUpdateAvailable
        case "plex":     return runner.plexUpdateAvailable
        case "pihole":   return runner.piholeUpdateAvailable
        default:         return false
        }
    }

    private func serviceUpdateIsAction(_ id: String) -> Bool {
        switch id {
        case "sonarr", "radarr", "lidarr", "prowlarr", "sab",
             "cloudkey", "plex", "pihole": return true
        default: return false
        }
    }

    /// Faint leading glyph marking a status-grid section (globe = services,
    /// external drive = storage). Decorative and Apple-styled: an SF Symbol in
    /// tertiary grey, in a fixed-width gutter so both sections share a left rail.
    /// Hidden from VoiceOver — the pills already carry the labels.
    @ViewBuilder
    private func sectionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .frame(width: 34)
            .accessibilityHidden(true)
    }

    private func nasStateColor(_ state: String?) -> Color {
        switch state {
        case "green":  return .green
        case "orange": return .orange
        case "blue":   return .blue
        case "grey":   return .secondary   // idle local volume (unmounted) — not a fault
        default:       return .red
        }
    }

    /// Status dot for the square family (NAS units, local volumes). Shape varies
    /// with state so status survives grayscale / color-blind viewing: healthy is
    /// the calm filled square, warning a triangle, offline an x-in-square, and
    /// idle a hollow square. The white update ring only pairs with the square
    /// (degraded states already flag updates via the blue pill background).
    @ViewBuilder
    private func squareStatusDot(state: String, hasUpdate: Bool) -> some View {
        ZStack {
            switch state {
            case "red":
                Image(systemName: "xmark.square.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
            case "orange":
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            case "grey":
                RoundedRectangle(cornerRadius: 1)
                    .stroke(Color.secondary, lineWidth: 1.2)
                    .frame(width: 7, height: 7)
            default:
                RoundedRectangle(cornerRadius: 1)
                    .fill(nasStateColor(state))
                    .frame(width: 8, height: 8)
                if hasUpdate {
                    RoundedRectangle(cornerRadius: 1).stroke(Color.white, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 10, height: 10)
    }

    /// Copy a string to the pasteboard; when it's a valid URL, also write a URL
    /// representation so URL-aware targets (browsers, Finder) get the richer type.
    static func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [s as NSString]
        if let u = URL(string: s), u.scheme != nil { objects.insert(u as NSURL, at: 0) }
        pb.writeObjects(objects)
    }

    /// Title for one entry in the log-source picker. The "Latest" tab names the
    /// source it's currently following, but only while it's the selection.
    /// A plain function rather than an inline ternary: nested string
    /// interpolation inside a ViewBuilder is expensive to type-check.
    private func logTabLabel(_ choice: LogChoice) -> String {
        guard choice == .auto else { return choice.tabLabel }
        return runner.logChoice == .auto ? "Latest: \(runner.logTailSource)" : "Latest"
    }

    // The window is one VStack of two rows. They live in their own properties
    // rather than inline: as a single expression `body` exceeded the type
    // checker's budget when compiled against the macOS 13 SDK surface, where
    // SwiftUI's availability-gated overloads widen the search.
    @ViewBuilder
    private var topRow: some View {
            HStack(alignment: .top, spacing: 16) {

                // Top-left: logo + version, centered in the (narrowed) quadrant.
                VStack(spacing: 4) {
                    Image(nsImage: Self.headerIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 160, height: 160)
                        .padding(.bottom, -36)
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if runner.pendingOSUpdates {
                        Text("macOS update available")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    // Port + API token, centered under the version (moved here from the
                    // window's bottom edge in v4.72).
                    if let api = runner.api {
                        if runner.apiPortConflict {
                            Label("Port \(String(APIServer.port)) in use",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(api.token, forType: .string)
                                tokenCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                            } label: {
                                Text(tokenCopied
                                     ? "Copied!"
                                     : "Port \(String(APIServer.port)) — token: click to copy")
                                    .font(.caption2)
                                    .foregroundColor(tokenCopied ? .green : .secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy API access token")
                        }
                    }
                }
                .frame(width: 200)

                // Top-right: service + NAS/volume lights
                VStack(alignment: .leading, spacing: 8) {
                    // Friendly empty state instead of a blank quadrant (fresh install
                    // before onboarding adds anything).
                    if runner.enabledServices.isEmpty && runner.nasUnits.isEmpty && runner.localVolumes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing monitored yet")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("Add services and storage in Settings, or run Setup from the menu-bar icon.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !runner.enabledServices.isEmpty {
                      HStack(alignment: .center, spacing: 8) {
                        sectionGlyph("square.stack.3d.up")
                        // Fixed 3-column grid, snugged to just fit the widest service
                        // label ("qBittorrent") + its dot + a little cushion — not
                        // stretched to fill the quadrant like the old adaptive grid.
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(90), spacing: 8, alignment: .leading), count: 3),
                              spacing: 6) {
                        ForEach(runner.enabledServices, id: \.id) { service in
                            let b = runner.badge(for: service.id) ?? 0
                            let hasUpdate   = serviceHasUpdate(service.id)
                            let isAction    = serviceUpdateIsAction(service.id)
                            let isStreaming = (service.id == "plex" && runner.plexStreamCount != nil)
                                || (service.id == "jellyfin" && runner.jellyfinStreamCount != nil)
                            let dotColor: Color = runner.serviceHealth[service.id] == nil ? .secondary
                                : runner.serviceHealth[service.id] != true ? .red
                                : runner.serviceWarnings[service.id] == true ? .orange
                                : b > 0 ? .blue
                                : .green
                            let tipURL = service.openURL ?? service.url ?? ""
                            let pillURL = tipURL.isEmpty ? nil : URL(string: tipURL)
                            // Hoisted out of the Button action below: resolving this
                            // coalesce inline pushed the whole builder past the type
                            // checker's budget when targeting macOS 13.
                            let actionURL: String? = service.openURL ?? service.url
                            let statusWord: String = runner.serviceHealth[service.id] == nil ? "not yet checked"
                                : runner.serviceHealth[service.id] != true ? "down"
                                : runner.serviceWarnings[service.id] == true ? "warning"
                                : "running"
                            let a11y = "\(service.label), \(statusWord)"
                                + (hasUpdate ? ", update available" : "")
                                + (b > 0 ? ", \(b) queued" : "")
                                + (isStreaming ? ", streaming" : "")
                            // A real Button (not onTapGesture): keyboard-operable (Tab +
                            // Space/Return) and announced as a control by VoiceOver.
                            let pill = Button {
                                if runner.serviceHealth[service.id] == false {
                                    confirmAction = ConfirmAction(id: service.id, label: service.label, kind: .service, url: actionURL)
                                } else if hasUpdate && isAction {
                                    pendingUpdate = UpdateAction(id: service.id, label: service.label, url: actionURL, scriptItem: nil, nasId: nil)
                                } else if let url = pillURL {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                servicePillLabel(label: service.label, isStreaming: isStreaming, b: b,
                                                 hasUpdate: hasUpdate, dotColor: dotColor,
                                                 warning: runner.serviceWarnings[service.id] == true,
                                                 hovered: hoveredLightId == service.id)
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredLightId = $0 ? service.id : nil }
                            .help(tipURL)
                            .contextMenu {
                                serviceContextMenu(id: service.id, label: service.label,
                                                   url: pillURL, tipURL: tipURL,
                                                   actionURL: actionURL,
                                                   down: runner.serviceHealth[service.id] == false,
                                                   runnableUpdate: hasUpdate && isAction)
                            }
                            .accessibilityLabel(a11y)
                            // Pills represent URLs — allow dragging one into a browser/Finder.
                            if let url = pillURL {
                                pill.draggable(url)
                            } else {
                                pill
                            }
                        }
                    }
                      }
                    }

                    // Hairline between the two pill sections, spanning only the grid
                    // width (322 = 3 fixed columns + 2 gaps) — not the glyph column.
                    if !runner.enabledServices.isEmpty && !(runner.nasUnits.isEmpty && runner.localVolumes.isEmpty) {
                        Divider()
                            .frame(width: 286)   // 3 × 90-wide columns + 2 × 8 gaps (v4.78, was 322)
                            .padding(.leading, 42)   // glyph width (34) + section HStack spacing (8)
                    }

                    if !(runner.nasUnits.isEmpty && runner.localVolumes.isEmpty) {
                      HStack(alignment: .center, spacing: 8) {
                        sectionGlyph("externaldrive")
                        // Drives flow inline, each pill sized to its (variable-length)
                        // name and wrapping at the quadrant edge — like the web view.
                        FlowLayout(spacing: 16, lineSpacing: 6, justified: true) {
                        ForEach(runner.nasUnits, id: \.id) { nas in
                            let nasHasUpdate = runner.nasHasUpdate(for: nas.id)
                            let nasState = runner.nasHealthState(for: nas.id)
                            let nasURL = nas.openURL.isEmpty ? nil : URL(string: nas.openURL)
                            let stateWord = nasState == "green" ? "online"
                                : nasState == "orange" ? "degraded"
                                : nasState == "grey" ? "idle" : "offline"
                            let a11y = "\(nas.label), \(stateWord)" + (nasHasUpdate ? ", update available" : "")
                            let pill = Button {
                                if nasState == "red" {
                                    confirmAction = ConfirmAction(id: nas.id, label: nas.label, kind: .nas)
                                } else if nasHasUpdate,
                                   let item = Runner.items.first(where: { $0.id == "dsm-update" }) {
                                    pendingUpdate = UpdateAction(id: nas.id, label: nas.label, url: nas.openURL, scriptItem: item, nasId: nas.id)
                                } else if let url = nasURL {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                nasPillLabel(label: nas.label, state: nasState,
                                             hasUpdate: nasHasUpdate,
                                             hovered: hoveredLightId == nas.id)
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredLightId = $0 ? nas.id : nil }
                            .help(nas.openURL)
                            .contextMenu {
                                if let url = nasURL {
                                    Button("Open \(nas.label)") { NSWorkspace.shared.open(url) }
                                    Button("Copy URL") { Self.copyToPasteboard(nas.openURL) }
                                }
                                if nasState == "red" {
                                    Button("Remount\u{2026}") {
                                        confirmAction = ConfirmAction(id: nas.id, label: nas.label, kind: .nas)
                                    }
                                }
                                if nasHasUpdate, let item = Runner.items.first(where: { $0.id == "dsm-update" }) {
                                    Button("Update DSM\u{2026}") {
                                        pendingUpdate = UpdateAction(id: nas.id, label: nas.label, url: nas.openURL, scriptItem: item, nasId: nas.id)
                                    }
                                }
                            }
                            .accessibilityLabel(a11y)
                            if let url = nasURL {
                                pill.draggable(url)
                            } else {
                                pill
                            }
                        }
                        ForEach(runner.localVolumes, id: \.id) { vol in
                            // Local volumes are optional: an unknown/unpolled state is
                            // idle "grey", NOT a fault. Match the web/Remote payload's
                            // `?? "grey"` so a nil never falls to nasStateColor's red default.
                            let volState = runner.volumeHealth[vol.id] ?? "grey"
                            let mounted = ["green", "orange"].contains(volState)
                            let stateWord = volState == "green" ? "mounted"
                                : volState == "orange" ? "mounted, above disk threshold"
                                : "not mounted"
                            Button {
                                confirmAction = ConfirmAction(id: vol.id, label: vol.label, kind: .localVolume, mounted: mounted)
                            } label: {
                                HStack(spacing: 4) {
                                    squareStatusDot(state: volState, hasUpdate: false)
                                    Text(vol.label)
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .underline(hoveredLightId == vol.id)   // all volumes are clickable (mount/unmount)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredLightId = $0 ? vol.id : nil }
                            .contextMenu {
                                Button(mounted ? "Unmount\u{2026}" : "Mount\u{2026}") {
                                    confirmAction = ConfirmAction(id: vol.id, label: vol.label, kind: .localVolume, mounted: mounted)
                                }
                            }
                            .accessibilityLabel("\(vol.label), \(stateWord)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                      }
                    }

                    if runner.autoRanAtBoot {
                        Label("Boot detected — auto-ran mount & iperf3.",
                              systemImage: "power")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
                .frame(width: 364, height: 160, alignment: .center)
                .padding(.top, -10)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 16)

    }

    @ViewBuilder
    private var bottomRow: some View {
            HStack(alignment: .top, spacing: 16) {

                // Bottom-left: action rows pinned to the top, Settings pinned to the
                // bottom (its bottom edge lines up with the log viewer's bottom).
                VStack(alignment: .leading, spacing: 14) {
                    let desktopOrder = ["mount", "iperf", "inventory", "kickstart", "kickstart-jellyfin",
                                        "scan-libraries", "clear-transcode", "check-updates",
                                        "pause-downloads", "bazarr-search", "backup", "pihole-gravity", "reboot"]
                    ForEach(Runner.items
                        .filter { desktopOrder.contains($0.id) && runner.showsInMainWindow($0.id) }
                        .sorted { (desktopOrder.firstIndex(of: $0.id) ?? 99) < (desktopOrder.firstIndex(of: $1.id) ?? 99) }
                    ) { item in
                        row(for: item)
                    }

                    if runner.anyScriptRunning {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .padding(.top, 4)
                    }

                    // Settings button removed from the main window (v4.71) — Settings is
                    // still reachable from the menu bar (⌘,) and the menu-bar menu. The
                    // Spacer keeps the action rows pinned to the top of the column.
                    Spacer(minLength: 0)
                }
                .frame(width: 240, alignment: .top)   // v4.66: Actions +20% (200→240)
                .frame(maxHeight: .infinity)

                // Bottom-right: log tabs + filter + scroll
                VStack(alignment: .leading, spacing: 4) {
                    // Dropdown log selector (like the web). The "Latest" entry names the
                    // log it currently resolves to (e.g. "Latest: sonarr.txt").
                    HStack(spacing: 6) {
                        Picker("", selection: $runner.logChoice) {
                            // New-service tabs (Jellyfin/Bazarr/…) appear only when their
                            // log file was found; the rest always show.
                            ForEach(LogChoice.allCases.filter {
                                !$0.isNewServiceLog || runner.availableNewLogs.contains($0.rawValue)
                            }) { choice in
                                Text(logTabLabel(choice))
                                    .tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Logs") { runner.openLogsFolder() }
                            .font(.caption)
                    }
                    TextField("Filter…", text: $logFilter)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(logBodyText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .id("logText")
                        }
                        .frame(height: 204)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .onAppear { proxy.scrollTo("logText", anchor: .bottom) }
                        .onChange(of: runner.logTail) { _ in proxy.scrollTo("logText", anchor: .bottom) }
                    }
                }
                .frame(width: 324)   // v4.66: Logs narrowed 40px to offset the wider Actions column
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

    }

    /// Carry out a confirmed restart/remount. A method rather than an inline
    /// closure so the alert builder stays inside the type-checker budget.
    private func performConfirmed(_ action: ConfirmAction) {
        switch action.kind {
        case .service:
            runner.restartService(action.id, label: action.label)
        case .nas:
            runner.remountNAS(action.id, label: action.label)
        case .localVolume:
            guard let vol = runner.localVolumes.first(where: { $0.id == action.id }) else { return }
            if action.mounted {
                runner.unmountVolume(action.id, label: action.label, mountPoint: vol.mountPoint)
            } else {
                runner.remountVolume(action.id, label: action.label, mountPoint: vol.mountPoint)
            }
        }
    }

    /// The log pane's body: the tail, narrowed by the filter field, joined for
    /// display. A computed property rather than an inline chain — the filter +
    /// ternary + join was one of the expressions that blew the type-checker
    /// budget against the macOS 13 SDK surface.
    private var logBodyText: String {
        let shown = logFilter.isEmpty
            ? runner.logTail
            : runner.logTail.filter { $0.localizedCaseInsensitiveContains(logFilter) }
        return shown.isEmpty ? "—" : shown.joined(separator: "\n")
    }

    /// The service pill's label: glyph + name, wrapped in the blue update pill
    /// when one is pending. Extracted for type-checker budget (see `serviceGlyph`).
    @ViewBuilder
    private func servicePillLabel(label: String, isStreaming: Bool, b: Int,
                                  hasUpdate: Bool, dotColor: Color,
                                  warning: Bool, hovered: Bool) -> some View {
        HStack(spacing: 4) {
            serviceGlyph(isStreaming: isStreaming, b: b, hasUpdate: hasUpdate,
                         dotColor: dotColor, warning: warning)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(hasUpdate ? .white : .secondary)
                .underline(hovered)
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

    /// Right-click menu for a service pill: open/copy its URL, restart it when
    /// it's down, run its updater when one is pending. Extracted from the pill
    /// for type-checker budget (see `serviceGlyph`).
    @ViewBuilder
    private func serviceContextMenu(id: String, label: String, url: URL?, tipURL: String,
                                    actionURL: String?, down: Bool,
                                    runnableUpdate: Bool) -> some View {
        if let url {
            Button("Open \(label)") { NSWorkspace.shared.open(url) }
            Button("Copy URL") { Self.copyToPasteboard(tipURL) }
        }
        if down {
            Button("Restart \(label)\u{2026}") {
                confirmAction = ConfirmAction(id: id, label: label, kind: .service, url: actionURL)
            }
        }
        if runnableUpdate {
            Button("Run Update\u{2026}") {
                pendingUpdate = UpdateAction(id: id, label: label, url: actionURL, scriptItem: nil, nasId: nil)
            }
        }
    }

    /// The NAS/volume pill's label. Square glyph family (vs the services'
    /// circles), with the blue update pill drawn independently of state.
    /// Extracted for the same type-checker-budget reason as `serviceGlyph`.
    @ViewBuilder
    private func nasPillLabel(label: String, state: String,
                              hasUpdate: Bool, hovered: Bool) -> some View {
        HStack(spacing: 4) {
            squareStatusDot(state: state, hasUpdate: hasUpdate)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(hasUpdate ? .white : .secondary)
                .underline(hovered)
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

    /// The pill's leading glyph: streaming arc, queue badge, or status dot.
    /// Extracted from the pill's label because the enclosing builder exceeds the
    /// type checker's budget when compiled against the macOS 13 SDK surface.
    @ViewBuilder
    private func serviceGlyph(isStreaming: Bool, b: Int, hasUpdate: Bool,
                              dotColor: Color, warning: Bool) -> some View {
                if isStreaming {
                    if reduceMotion {
                        // Static ◕ arc — same silhouette, no animation.
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
                } else if b > 0 && !warning {
                    ZStack {
                        Circle().fill(hasUpdate ? Color.white.opacity(0.9) : Color.blue)
                        Text("\(b)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(hasUpdate ? Color.blue : Color.white)
                    }
                    .frame(width: 16, height: 16)
                } else {
                    // Shape varies with state so status survives grayscale /
                    // color-blind viewing: healthy stays the calm dot; warning
                    // is a triangle; down is an x-in-circle.
                    ZStack {
                        if dotColor == .red {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.red)
                        } else if dotColor == .orange {
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
