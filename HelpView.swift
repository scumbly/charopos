import SwiftUI

// MARK: - Help (Help menu → Charopos Help)
//
// A reference window replacing the old per-action (i) popovers, which cramped
// the action rows' status text. Master-detail like Settings: a sidebar of
// topics grouped by section, a detail pane with the topic's content. Body text
// uses SwiftUI's constrained Markdown (bold, inline `code`) via
// Text(LocalizedStringKey:).

struct HelpTopic: Identifiable {
    let id: String
    let section: String
    let title: String
    let symbol: String
    let body: String
}

enum HelpContent {
    /// Section display order — sidebar sections follow this, not first-seen order.
    static let sectionOrder = [
        "Getting Started", "Actions", "Services", "Storage",
        "Notifications", "Remote Access", "Troubleshooting", "About",
    ]

    static let topics: [HelpTopic] = [
        // MARK: Getting Started
        HelpTopic(id: "overview", section: "Getting Started", title: "Welcome to Charopos", symbol: "house",
            body: """
            Charopos watches the services and storage on this Mac and your homelab, and gives you one-tap controls for the maintenance tasks around them — mounting network volumes, restarting the media stack, checking for updates, rebooting the server.

            **Three surfaces, one source of truth.** This desktop app is the primary surface. It also runs a small local web server, so you can open the **web dashboard** from any browser on your network, and there's a companion **Charopos Remote** app for controlling the server from another Mac. All three show the same status grid and the same actions — they just poll the same data.

            **Nothing is monitored until you add it.** A fresh install starts with an empty roster. Add services and storage in **Settings** (⌘,), or run **Setup** again from the menu-bar icon if you skipped onboarding the first time.
            """),
        HelpTopic(id: "status-grid", section: "Getting Started", title: "Reading the Status Grid", symbol: "square.stack.3d.up",
            body: """
            The status grid has two sections: **services** (circular dots) and **storage** — NAS units and local volumes (square dots).

            **Color:**
            - **Green** — healthy / reachable.
            - **Orange** — a warning (e.g. a service reports an issue, or a drive is above its disk-space threshold).
            - **Red** — down / unreachable.
            - **Grey** — idle or not yet checked (an unmounted local volume shows grey, not red — that's expected, not a fault).

            **Shape** carries the same information as color, so status is never color-only: a filled dot is healthy, a **triangle** is a warning, an **✕** is down, and a **hollow** square is idle.

            **Blue** is a separate signal layered on top of health — it means an **update is available**, or (for services with a live count) a **queue is active**: a filled blue circle with a number is a download/request queue; a plain blue pill is an update. A service can be simultaneously orange (warning) and blue (update) — the pill's outline color reflects that.

            **The spinning arc** (green, on Plex or Jellyfin) means that service is actively streaming.

            Click a service or drive pill to open it, or to fix a red one (restart, remount, mount/unmount). Right-click for more options, including **Copy URL**.
            """),
        HelpTopic(id: "menu-bar", section: "Getting Started", title: "The Menu-Bar Icon", symbol: "menubar.rectangle",
            body: """
            Charopos lives in the menu bar. The icon's color mirrors the overall status (green/orange/red/blue), so you can tell at a glance whether anything needs attention without opening the window.

            Click it for a menu with **Open Charopos**, the same **Actions** available in the action rows, **Settings…**, **Run Setup Again…** (re-enter onboarding), and display options (Open at Login, Show Window at Startup, Hide Dock Icon).
            """),

        // MARK: Actions — migrated from the old per-row (i) popovers
        HelpTopic(id: "action-kickstart", section: "Actions", title: "Kickstart Plex", symbol: "bolt",
            body: "Cleanly restarts all media server processes. Sends SIGTERM to Plex Media Server, Radarr, Sonarr, Lidarr, and Prowlarr, giving them up to 20 seconds to shut down gracefully before sending SIGKILL. Once all processes have exited, NAS Refresh runs automatically to remount NAS drives and bring everything back up in order.\n\nUse this when Plex has lost track of its library, media apps are misbehaving, or you need a fresh restart without rebooting the machine."),
        HelpTopic(id: "action-mount", section: "Actions", title: "NAS Refresh", symbol: "arrow.triangle.2.circlepath",
            body: "Remounts every NAS share configured with a Mount Source in Settings → Storage, starts the Ghost Monitor, then launches Plex Media Server, Radarr, Sonarr, Lidarr, Prowlarr, and SABnzbd. Progress is logged to a timestamped file in the app's logs folder.\n\nRuns automatically when the Mac boots or after a successful DSM update. Run it manually if NAS volumes disconnected mid-session, apps crashed, or drives need remounting after a network interruption."),
        HelpTopic(id: "action-watch", section: "Actions", title: "Ghost Monitor", symbol: "eye",
            body: "A persistent background daemon that watches for duplicate or conflicting Synology volume mount points. Duplicate mounts appear when a NAS reconnects while its previous mount is still active — two volumes with the same name, each containing the same media — which causes Plex to report duplicates and can lead to library corruption.\n\nThe watcher detects this condition and sends a macOS notification. It runs continuously until stopped, and is normally started automatically by NAS Refresh. Toggle it in Settings → Notifications → Storage → **Monitor Ghosts**."),
        HelpTopic(id: "action-iperf", section: "Actions", title: "iperf3 Server", symbol: "speedometer",
            body: "Starts an iperf3 network throughput server in the background, so it keeps running after the action completes. From any device on your network, measure real-world throughput to this Mac with:\n\n`iperf3 -c <this Mac's IP>`\n\nUseful for diagnosing slow NAS transfers, Wi-Fi bottlenecks, or comparing wired vs. wireless performance. Press **Stop** to terminate it."),
        HelpTopic(id: "action-inventory", section: "Actions", title: "Run Inventory", symbol: "list.bullet.rectangle",
            body: "Writes a text log listing every file on every mounted NAS to the app's logs folder. If enabled in Settings → Services → Integrations → Synology (\"Log inventory every N days\"), it also runs automatically on that schedule. Keeps the 10 most recent logs and prunes older ones. Large NAS shares can make a big log and take a while."),
        HelpTopic(id: "action-reboot", section: "Actions", title: "Reboot Server", symbol: "power",
            body: "Asks every open app to quit — the media apps it controls, plus any window app open in the Dock — then, once they're all closed, sends a system restart and quits itself last so nothing blocks the restart.\n\nIf an app won't quit (e.g. an unsaved-work dialog), the reboot is held and a **Force Reboot** option appears: it force-quits the blocking apps (unsaved work is lost) and restarts.\n\nOn the next login, the boot sequence runs automatically — NAS Refresh and iperf3 Server start without any manual action needed.\n\nThe status turns blue when macOS has a pending update. **Note:** on Apple Silicon, a macOS *system* update can't be applied by a remote reboot — it needs an admin password at the Mac (System Settings → General → Software Update, or via Screen Sharing). Charopos only flags that one's waiting; you install it there."),
        HelpTopic(id: "action-updates", section: "Actions", title: "Service Updates (Arr / SABnzbd / DSM)", symbol: "arrow.down.circle",
            body: "When a service's status pill turns blue with an update pending, clicking it offers to install the update — the mechanics differ per service:\n\n**Update Arr** checks GitHub for new Sonarr/Radarr/Lidarr/Prowlarr releases and installs any found (stop → replace binary → restart, usually under 10 seconds per app, safe to run while media is playing). Also runs hourly in check-only mode to keep the badge current.\n\n**Update SABnzbd** checks GitHub for the latest release and installs it if newer, using the same stop/replace/restart pattern. Requires a valid SABnzbd API key in Settings.\n\n**Update DSMs** connects to each configured Synology NAS via the DSM API, checks for pending DSM updates, and installs any found — the DSM account must be an administrator on each NAS. If a NAS was updated, NAS Refresh runs automatically afterward to remount drives."),
        HelpTopic(id: "action-more", section: "Actions", title: "More One-Tap Actions", symbol: "bolt.badge.clock",
            body: "These optional actions are hidden by default — enable the ones you want in Settings → Actions (or during onboarding). Each appears as a button on every surface once enabled.\n\n**Kickstart Jellyfin** — cleanly restarts the Jellyfin server (SIGTERM, 20s grace, then SIGKILL) and relaunches it. The Jellyfin counterpart to Kickstart Plex.\n\n**Scan Libraries** — asks Plex and Jellyfin to rescan their libraries right away, so newly added files appear without waiting for the next scheduled scan. Only the enabled servers are contacted.\n\n**Clear Transcode Cache** — deletes the temporary transcode files Plex and Jellyfin generate. These caches are safe to remove (the servers regenerate them on demand); clearing them reclaims disk space. Only known transcode temp directories are touched — media and settings are never affected.\n\n**Check for Updates** — forces an immediate refresh of every update badge (arr apps, SABnzbd, Plex, DSM, macOS) instead of waiting for the hourly check. This only checks; use the individual update actions to install.\n\n**Pause / Resume Downloads** — toggles pause across SABnzbd and qBittorrent in one tap. The button shows **Pause** while downloads are active and **Resume** once paused.\n\n**Search Subtitles** — asks Bazarr to search for missing subtitles now. Requires a Bazarr API key in Settings → Services → Bazarr. Best-effort: Bazarr does the downloading in the background on its own timeline.\n\n**Back Up Now** — starts a Time Machine backup immediately. A Time Machine destination must already be configured in System Settings; Charopos doesn't set one up.\n\n**Update Pi-hole Gravity** — connects to your Pi-hole host over SSH and runs `pihole -g` to rebuild the blocklist (gravity) database. Uses the same SSH key/host configured for Pi-hole. This refreshes blocklists only — it's not a Pi-hole software update."),

        // MARK: Services
        HelpTopic(id: "services-overview", section: "Services", title: "Adding & Enabling Services", symbol: "square.stack.3d.up",
            body: "Add and configure services in **Settings → Services**. Each has a **health URL** (used for the status light) and, for some, an **API key or login** that unlocks richer status — a queue count, an active-stream indicator, or update detection.\n\nUncheck a service's **Enabled** toggle to remove it from every status grid entirely — no permanent red light for something you don't run. A newly added service in a future Charopos update starts **disabled** on an existing install too, so upgrading never surprises you with new red lights; it only appears once you turn it on.\n\nServices that need credentials (API key, or a username/password for qBittorrent) will show a warning-free grey/green light without them — the light still works from the health URL alone; the credentials only unlock the extra badge/update signal."),
        HelpTopic(id: "services-unifi", section: "Services", title: "UniFi (Network Console)", symbol: "wifi",
            body: "Charopos talks to any **UniFi OS** console over SSH — that covers Cloud Key Gen2+, Dream Machine, Dream Machine Pro/SE, and Dream Router, not just the original Cloud Key hardware. Enter the console's host/IP and an SSH key in Settings → Services → Integrations → UniFi.\n\nA self-hosted UniFi Network Application (running in Docker rather than on Ubiquiti hardware) isn't supported yet — it uses a different API and doesn't accept the same SSH-based check."),
        HelpTopic(id: "services-media", section: "Services", title: "Media Stack (arr apps, Plex/Jellyfin, Overseerr, Tautulli, Bazarr, qBittorrent)", symbol: "play.tv",
            body: "The media-stack roster covers Sonarr, Radarr, Lidarr, Prowlarr, SABnzbd, Plex, Jellyfin, Bazarr, Overseerr, Tautulli, and qBittorrent.\n\n**Overseerr** is Jellyseerr-compatible — the same API key and health URL work for either, so point the URL at whichever request manager you actually run.\n\n**qBittorrent** doesn't use an API key; its WebUI needs a real username/password login (Settings → Services → Media → qBittorrent), which Charopos uses to open a session the same way the WebUI itself would.\n\n**Jellyfin** shares the streaming indicator with Plex — whichever one has an active session shows the spinning arc.\n\nSome of these services' own log files can appear in the **Logs** dropdown, but only once Charopos actually finds one on disk — see Troubleshooting if a log tab you expect isn't showing up."),

        // MARK: Storage
        HelpTopic(id: "storage-overview", section: "Storage", title: "NAS Units & Local Volumes", symbol: "externaldrive",
            body: "Add NAS units and local volumes in **Settings → Storage**. **Built-in NAS support is Synology-only** — health checks, update detection, and DSM updates all use Synology's DSM API. Local volumes can be any mounted disk and don't need any particular vendor.\n\nEach NAS unit has a **Health URL** (its DSM web address, usually `https://<nas>:5001`) for the status light, and an optional **Mount Source** (an `smb://` or `afp://` URL) that lets **NAS Refresh** actually mount the share — without a Mount Source, the light still works, but NAS Refresh has nothing to mount for that unit.\n\n**Suppress space alerts** on a NAS or volume exempts it from the disk-space warning — useful for a drive that's expected to run full."),
        HelpTopic(id: "storage-mount-user", section: "Storage", title: "NAS Mount User vs. DSM User", symbol: "person.badge.key",
            body: "Two different accounts serve two different purposes, both in Settings → Services → Integrations → Synology:\n\n**DSM user/password** authenticates to the Synology API — health checks and DSM updates.\n\n**NAS mount user** is the AFP/SMB account used to actually mount a share via NAS Refresh, and is often a different account with narrower file permissions. It's injected into each NAS unit's Mount Source URL automatically."),

        // MARK: Notifications
        HelpTopic(id: "notif-overview", section: "Notifications", title: "Alerts & Categories", symbol: "bell",
            body: "Alerts push via **Prowl** — add your API key in Settings → Notifications → (any category) → Prowl. Alerts are grouped into three categories: **Services**, **Storage**, and **Host**, each with its own master switch alongside per-alert toggles.\n\nTurning a category's master switch off mutes every alert in it **without losing the individual toggle settings underneath** — flip it back on and your prior choices return exactly as they were. The one exception is the **Ghost Monitor**, which is a running process, not just a notification — its own toggle lives outside the Storage alert list and isn't affected by that category's master switch."),
        HelpTopic(id: "notif-thresholds", section: "Notifications", title: "Default Thresholds", symbol: "slider.horizontal.3",
            body: "A few alerts are tunable with a threshold, each with a sensible default you can adjust in place next to its toggle:\n\n- **Service unreachable** — after 5 minutes down.\n- **Disk space low** — above 90% used.\n- **Swap usage high** — above 25% of physical RAM (self-sizing — Charopos shows the live GB equivalent for this Mac), and only when the kernel also reports elevated memory pressure, so healthy background swapping doesn't trigger it.\n- **UPS battery low** — below 20% remaining."),

        // MARK: Remote Access
        HelpTopic(id: "remote-overview", section: "Remote Access", title: "Web Dashboard & the Remote App", symbol: "antenna.radiowaves.left.and.right",
            body: "Charopos runs a small local web server (default port 8787) that serves both a **web dashboard** (open the Mac's address in any browser) and the API the **Charopos Remote** companion app polls.\n\nSettings → Services → Integrations → Remote Access (or the onboarding step) offers three modes: **This Mac only** (default — loopback, nothing on your network can reach it), **Tailscale only** (binds just this Mac's Tailscale address, so only your tailnet can reach it), and **All interfaces** (reachable from your whole LAN). The listener rebinds immediately on a change, no relaunch needed. **Tailscale only is the recommended choice on a shared network** — it gets you remote access without exposing the API to everyone on the Wi-Fi. **All interfaces** shows a warning: use it only on trusted networks, since the API is unencrypted HTTP and a captured token gives full control.\n\nRemote clients authenticate with a **token**, generated once and stored next to the app in `launcher-remote-token.txt`. Copy it from under the version number (top-left of the main window; click the \"token: click to copy\" line) to pair the Remote app or a browser session. The same Settings pane has a **Rotate API Token…** button for issuing a fresh token — every paired client (Remote app, browser sessions) is signed out immediately and needs the new token pasted back in."),

        // MARK: Troubleshooting
        HelpTopic(id: "trouble-red", section: "Troubleshooting", title: "A service shows red but is actually running", symbol: "exclamationmark.triangle",
            body: "Charopos checks the **Health URL** configured for that service in Settings — if the service runs on a different host, port, or path than the default, update its Health URL there. Also confirm the service is actually listening on that address (try opening the URL directly in a browser)."),
        HelpTopic(id: "trouble-badge", section: "Troubleshooting", title: "A queue count, update badge, or stream indicator isn't showing", symbol: "questionmark.circle",
            body: "Those signals need credentials beyond the plain health check — an API key (Overseerr, Tautulli, Jellyfin, the arr apps, SABnzbd) or a login (qBittorrent, Synology). Check Settings → Services → (that service) and confirm the key/login is filled in and correct. The health light itself doesn't need credentials — only the richer signals do."),
        HelpTopic(id: "trouble-logs", section: "Troubleshooting", title: "A service's log tab isn't in the Logs dropdown", symbol: "doc.text.magnifyingglass",
            body: "The Logs dropdown only lists a service's own log tab once Charopos finds a matching log file on disk for it — installs vary in where they write logs, so this is a best-effort search. If a service is enabled but its tab still isn't appearing, its install may be logging somewhere Charopos doesn't check yet; Charopos's own event log (the **Charopos** tab) and the **Updater** tab (Arr/SAB/DSM update runs) are always available regardless."),
        HelpTopic(id: "trouble-mount", section: "Troubleshooting", title: "A NAS share won't mount", symbol: "externaldrive.trianglebadge.exclamationmark",
            body: "NAS Refresh can only mount a share that has a **Mount Source** configured (Settings → Storage → that NAS unit). Confirm the `smb://` or `afp://` URL is correct and reachable, and that the **NAS mount user** (Settings → Services → Integrations → Synology) has permission to the share. Try the same URL manually in Finder's **Go → Connect to Server** to isolate a credentials or network problem from a Charopos one."),
        HelpTopic(id: "trouble-remote", section: "Troubleshooting", title: "The Remote app or web dashboard won't connect", symbol: "wifi.exclamationmark",
            body: "Confirm **Remote Access** is set to **Tailscale only** or **All interfaces** (Settings → Services → Integrations → Remote Access) if connecting from another device — it's **This Mac only** by default on a fresh install. If you're using **Tailscale only**, also confirm Tailscale is up on both this Mac and the connecting device — the listener falls back to loopback (and logs it) whenever the tailnet is down, and rebinds automatically once it's back. Confirm the token matches exactly what's shown in the main Charopos window (click the token line to copy it fresh) — note that using **Rotate API Token…** invalidates the old one. If the host name doesn't resolve, try the Mac's IP address or Tailscale address instead of its `.local` name."),

        HelpTopic(id: "trouble-cert", section: "Troubleshooting", title: "\"Certificate Changed\" — a host stopped responding after I replaced its certificate", symbol: "lock.shield",
            body: "NAS and Pi-hole boxes normally serve a certificate no public authority has signed, so there's nothing for Charopos to check it against. Instead it remembers the certificate each host presents the first time it connects, and refuses that host if it later presents a different one — the same trust-on-first-use idea as SSH host keys. This is what keeps the DSM and Pi-hole passwords from being handed to whatever happens to be answering at that address.\n\nIf you deliberately replaced a certificate (regenerated DSM's, moved to a real certificate, or rebuilt the box), clear the stored one: **Settings → Services → Certificates → Forget Pinned Certificates**. Charopos will trust what each host presents on the next connection.\n\nIf you *didn't* change anything, don't clear it yet — a certificate that changes on its own is worth understanding first. Charopos's own event log (the **Charopos** tab) records which host changed and both key fingerprints.\n\nHosts with a genuinely trusted certificate (DSM with Let's Encrypt, say) are validated the ordinary way instead, so routine renewals never trigger this."),

        // MARK: About
        HelpTopic(id: "about", section: "About", title: "About Charopos", symbol: "info.circle",
            body: "Charopos is a menu-bar server-management app: it monitors services and storage, and gives you one-tap controls for the maintenance tasks around them.\n\nFor version information and credits, see **Charopos → About Charopos**. Application logs live in the app's logs folder, reachable via **Open Logs** below the Logs dropdown."),
    ]
}

struct HelpView: View {
    @State private var selection: String? = HelpContent.topics.first?.id

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(HelpContent.sectionOrder, id: \.self) { section in
                    let sectionTopics = HelpContent.topics.filter { $0.section == section }
                    if !sectionTopics.isEmpty {
                        Section(section) {
                            ForEach(sectionTopics) { topic in
                                Label(topic.title, systemImage: topic.symbol)
                                    .tag(topic.id)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 260)

            Divider()

            ScrollView {
                if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: topic.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            Text(topic.title)
                                .font(.title2).fontWeight(.semibold)
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
        .frame(width: 760, height: 540)
    }
}
