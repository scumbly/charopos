import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement

/// Thread-safe capped tail buffer for a running script's stdout/stderr. Drained
/// asynchronously from a pipe's readabilityHandler so a long-running script
/// (iperf3 server, ghost monitor) can never block on a full 64 KB pipe; only the
/// last `cap` bytes are retained — enough to recover the final error line.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    init(cap: Int = 8192) { self.cap = cap }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap { data.removeFirst(data.count - cap) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Runner

@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()

    @Published var states: [String: RunState] = [:]
    @Published var autoRanAtBoot = false

    /// True if a watcher process exists anywhere on the system,
    /// even one spawned by the mount script rather than this app.
    @Published var watcherAlive = false

    /// True if an iperf3 server process is alive (the script exits after
    /// nohup-ing it, so we track the real process, not the script).
    @Published var iperfAlive = false

    /// Timestamp of the newest UpdateArr log file, surviving app restarts.
    @Published var updateArrLastRun: Date? = nil

    /// Full content of the selected log file, refreshed by polling.
    @Published var logTail: [String] = []
    @Published var logTailSource = ""

    /// Which log the panel shows; .auto follows the most recently written file.
    @Published var logChoice: LogChoice = .auto {
        didSet { pollLogTail() }
    }

    private var processes: [String: Process] = [:]
    private var didAutoRun = false
    private var pollTimer: Timer?

    static let watcherFileName = "watch-duplicate-volumes backup-alert-only.command"

    /// Scripts are embedded in the app bundle's Resources/scripts folder.
    let scriptsDir: URL = Bundle.main.resourceURL!.appendingPathComponent("scripts")

    /// Logs go next to the .app (e.g. ~/Applications/logs), never inside the bundle.
    let logsDir: URL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("logs")

    static let items: [ScriptItem] = [
        ScriptItem(id: "kickstart",
                   title: "Kickstart Plex",
                   fileName: "",
                   longRunning: false,
                   info: "Cleanly restarts all media server processes. Sends SIGTERM to Plex Media Server, Radarr, Sonarr, Lidarr, and Prowlarr, giving them up to 20 seconds to shut down gracefully before sending SIGKILL. Once all processes have exited, NAS Refresh runs automatically to remount NAS drives and bring everything back up in order.\n\nUse this when Plex has lost track of its library, media apps are misbehaving, or you need a fresh restart without rebooting the machine."),
        ScriptItem(id: "mount",
                   title: "NAS Refresh",
                   fileName: "Network Volume Refresh and App Launch.command",
                   longRunning: false,
                   info: "Remounts every NAS share configured with a Mount Source in Settings \u{2192} Storage, starts the Ghost Monitor, then launches Plex Media Server, Radarr, Sonarr, Lidarr, Prowlarr, and SABnzbd. Progress is logged to a timestamped file in ~/Applications/logs/.\n\nRuns automatically when the Mac boots or after a successful DSM update. Run it manually if NAS volumes disconnected mid-session, apps crashed, or drives need remounting after a network interruption."),
        ScriptItem(id: "watch",
                   title: "Ghost Monitor",
                   fileName: "watch-duplicate-volumes backup-alert-only.command",
                   longRunning: true,
                   info: "Starts a persistent background daemon that monitors for duplicate or conflicting Synology volume mount points. Duplicate mounts appear when a NAS reconnects while its previous mount is still active — two volumes with the same name, each containing the same media — which causes Plex to report duplicates and can lead to library corruption.\n\nThe watcher detects this condition and sends a macOS notification. It runs continuously until you press Stop, and is normally started automatically by NAS Refresh."),
        ScriptItem(id: "iperf",
                   title: "iperf3 Server",
                   fileName: "iperf-3.command",
                   longRunning: false,
                   info: "Starts an iperf3 network throughput server in the background via nohup, so it keeps running after the script exits. From any device on your network, measure real-world throughput to this Mac with:\n\n    iperf3 -c <this Mac's IP>\n\nUseful for diagnosing slow NAS transfers, Wi-Fi bottlenecks, or comparing wired vs. wireless performance. Press Stop to terminate the iperf3 process."),
        ScriptItem(id: "arr",
                   title: "Update Arr",
                   fileName: "Update Arr.command",
                   longRunning: false,
                   info: "Checks GitHub for new releases of Sonarr, Radarr, Lidarr, and Prowlarr, then downloads and installs any updates found. For each app: stops the process, replaces the binary, restarts it. Typical downtime per app is under 10 seconds and is safe to run while media is playing.\n\nAlso runs in check-only mode every hour automatically to keep the update badge current. Progress is logged to an UpdateArr-timestamped file in ~/Applications/logs/."),
        ScriptItem(id: "sab-update",
                   title: "Update SABnzbd",
                   fileName: "update-sabnzbd.sh",
                   longRunning: false,
                   info: "Checks GitHub for the latest SABnzbd release and installs it if newer than the running version. Downloads the macOS build, stops SABnzbd, installs the update, and restarts it. The SABnzbd status light turns blue when a newer version is detected.\n\nRequires a valid SABnzbd API key in Preferences. Results are logged to an UpdateSAB-timestamped file in ~/Applications/logs/."),
        ScriptItem(id: "dsm-update",
                   title: "Update DSMs",
                   fileName: "update-dsms.sh",
                   longRunning: false,
                   info: "Connects to each configured Synology NAS via the DSM API using the credentials in Preferences, checks for available DSM updates, and triggers installation on any NAS that has one pending. The DSM service on each updated NAS restarts after the update.\n\nExits with code 0 if at least one NAS was updated — which automatically triggers NAS Refresh to remount drives. Exits with code 1 if all NASes are already current (not treated as an error). The DSM account must be in the administrators group on each Synology."),
        ScriptItem(id: "inventory",
                   title: "Run Inventory",
                   fileName: "",
                   longRunning: false,
                   info: "Writes a text log listing every file on every mounted NAS (via `find`) to ~/Applications/logs/inventory_<timestamp>.log. If enabled in Settings > Services > Synology (\"Log inventory every N days\") it also runs automatically on that schedule. Keeps the 10 most recent logs and prunes older ones. Large NAS shares can make a big log and take a while."),
        ScriptItem(id: "reboot",
                   title: "Reboot Server",
                   fileName: "",
                   longRunning: false,
                   info: "Asks every open app to quit — the media apps it controls (Plex, Radarr, Sonarr, Lidarr, Prowlarr, SABnzbd) plus any window app open in the Dock — then, once they're all closed, sends a system restart and quits itself last so nothing blocks the restart.\n\nIf an app won't quit (e.g. an unsaved-work dialog), the reboot is held and a Force Reboot button appears: Force Reboot force-quits the blocking apps (unsaved work is lost) and restarts.\n\nOn the next login, the boot sequence runs automatically — NAS Refresh and iperf3 Server start without any manual action needed.\n\nThe status turns blue when macOS has a pending update. Note: on Apple Silicon a macOS *system* update can't be applied by a remote reboot — it needs an admin password at the Mac (System Settings → General → Software Update, or via Screen Sharing). Charopos flags the update; you install it there."),
        // v4.65 Tier 1 + Tier 2 actions. All optional and hidden by default on
        // existing installs (see knownActions migration); enable per-taste.
        ScriptItem(id: "backup",
                   title: "Back Up Now",
                   fileName: "",
                   longRunning: false,
                   info: "Kicks off a Time Machine backup immediately by running `tmutil startbackup`, without waiting for the next scheduled hourly run. Requires a Time Machine destination to already be configured in System Settings — Charopos does not set one up.\n\nUse this before rebooting, before risky maintenance, or any time you want a fresh restore point on demand. The backup runs in the background; macOS shows its progress in the menu bar as usual."),
        ScriptItem(id: "pause-downloads",
                   title: "Pause Downloads",
                   fileName: "",
                   longRunning: false,
                   info: "Pauses or resumes active downloads on your download clients — SABnzbd (via its API) and qBittorrent (via its Web API) — in one tap. The button reflects the current state: it reads \"Pause Downloads\" while downloads are active and \"Resume Downloads\" once paused.\n\nHandy before running updates, freeing bandwidth for something else, or quieting the server without stopping the apps. Only the clients you have enabled in Settings are affected."),
        ScriptItem(id: "check-updates",
                   title: "Check for Updates",
                   fileName: "",
                   longRunning: false,
                   info: "Forces an immediate check for new versions across everything Charopos tracks — the media apps (Sonarr, Radarr, Lidarr, Prowlarr), SABnzbd, Synology DSM, and macOS — refreshing the update badges right away instead of waiting for the normal hourly cycle.\n\nThis only checks; it does not install anything. Use the individual update actions (Update Arr, Update SABnzbd, Update DSMs) to apply what it finds."),
        ScriptItem(id: "pihole-gravity",
                   title: "Update Pi-hole Gravity",
                   fileName: "",
                   longRunning: false,
                   info: "Connects to your Pi-hole host over SSH and runs `pihole -g`, which rebuilds the gravity database from your configured blocklists. This is the update that pulls in the latest ad/tracker domains.\n\nRequires the same SSH key and host configured for Pi-hole in Settings. Output is logged to a timestamped file in ~/Applications/logs/. Distinct from a Pi-hole software update — this refreshes blocklists only."),
        ScriptItem(id: "kickstart-jellyfin",
                   title: "Kickstart Jellyfin",
                   fileName: "",
                   longRunning: false,
                   info: "Cleanly restarts the Jellyfin media server process — the Jellyfin counterpart to Kickstart Plex. Sends SIGTERM and gives Jellyfin up to 20 seconds to shut down gracefully before sending SIGKILL, then lets it relaunch.\n\nUse this when Jellyfin becomes unresponsive, stops serving clients, or needs a clean restart without rebooting the machine."),
        ScriptItem(id: "scan-libraries",
                   title: "Scan Libraries",
                   fileName: "",
                   longRunning: false,
                   info: "Tells your media servers to rescan their libraries so newly added files show up without waiting for the next scheduled scan. Triggers a full library refresh on Plex and Jellyfin (whichever are enabled) via their APIs.\n\nUse this right after dropping new media onto a NAS share. Only the servers you have enabled are contacted."),
        ScriptItem(id: "clear-transcode",
                   title: "Clear Transcode Cache",
                   fileName: "",
                   longRunning: false,
                   info: "Deletes the temporary transcoding files that Plex and Jellyfin generate while converting media for playback. These caches are safe to remove — the servers regenerate them on demand — and clearing them reclaims disk space when a stuck or bloated transcode directory has grown large.\n\nOnly known transcode temp directories are touched; your media and server settings are never affected. Active playback that is mid-transcode may briefly hiccup as it rebuilds."),
        ScriptItem(id: "bazarr-search",
                   title: "Search Subtitles",
                   fileName: "",
                   longRunning: false,
                   info: "Asks Bazarr to run a search for missing subtitles across your library via its API, rather than waiting for Bazarr's own schedule.\n\nRequires Bazarr to be enabled with a valid URL and API key in Settings. This is a best-effort trigger — Bazarr does the actual downloading in the background on its own timeline, and results depend on what its configured subtitle providers can find."),
    ]

    func state(of item: ScriptItem) -> RunState {
        states[item.id] ?? .idle
    }

    /// True while the quit phase of Kickstart Plex is in progress.
    @Published var kickstarting = false

    /// Timestamp of the last successful Kickstart Plex completion.
    @Published var kickstartLastRun: Date? = nil

    /// When true, all polling is suspended and mock data drives the lights.
    @Published var uiPreviewMode = false
    private var previewTimer: Timer?
    private var previewScenario = 0

    /// Health lights: service id -> healthy. Missing key = not yet checked (renders gray).
    @Published var serviceHealth: [String: Bool] = [:]
    /// Consecutive failure count per service — light only turns red after 2 misses.
    private var serviceFailCount: [String: Int] = [:]

    /// True when /api/v3/health reports any warning or error for that service.
    @Published var serviceWarnings: [String: Bool] = [:]

    /// Disk usage percentage that triggers an orange volume light and Prowl alert (default 90%).
    private var diskAlertThreshold: Double = 90.0

    // Category master gates (loaded from config, default on). Turning a category off
    // suppresses every alert in it while preserving each alert's individual toggle.
    var notifyServices = true
    var notifyStorage  = true
    var notifyHost     = true

    // Individual Prowl alert toggles (raw state, loaded from config, default on). The
    // gated `alertX` accessors below AND these with their category master, so every
    // alert site in Runner honors the master switch without per-site changes.
    var alertNASOfflineEnabled        = true
    var alertServiceDownEnabled       = true
    var alertUpdatesAvailableEnabled  = true
    var alertDiskSpaceEnabled         = true
    var alertUPSOnBatteryEnabled      = true
    var alertUPSLowBatteryEnabled     = true
    var alertMemoryPressureEnabled    = true
    var alertSwapHighEnabled          = true
    var alertExternalIPChangeEnabled  = true
    var alertZombieProcessEnabled     = true
    var alertNTPDriftEnabled          = true
    var alertSMARTFailureEnabled      = true
    var alertSMARTReallocatedEnabled  = true
    var alertTimeMachineErrorEnabled  = true

    // NAS inventory logging (not an alert toggle; default off).
    var inventoryEnabled = false
    var inventoryDays    = 7

    // Gated accessors — individual toggle AND its category master.
    var alertServiceDown:      Bool { alertServiceDownEnabled      && notifyServices }
    var alertUpdatesAvailable: Bool { alertUpdatesAvailableEnabled && notifyServices }
    var alertZombieProcess:    Bool { alertZombieProcessEnabled    && notifyServices }
    var alertNASOffline:       Bool { alertNASOfflineEnabled       && notifyStorage }
    var alertSMARTFailure:     Bool { alertSMARTFailureEnabled     && notifyStorage }
    var alertSMARTReallocated: Bool { alertSMARTReallocatedEnabled && notifyStorage }
    var alertTimeMachineError: Bool { alertTimeMachineErrorEnabled && notifyStorage }
    var alertDiskSpace:        Bool { alertDiskSpaceEnabled        && notifyStorage }
    var alertUPSOnBattery:     Bool { alertUPSOnBatteryEnabled     && notifyHost }
    var alertUPSLowBattery:    Bool { alertUPSLowBatteryEnabled    && notifyHost }
    var alertMemoryPressure:   Bool { alertMemoryPressureEnabled   && notifyHost }
    var alertSwapHigh:         Bool { alertSwapHighEnabled         && notifyHost }
    var alertExternalIPChange: Bool { alertExternalIPChangeEnabled && notifyHost }
    var alertNTPDrift:         Bool { alertNTPDriftEnabled         && notifyHost }
    /// Optional override for the dashboard link attached to Prowl notifications
    /// (config `dashboardURL`). Empty → derive from this machine's mDNS hostname.
    /// Set to e.g. a Tailscale IP if `.local` doesn't resolve where you read alerts.
    var dashboardURLOverride   = ""
    /// Whether the API/dashboard server binds to all interfaces (LAN/Tailscale-reachable)
    /// vs loopback only. Default false = **loopback** (secure) for fresh installs; an existing
    /// install is seeded to true on first load to preserve its prior remote access (see loadConfig).
    /// Kept in sync with `apiBindMode` (= mode != "loopback") for back-compat readers/writers.
    var allowRemoteAccess      = false
    /// API listener bind mode (config `apiBindMode`, v4.80): "loopback" (this Mac only),
    /// "tailscale" (only the Mac's Tailscale CGNAT address — WireGuard-encrypted transit;
    /// the plaintext-HTTP API never crosses the raw LAN), or "all" (old allowRemoteAccess
    /// behavior). Migrated from allowRemoteAccess when the key is absent.
    @Published var apiBindMode = "loopback"
    /// True while apiBindMode is "tailscale" but the tailnet was down at bind time, so the
    /// listener fell back to loopback. pollAll retries every 10s and rebinds when it appears.
    var apiBoundFallback       = false
    /// False only on a true first run (no config file) or until onboarding finishes.
    /// Gates the boot-sequence auto-run and triggers the onboarding window at launch.
    /// Existing installs (config predating the flag) are seeded true in loadConfig.
    var setupComplete          = true
    @Published var ghostMonitorEnabled: Bool = true
    var showWindowAtStartup = false
    var hideDockIcon        = false
    // Configurable alert thresholds (defaults match previous hardcoded values).
    var svcDownMinutes:   Int    = 5
    var upsBatteryLowPct: Int    = 20
    var swapAlertPctRAM:  Double = 25.0  // % of physical RAM (self-sizing); alert also requires elevated kernel pressure

    // Host hardware health state.
    @Published var upsOnBattery: Bool    = false
    @Published var upsBatteryPct: Int?   = nil      // nil until first poll
    @Published var memoryPressure: String = "normal" // "normal" | "warn" | "critical"
    @Published var swapUsedGB: Double    = 0.0

    /// NAS lights: id -> "green" (reachable+mounted) | "orange" (one only) | "red" (neither).
    @Published var nasHealth: [String: String] = [:]

    /// SABnzbd queue info (nil = idle or no API key).
    @Published var sabQueueCount: Int? = nil
    @Published var sabSpeedMBps: Double = 0
    @Published var sabETAMinutes: Int? = nil

    /// *arr queue totals (nil = no API key configured).
    @Published var sonarrQueueCount: Int? = nil
    @Published var radarrQueueCount: Int? = nil
    @Published var lidarrQueueCount: Int? = nil

    /// Active Plex stream count (nil = none or token unavailable).
    @Published var plexStreamCount: Int? = nil

    /// Roster-expansion state (Jellyfin/Overseerr/qBittorrent).
    // v4.65 actions: last-run timestamps for momentary actions (drives their row
    // status text), download pause state, and the qBittorrent-only pause intent.
    @Published var actionLastRun: [String: Date] = [:]
    /// Fail-loud safety net: the most informative error line from the last run of
    /// a script that exited non-zero (keyed by script id). Surfaced in the red
    /// action-row status so a failed run reports *why*, not just an exit code —
    /// e.g. an upstream release-asset rename that leaves the button doing nothing.
    /// Cleared on the next successful run of that id.
    @Published var lastRunError: [String: String] = [:]
    @Published var sabPaused = false          // SAB reports its own global pause state
    private var qbitPauseIntent = false       // qBit has no global pause flag — track our intent
    /// Downloads considered paused if SAB (when enabled) reports paused; else the
    /// qBittorrent pause intent. Drives the Pause/Resume toggle's displayed state.
    var downloadsPaused: Bool { isEnabled("sab") ? sabPaused : qbitPauseIntent }
    @Published var overseerrPendingCount: Int? = nil    // pending media requests (badge)
    @Published var jellyfinStreamCount: Int? = nil      // active playback sessions (nil when none — mirrors plexStreamCount)
    @Published var qbitDownloadCount: Int? = nil        // actively-downloading torrents (badge; nil when none)
    @Published var overseerrUpdateAvailable = false
    @Published var tautulliUpdateAvailable = false

    /// True when GitHub shows a newer SABnzbd release than what's running.
    @Published var sabUpdateAvailable  = false
    @Published var plexUpdateAvailable = false

    /// Timestamp of the newest UpdateSAB log file.
    @Published var sabUpdateLastRun: Date? = nil

    /// Timestamp of the newest UpdateDSM log file.
    @Published var dsmUpdateLastRun: Date? = nil

    /// True when any NAS reports upgrade_ready via DSM polling.
    var dsmUpdateAvailable: Bool { nasAlertState.values.contains("upgrade") }

    /// True when Software Update reports downloaded/available updates.
    @Published var pendingOSUpdates = false

    /// The set of *arr service ids (sonarr/radarr/lidarr/prowlarr) that
    /// update-arr.sh --check reports an update for — per-service, so only the
    /// app(s) that actually have an update light up (not all four).
    @Published var arrUpdatesAvailable: Set<String> = []

    /// Per-app *arr API version, discovered from each app's unversioned `/api`
    /// endpoint so a future bump (e.g. Lidarr v1→v2) auto-adapts instead of
    /// silently 404ing. Seeded with the known-current values; `refreshArrApiVersions`
    /// updates them and logs any change.
    private var arrApiVersion: [String: String] = ["sonarr": "v3", "radarr": "v3", "lidarr": "v1", "prowlarr": "v1"]
    private var arrCheckTimer: Timer?

    /// True when the CloudKey reports a pending firmware update (firmware.yaml /
    /// UniFi DB probe over SSH — see pollCloudKey).
    @Published var cloudKeyUpdateAvailable = false
    @Published var apiPortConflict = false
    private var cloudKeyTimer: Timer?

    /// True when the PiHole v6 API reports a newer core/web/FTL version available.
    /// Informational only (turns the light blue) — PiHole has no update API, so
    /// there is no kickoff; updating is done on the PiHole host via `pihole -up`.
    @Published var piholeUpdateAvailable = false
    /// Cached PiHole v6 session id + its expiry; re-auth when expired or on 401.
    private var piholeSID: String?
    private var piholeSIDExpiry: Date = .distantPast
    /// Don't re-attempt auth before this time — PiHole's FTL rate-limits logins
    /// (HTTP 429), and the 10s health poll would otherwise hammer it and never
    /// let the limit clear. Set on every auth failure.
    private var piholeNextAuth: Date = .distantPast

    /// qBittorrent WebUI v2 auth uses a form login → SID cookie (no API key). Mirror
    /// the PiHole session hygiene: cache the SID and reuse it; back off 3 min after any
    /// auth failure so the 10s poll doesn't hammer the login. Cleared on HTTP 403 to
    /// force a re-login on the next tick.
    private var qbitSID: String?
    private var qbitNextAuth: Date = .distantPast

    /// Date the mount script was last started — persisted in UserDefaults so it
    /// survives app restarts and can be compared against bootDate.
    var lastMountRunDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastMountRunDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastMountRunDate") }
    }
    var lastInventoryRun: Date? {
        get { UserDefaults.standard.object(forKey: "lastInventoryRun") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastInventoryRun") }
    }

    /// When this Mac last booted, from the kernel's boot timestamp.
    var bootDate: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    // MARK: - Infrastructure defaults (used as first-run fallback; editable in Settings)

    /// Neutral first-run defaults for the supported service roster. The IDs/labels are the
    /// load-bearing roster; URLs are placeholders a user replaces in Settings (persisted to
    /// "serviceURLs" in the config). Health URLs default to localhost (services typically run
    /// on the same Mac); "open in browser" URLs default to localhost too. For remote access
    /// over Tailscale, set the open URL to the Tailscale IP — NOT the *.ts.net MagicDNS name
    /// (`ts.net` is HSTS-preloaded, so browsers force-upgrade http→https and plaintext services
    /// hang; the Tailscale IP bypasses HSTS).
    static let serviceDefaults: [(id: String, label: String, url: String?, openURL: String?)] = [
        ("sab",       "SABNzbd",   "http://127.0.0.1:8080/",         "http://127.0.0.1:8080"),
        ("sonarr",    "Sonarr",    "http://127.0.0.1:8989/",         "http://127.0.0.1:8989"),
        ("radarr",    "Radarr",    "http://127.0.0.1:7878/",         "http://127.0.0.1:7878"),
        ("prowlarr",  "Prowlarr",  "http://127.0.0.1:9696/",         "http://127.0.0.1:9696"),
        ("lidarr",    "Lidarr",    "http://127.0.0.1:8686/",         "http://127.0.0.1:8686"),
        ("plex",      "Plex",      "http://127.0.0.1:32400/identity","http://127.0.0.1:32400/manage/index.html#!/"),
        ("jellyfin",  "Jellyfin",  "http://127.0.0.1:8096/health",   "http://127.0.0.1:8096"),
        ("bazarr",    "Bazarr",    "http://127.0.0.1:6767/",         "http://127.0.0.1:6767"),
        ("overseerr", "Overseerr", "http://127.0.0.1:5055/",         "http://127.0.0.1:5055"),
        ("tautulli",  "Tautulli",  "http://127.0.0.1:8181/",         "http://127.0.0.1:8181"),
        // qBittorrent's stock WebUI port is 8080, but the placeholder uses 8085 to avoid
        // colliding with SABnzbd's stock 8080 default (both often run on the same Mac).
        ("qbittorrent","qBittorrent","http://127.0.0.1:8085/",       "http://127.0.0.1:8085"),
        ("tailscale", "Tailscale", nil,                              "https://login.tailscale.com/admin/machines"),
        ("pihole",    "PiHole",    "http://pihole.local/admin/",     "http://pihole.local/admin/"),
        // The "cloudkey" id is load-bearing (config keys, payload consumers, update-script
        // routing) so it stays "cloudkey"; only the display label is "UniFi". The integration
        // covers any UniFi OS console (CloudKey Gen2+, UDM, UDM Pro/SE, UDR) since it reads
        // /data/unifi-core/... over SSH — not just the original Cloud Key hardware.
        ("cloudkey",  "UniFi",     "https://unifi.local/",           "https://unifi.ui.com/"),
    ]

    // First-run defaults are EMPTY — a fresh install adds its own NAS units / local volumes
    // in Settings (or onboarding). A personal install's values live in the config file.
    static let defaultNASUnits: [NASUnit] = []

    static let defaultLocalVolumes: [LocalVolume] = []

    // MARK: - Runtime infrastructure arrays (loaded from config on startup)

    /// NAS units: checked for both HTTP reachability and volume mount state.
    @Published var nasUnits: [NASUnit] = []

    /// Services probed for the status-light row.
    /// `url` — localhost/LAN address used only for health checks.
    /// `openURL` — destination opened in the browser when the light is clicked; nil falls back to url.
    var services: [(id: String, label: String, url: String?, openURL: String?)] = []
    /// Service ids the user has turned off (config `disabledServices`). A disabled service
    /// is not polled (so no wasted requests, no false "Service Down" alert) and is omitted
    /// from the status grid on every surface — for installs that don't run it.
    var disabledServices: Set<String> = []
    func isEnabled(_ id: String) -> Bool { !disabledServices.contains(id) }
    /// Services minus disabled — what the lights/payload should show.
    var enabledServices: [(id: String, label: String, url: String?, openURL: String?)] {
        services.filter { isEnabled($0.id) }
    }

    /// Action rows the user can hide (onboarding checkboxes / Settings → Actions).
    /// Only these ids are hideable — the internal flow scripts (arr/sab-update/
    /// dsm-update/watch) aren't user-facing rows, and automation chains (e.g.
    /// kickstart → mount) still run their scripts regardless of visibility.
    static let optionalActionIDs: Set<String> = [
        "mount", "iperf", "inventory", "kickstart", "reboot",
        // v4.65 Tier 1 + Tier 2 additions.
        "backup", "pause-downloads", "check-updates", "pihole-gravity",
        "kickstart-jellyfin", "scan-libraries", "clear-transcode", "bazarr-search",
    ]
    /// Actions the config has never seen are auto-hidden on load so roster growth
    /// never surprises an existing install (mirrors `knownServices`). Anything not
    /// in this list at load time gets added to `disabledActions`.
    static let preExpansionActions: [String] = ["mount", "iperf", "inventory", "kickstart", "reboot"]

    /// Where an optional action appears (v4.66). `.none` = hidden everywhere;
    /// `.menu` = menu-bar / Actions menu only; `.main` = desktop main window (and,
    /// since the menu mirrors the window, the menu too). The web shows everything
    /// that isn't `.none`.
    enum ActionPlacement: String { case none, menu, main }

    /// Per-action placement (config `actionPlacements`, id → raw). An id absent from
    /// the map is `.none` (the default for a brand-new optional action). Legacy config
    /// migrated from `disabledActions` on first load — see `loadConfig`.
    @Published var actionPlacements: [String: String] = [:]
    /// Legacy hidden-set, still loaded so first-upgrade migration can derive placements.
    var disabledActions: Set<String> = []

    func placement(of id: String) -> ActionPlacement {
        ActionPlacement(rawValue: actionPlacements[id] ?? "") ?? ActionPlacement.none
    }
    /// Enabled = visible on at least one surface (drives web inclusion + payload).
    /// Non-optional internal rows (arr/sab-update/dsm-update/watch) are always enabled.
    func isActionEnabled(_ id: String) -> Bool {
        guard Self.optionalActionIDs.contains(id) else { return true }
        return placement(of: id) != .none
    }
    /// Desktop main-window action rows show only `.main`.
    func showsInMainWindow(_ id: String) -> Bool { placement(of: id) == .main }
    /// Menu-bar / Actions menu shows `.menu` and `.main`.
    func showsInMenu(_ id: String) -> Bool {
        let p = placement(of: id); return p == .menu || p == .main
    }
    /// How many actions currently sit in the main window (for the 6-slot cap in Settings).
    var mainWindowActionCount: Int {
        Self.optionalActionIDs.reduce(0) { $0 + (placement(of: $1) == .main ? 1 : 0) }
    }
    static let maxMainWindowActions = 6

    /// Priority used only to decide which actions keep their Main Window slot when a
    /// loaded/migrated config somehow exceeds the cap — classics first, then the rest.
    private static let mainClampPriority = [
        "mount", "kickstart", "reboot", "iperf", "inventory",
        "kickstart-jellyfin", "scan-libraries", "clear-transcode",
        "check-updates", "pause-downloads", "backup", "pihole-gravity", "bazarr-search",
    ]

    /// Enforce the 6-slot main-window cap defensively on load (migration, hand-edit, or
    /// downgrade could otherwise exceed it). Extra main actions are demoted to `.menu`
    /// (kept accessible, not hidden). Returns true if anything changed.
    @discardableResult
    private func clampMainWindowPlacements() -> Bool {
        let mains = Self.optionalActionIDs.filter { placement(of: $0) == .main }
        guard mains.count > Self.maxMainWindowActions else { return false }
        let ordered = mains.sorted {
            (Self.mainClampPriority.firstIndex(of: $0) ?? 99) < (Self.mainClampPriority.firstIndex(of: $1) ?? 99)
        }
        let demote = ordered.dropFirst(Self.maxMainWindowActions)
        for id in demote { actionPlacements[id] = ActionPlacement.menu.rawValue }
        AppLog.shared.write("Clamped main-window actions to \(Self.maxMainWindowActions) — moved to Menu Only: \(demote.sorted().joined(separator: ", "))")
        return true
    }

    /// Read-modify-write the placement map (and the derived legacy disabledActions) to disk.
    private func persistActionPlacements() {
        let url = configFileURL
        var fresh = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        fresh["actionPlacements"] = actionPlacements
        // Array(...) — optionalActionIDs is a Set, and Set.filter returns a Set, which is
        // NOT a valid JSON type (would abort JSONSerialization with an ObjC exception).
        fresh["disabledActions"] = Array(Self.optionalActionIDs.filter { placement(of: $0) == .none })
        do {
            let data = try JSONSerialization.data(withJSONObject: fresh, options: .prettyPrinted)
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.shared.write("persistActionPlacements: FAILED to write — \(error.localizedDescription)")
        }
    }

    /// Disabled services aren't polled, so any per-service state they held would stay
    /// frozen at its last value and keep driving the menubar icon / update alerts.
    /// Clear it on (re)load so a disabled service has zero lingering effect anywhere.
    private func clearDisabledServiceState() {
        for id in disabledServices {
            serviceHealth.removeValue(forKey: id)
            serviceWarnings.removeValue(forKey: id)
            arrUpdatesAvailable.remove(id)
            svcDownPending.removeAll { $0 == id }
            svcDownAlerted.remove(id)
            // Down-tracking too: a stale svcDownSince/fail-count would otherwise make a
            // re-enabled service alert after ~2 polls (window already elapsed) and go red
            // on its first miss, instead of getting a fresh debounce window.
            svcDownSince.removeValue(forKey: id)
            serviceFailCount.removeValue(forKey: id)
            switch id {
            case "sab":      sabQueueCount = nil; sabUpdateAvailable = false
                             sabSpeedMBps = 0; sabETAMinutes = nil
            case "sonarr":   sonarrQueueCount = nil
            case "radarr":   radarrQueueCount = nil
            case "lidarr":   lidarrQueueCount = nil
            case "plex":     plexStreamCount = nil; plexUpdateAvailable = false
            case "overseerr":   overseerrPendingCount = nil; overseerrUpdateAvailable = false
            case "jellyfin":    jellyfinStreamCount = nil
            case "qbittorrent": qbitDownloadCount = nil; qbitSID = nil
            case "tautulli":    tautulliUpdateAvailable = false
            case "cloudkey": cloudKeyUpdateAvailable = false
            case "pihole":   piholeUpdateAvailable = false
            default: break
            }
        }
    }

    /// Local volumes checked for mount state and disk usage.
    @Published var localVolumes: [LocalVolume] = []

    /// Health state for local volumes: "green" | "orange" | "red".
    @Published var volumeHealth: [String: String] = [:]

    /// Last-seen BSD device identifier per local volume id (e.g. "disk10s1"),
    /// captured while the volume is mounted and persisted across unmount and
    /// relaunch. Used to remount a drive after it's been unmounted, where
    /// resolving the device purely by volume name can fail.
    var volumeDevice: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "volumeDevice") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "volumeDevice") }
    }
    /// In-memory guard so we capture the device once per mount session rather
    /// than spawning `diskutil` on every poll tick.
    private var deviceCapturedThisMount: Set<String> = []

    /// These hosts serve self-signed certificates, so the system trust store
    /// can't vouch for them. Rather than accept anything, both sessions pin the
    /// certificate on first contact and refuse a host whose identity later
    /// changes — see `CertPinStore` in Models.swift.

    private let healthSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        return URLSession(configuration: cfg,
                          delegate: PinningTrustDelegate(),
                          delegateQueue: nil)
    }()
    /// Separate session for the credential-bearing calls (DSM auth + status,
    /// Pi-hole login) — longer timeout since DSM login can take 3–4 seconds.
    private let dsmSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg,
                          delegate: PinningTrustDelegate(),
                          delegateQueue: nil)
    }()
    private var healthTick = 0

    // API keys loaded from config.json in Application Support (see configFileURL).
    private var prowlAPIKey    = ""
    private var sabAPIKey      = ""
    private var sonarrAPIKey   = ""
    private var radarrAPIKey   = ""
    private var lidarrAPIKey   = ""
    private var prowlarrAPIKey = ""
    // Service-roster expansion (Jellyfin/Bazarr/Overseerr/Tautulli/qBittorrent).
    private var overseerrApiKey = ""
    private var tautulliApiKey  = ""
    private var jellyfinApiKey  = ""
    private var bazarrApiKey    = ""   // v4.65: used by the Search Subtitles action (best-effort)
    private var qbitUser        = ""
    private var qbitPass        = ""
    private var synologyUser   = ""
    /// NAS file-mount user (AFP/SMB) — distinct from synologyUser (the DSM API account).
    /// Injected into each NAS's mountSource URL that doesn't already specify a user.
    private var nasMountUser   = ""
    private var synologyPass  = ""
    private var cloudKeyHost  = ""
    private var cloudKeySshKey = ""
    private var piholePassword = ""
    private var piholeSshTarget = ""   // e.g. "pi@pihole.local"
    private var piholeSshKey    = ""   // defaults to ~/.ssh/pihole_ed25519
    // Throttle disk-space Prowl alerts: one per hour per NAS or local volume (keyed by id).
    private var prowlNotifiedAt: [String: Date] = [:]
    // NAS offline: consecutive "red" poll count; set of NASes already alerted.
    private var nasOfflineCount:            [String: Int]  = [:]
    private var nasOfflineAlerted:          Set<String>    = []
    private var nasMountedUnreachableCount: [String: Int]  = [:]
    // Service down: timestamp when service first confirmed down; set already alerted.
    private var svcDownSince:        [String: Date] = [:]
    private var svcDownAlerted:      Set<String>    = []
    // Digest: services queued to be sent in one combined notification.
    private var svcDownPending:      [String]        = []
    private var svcDownDigestTimer:  Timer?
    // Updates digest: last time alert was sent (at most once per 24h).
    private var lastUpdateAlertDate: Date?
    // Host health: suppress repeat alerts until condition clears.
    private var lowBatteryAlerted        = false
    private var memPressureAlerted       = false
    private var memPressureCriticalCount = 0
    private var swapHighAlerted          = false
    private var swapHighCount            = 0
    private var swapLowCount             = 0
    private var swapSeenNormal           = false
    private var zombieAlerted            = false
    private var zombiePolling            = false
    var rebootHung                        = false
    private var ntpDriftAlerted          = false
    private var smartFailedAlerted:      Set<String> = []
    private var smartReallocatedAlerted: Set<String> = []
    // Tracked state for change detection.
    private var externalIP: String = ""
    // Throttle timestamps for slow checks.
    private var lastExternalIPCheck:  Date? = nil
    private var lastNTPCheck:         Date? = nil
    private var lastSMARTCheck:       Date? = nil
    private var lastTMCheck:          Date? = nil

    // DSM health overlay: "crashed" | "upgrade" | "ok" (or absent = not yet queried).
    // "crashed"  → force red regardless of base state
    // "upgrade"  → turn blue when base is green (DSM update available)
    @Published var nasAlertState: [String: String] = [:]

    private struct SynoSession { let sid: String; let expires: Date }
    private var synoSessions: [String: SynoSession] = [:]

    /// True while any one-shot script is active (the always-on watcher
    /// is excluded so the progress bar isn't permanently visible).
    var anyScriptRunning: Bool {
        kickstarting || states.contains { $0.key != "watch" && $0.value == .running }
    }

    /// Pick the most informative line from a failed script's captured output.
    /// Scripts echo `ERROR: …` on their failure paths, so prefer that; else fall
    /// back to the last non-empty line. Truncated for the one-line status.
    nonisolated private func failureReason(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let pick = lines.last(where: { $0.uppercased().hasPrefix("ERROR") }) ?? lines.last
        else { return "" }
        return pick.count > 100 ? String(pick.prefix(100)) + "…" : pick
    }

    func run(_ item: ScriptItem, envOverrides: [String: String] = [:]) {
        guard state(of: item) != .running else { return }
        if item.id == "kickstart" {
            kickstartPlex()
            return
        }
        if item.id == "reboot" {
            rebootServer()
            return
        }
        if item.id == "inventory" {
            runInventory()
            return
        }
        // v4.65 in-process actions — no external script file.
        switch item.id {
        case "backup":             backupNow();            return
        case "pause-downloads":    toggleDownloadsPaused(); return
        case "check-updates":      checkForUpdatesNow();   return
        case "pihole-gravity":     updatePiHoleGravity();  return
        case "kickstart-jellyfin": kickstartJellyfin();    return
        case "scan-libraries":     scanLibraries();        return
        case "clear-transcode":    clearTranscodeCache();  return
        case "bazarr-search":      bazarrSearchSubtitles(); return
        default: break
        }
        let url = scriptsDir.appendingPathComponent(item.fileName)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            states[item.id] = .finished(code: -1, at: Date())
            return
        }
        let process = Process()
        process.executableURL = url
        var env = ProcessInfo.processInfo.environment
        // Login-item PATH lacks Homebrew; prepend standard locations so scripts find bash 4+, etc.
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = brewPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["LAUNCHER_LOG_DIR"] = logsDir.path
        env["SAB_API_KEY"] = sabAPIKey
        // The update script needs the SABnzbd base URL to reach the running instance
        // (installs vary from the stock 8080 port). Without this the full-update run
        // fell back to the script's hardcoded 8080 default and failed instantly with a
        // connection refused before writing a log — while the hourly --check path (which
        // sets SAB_URL) correctly flagged the update. Mirror that injection here.
        env["SAB_URL"] = serviceBase("sab") ?? "http://127.0.0.1:8080"
        env["SYNO_URLS"] = nasUnits.map { $0.checkURL }.joined(separator: " ")
        env["SYNO_USER"] = synologyUser
        env["SYNO_PASS"] = synologyPass
        // Mount sources for the generic NAS Refresh script: "<mount URL>|<mount point>"
        // per configured NAS, newline-separated. Only units with a mountSource set are
        // included. (The owner's personal mount script ignores this and uses its own map.)
        env["SYNO_MOUNTS"] = nasUnits
            .filter { !$0.mountSource.isEmpty }
            .map { "\(mountURLWithUser($0.mountSource))|\($0.mountPoint)" }
            .joined(separator: "\n")
        // The Ghost monitor posts its duplicate-volume alert to Prowl directly, which
        // would bypass the Storage notification master — blank its key when that
        // category is muted. (Env is fixed at launch: a master flipped mid-run takes
        // effect the next time the watcher starts.) Other scripts keep the key.
        env["PROWL_API_KEY"] = (item.id == "watch" && !notifyStorage) ? "" : prowlAPIKey
        for (k, v) in envOverrides { env[k] = v }
        process.environment = env
        // Capture stdout+stderr into a capped tail so a non-zero exit can report
        // *why* it failed (fail-loud), not just an exit code. Drained continuously
        // so long-running scripts can't stall on a full pipe.
        let tail = OutputTail()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if !chunk.isEmpty { tail.append(chunk) }
        }
        AppLog.shared.write("Run: \(item.title)")
        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            outPipe.fileHandleForReading.readabilityHandler = nil
            // Drain any bytes still buffered at exit before reading the tail.
            let rest = outPipe.fileHandleForReading.availableData
            if !rest.isEmpty { tail.append(rest) }
            let reason = code == 0 ? "" : self.failureReason(from: tail.text)
            AppLog.shared.write("Finished: \(item.title) (exit \(code))"
                                + (reason.isEmpty ? "" : " — \(reason)"))
            DispatchQueue.main.async {
                if code == 0 { self.lastRunError[item.id] = nil }
                else { self.lastRunError[item.id] = reason }
                self.states[item.id] = .finished(code: code, at: Date())
                self.processes[item.id] = nil
                // Refresh update badges right after an update run. The app restarts a
                // few seconds after the script exits, so the immediate check can read
                // stale data (or hit a refused connection mid-restart) and leave the
                // blue pill lingering — schedule staggered re-checks so it clears once
                // the app is back up.
                if item.id == "arr" || item.id == "sab-update" {
                    self.refreshUpdateChecks()
                    self.scheduleUpdateRecheck()
                }
                // After a successful DSM update, remount the drives
                if item.id == "dsm-update" && code == 0 {
                    if let mountItem = Self.items.first(where: { $0.id == "mount" }) {
                        self.run(mountItem)
                    }
                }
                if item.id == "mount" && self.ghostMonitorEnabled {
                    if let watchItem = Self.items.first(where: { $0.id == "watch" }),
                       self.states["watch"] != .running {
                        self.run(watchItem)
                    }
                }
            }
        }
        do {
            try process.run()
            states[item.id] = .running
            processes[item.id] = process
            if item.id == "mount" { lastMountRunDate = Date() }
        } catch {
            AppLog.shared.write("Failed to launch: \(item.title)")
            states[item.id] = .finished(code: -1, at: Date())
        }
    }

    func updateSingleNAS(_ nasId: String) {
        guard let nas = nasUnits.first(where: { $0.id == nasId }),
              let item = Self.items.first(where: { $0.id == "dsm-update" }) else { return }
        run(item, envOverrides: ["SYNO_URLS": nas.checkURL])
    }

    func stop(_ item: ScriptItem) {
        AppLog.shared.write("Stop: \(item.title)")
        if let p = processes[item.id] {
            p.terminate()
        } else if !item.fileName.isEmpty {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", item.fileName]
            try? pkill.run()
        }
    }

    /// Restart macOS via a System Events Apple Event (no admin password
    /// needed for the logged-in user). Quits all media apps first so macOS
    /// Resume doesn't reopen them before the mount script has run — the boot
    /// sequence will launch them at the right time as usual.
    /// Apps Charopos controls that run as background/agent processes (not in the Dock),
    /// so they must be signalled by name rather than via NSWorkspace.
    private static let mediaAppNames = ["Plex Media Server", "Radarr", "Sonarr", "Lidarr", "Prowlarr", "SABnzbd"]

    /// Reboot is driven entirely by Charopos: quit the apps it controls + every
    /// Dock-visible user app FIRST, and only once they're all gone fire the system
    /// restart and self-terminate. If a user app refuses to quit (e.g. an unsaved-work
    /// dialog), we never start the restart — we flag `rebootHung` so the UI offers
    /// Force Reboot. Charopos never returns `.terminateLater`, so it can't deadlock the
    /// restart the way the old lsappinfo-polling design did.
    func rebootServer(force: Bool = false) {
        AppLog.shared.write("Reboot initiated\(force ? " (force)" : "")")
        rebootHung = false
        states["reboot"] = .running
        let ownPid = ProcessInfo.processInfo.processIdentifier

        // Phase 1: ask every Dock-visible user app to quit (graceful), or force-kill.
        let userApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
            && $0.processIdentifier != ownPid
            && $0.bundleIdentifier != "com.apple.finder"   // relaunches itself; never a real blocker
        }
        let names = userApps.compactMap { $0.localizedName }.joined(separator: ", ")
        AppLog.shared.write("Quitting user apps: \(names.isEmpty ? "none" : names)")
        for app in userApps { if force { app.forceTerminate() } else { app.terminate() } }

        // Phase 2 (detached): signal the controlled media apps + remote-session daemons
        // (the latter prevents the "another user is logged in" restart modal).
        let sig = force ? "KILL" : "TERM"
        let appList = Runner.mediaAppNames.map { "\"\($0)\"" }.joined(separator: " ")
        runRebootShell("""
        _log() { echo "[reboot] $*" >> "$LAUNCHER_LOG_DIR/charopos.log"; }
        for a in \(appList); do pkill -\(sig) -x "$a" 2>/dev/null; done
        _log "Media apps signalled (\(sig))"
        killall -9 screensharingd ARDAgent 2>/dev/null
        """)

        // Phase 3: after a grace period, KILL any leftover media apps (they have no save
        // dialogs) and decide based on whether any *user* app is still alive.
        let grace = force ? 3 : 10
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(grace)) { [weak self] in
            guard let self else { return }
            let appList = Runner.mediaAppNames.map { "\"\($0)\"" }.joined(separator: " ")
            self.runRebootShell("for a in \(appList); do pkill -KILL -x \"$a\" 2>/dev/null; done")

            let survivors = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
                && $0.processIdentifier != ownPid
                && $0.bundleIdentifier != "com.apple.finder"
                && !$0.isTerminated
            }
            if force || survivors.isEmpty {
                AppLog.shared.write("User apps clear — issuing restart and quitting Charopos")
                self.fireRestartAndQuit(force: force)
            } else {
                let blockers = survivors.compactMap { $0.localizedName }.joined(separator: ", ")
                AppLog.shared.write("Reboot blocked by: \(blockers) — awaiting Force Reboot")
                self.rebootHung = true
                self.states["reboot"] = .finished(code: 1, at: Date())
            }
        }
    }

    /// Fires the system restart on a detached child (which outlives Charopos), then
    /// quits Charopos so nothing is left to block the restart.
    private func fireRestartAndQuit(force: Bool) {
        // Plain System Events restart for BOTH modes. `restart with saving preference no`
        // is NOT valid AppleScript (System Events' restart verb has no `saving`
        // parameter — it fails to compile, so osascript errored silently and the machine
        // never rebooted). It's also unnecessary: by the time we get here every blocking
        // app has already been quit (force-terminated in force mode), so a plain restart
        // proceeds with nothing left to prompt.
        // Capture any osascript error to the log — a silent failure here is what hid
        // the invalid-AppleScript bug. If the restart event fires, the machine reboots
        // and there's nothing to log; if it errors, the reason lands in charopos.log.
        let restartCmd = "osascript -e 'tell application \"System Events\" to restart'"
        runRebootShell("sleep 5 && { \(restartCmd) || echo \"[reboot] restart command failed: $?\" >> \"$LAUNCHER_LOG_DIR/charopos.log\"; }")
        states["reboot"] = .finished(code: 0, at: Date())
        AppLog.shared.write("Restart issued (\(force ? "force" : "standard")) — quitting Charopos")
        NSApplication.shared.terminate(nil)
    }

    /// Runs a short bash snippet detached (no termination handler / waiting). The child
    /// survives Charopos's own exit, which is required for the deferred restart.
    private func runRebootShell(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["LAUNCHER_LOG_DIR"] = logsDir.path
        p.environment = env
        try? p.run()
    }

    /// Mount/launch script (which spawns the watcher itself) + iperf3.
    /// Used by the automatic at-boot run.
    func runBootSequence() {
        AppLog.shared.write("Boot sequence started")
        if let mount = Self.items.first(where: { $0.id == "mount" }) { run(mount) }
        if let iperf = Self.items.first(where: { $0.id == "iperf" }) { run(iperf) }
    }

    /// Quit Plex and the *arr apps (SIGTERM, escalating to SIGKILL after
    /// 20s — they don't answer AppleScript quit events), then run the
    /// mount/launch script, which relaunches them all.
    func kickstartPlex() {
        guard !kickstarting else { return }
        kickstarting = true
        AppLog.shared.write("Kickstart Plex: stopping media apps")
        // Stop Ghost Monitor now; mount's terminationHandler restarts it after remount
        if let watchItem = Self.items.first(where: { $0.id == "watch" }),
           states["watch"] == .running {
            stop(watchItem)
        }

        let script = """
        apps=("Plex Media Server" "Radarr" "Sonarr" "Lidarr" "Prowlarr")
        for a in "${apps[@]}"; do pkill -TERM -x "$a" 2>/dev/null; done
        for i in $(seq 1 20); do
            alive=0
            for a in "${apps[@]}"; do pgrep -x "$a" >/dev/null && alive=1; done
            [ $alive -eq 0 ] && exit 0
            sleep 1
        done
        for a in "${apps[@]}"; do pkill -KILL -x "$a" 2>/dev/null; done
        sleep 1
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.terminationHandler = { _ in
            AppLog.shared.write("Kickstart Plex: media apps stopped, launching mount sequence")
            DispatchQueue.main.async {
                self.kickstarting = false
                self.kickstartLastRun = Date()
                if let mountItem = Self.items.first(where: { $0.id == "mount" }) {
                    self.run(mountItem)
                }
            }
        }
        do { try p.run() } catch { kickstarting = false }
    }

    // MARK: - Manual restart / remount

    func restartService(_ id: String, label: String) {
        let cmd: String
        switch id {
        case "sab":      cmd = "open -a 'SABnzbd'"
        case "sonarr":   cmd = "open -a 'Sonarr'"
        case "radarr":   cmd = "open -a 'Radarr'"
        case "prowlarr": cmd = "open -a 'Prowlarr'"
        case "lidarr":   cmd = "open -a 'Lidarr'"
        case "bazarr":      cmd = "open -a 'Bazarr'"
        case "overseerr":   cmd = "open -a 'Overseerr'"
        case "tautulli":    cmd = "open -a 'Tautulli'"
        case "jellyfin":    cmd = "open -a 'Jellyfin'"
        case "qbittorrent": cmd = "open -a 'qBittorrent'"
        case "plex":     cmd = "open -a 'Plex Media Server'"
        case "tailscale":
            // Try CLI first (connects VPN); fall back to launching the GUI app
            cmd = """
            for p in /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
                [ -x "$p" ] && { "$p" up 2>&1; exit $?; }
            done
            open -a Tailscale 2>&1
            """
        default:
            AppLog.shared.write("[Relaunch] \(label): skipped — '\(id)' is a remote device or has no local restart action")
            return
        }
        let shortCmd = cmd.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? cmd
        AppLog.shared.write("[Relaunch] \(label): starting — \(shortCmd)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.terminationHandler = { proc in
            let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = proc.terminationStatus
            var msg = "[Relaunch] \(label): exit \(code) — \(code == 0 ? "success" : "FAILED")"
            if !stdout.isEmpty { msg += " | stdout: \(stdout)" }
            if !stderr.isEmpty { msg += " | stderr: \(stderr)" }
            AppLog.shared.write(msg)
        }
        do { try p.run() } catch {
            AppLog.shared.write("[Relaunch] \(label): FAILED to launch process — \(error.localizedDescription)")
        }
    }

    func remountNAS(_ id: String, label: String) {
        AppLog.shared.write("[Remount] \(label): triggering NAS Refresh script")
        if let item = Self.items.first(where: { $0.id == "mount" }) {
            run(item)
        } else {
            AppLog.shared.write("[Remount] \(label): FAILED — 'mount' script item not found in Runner.items")
        }
    }

    func remountVolume(_ id: String, label: String, mountPoint: String) {
        let volName = URL(fileURLWithPath: mountPoint).lastPathComponent
        let remembered = volumeDevice[id] ?? ""
        AppLog.shared.write("[Remount] \(label): attempting to mount '\(volName)'"
            + (remembered.isEmpty ? "" : " (remembered /dev/\(remembered))"))
        func shq(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        let name = shq(volName)
        let dev  = shq(remembered)
        let script = """
        VOL='\(name)'
        DEV='\(dev)'
        mount_dev() { echo "Mounting /dev/$1 for '$VOL'..."; diskutil mount "$1"; }
        # 1. Prefer the device we remembered while mounted — but only if it still
        #    belongs to this volume (disk numbers can shift across reconnects).
        if [ -n "$DEV" ]; then
            NAME=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Volume Name/{print $2; exit}')
            if [ "$NAME" = "$VOL" ]; then mount_dev "$DEV"; exit $?; fi
        fi
        # 2. Resolve the device from the volume name. diskutil can do this for an
        #    unmounted volume and handles names with spaces, unlike a column scan.
        DEV=$(diskutil info "$VOL" 2>/dev/null | awk -F': *' '/Device Identifier/{print $2; exit}')
        if [ -n "$DEV" ]; then mount_dev "$DEV"; exit $?; fi
        echo "Could not find a device for '$VOL' — is the drive physically connected?" >&2
        exit 1
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.terminationHandler = { proc in
            let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = proc.terminationStatus
            var msg = "[Remount] \(label): exit \(code) — \(code == 0 ? "success" : "FAILED")"
            if !stdout.isEmpty { msg += " | \(stdout)" }
            if !stderr.isEmpty { msg += " | stderr: \(stderr)" }
            AppLog.shared.write(msg)
        }
        do { try p.run() } catch {
            AppLog.shared.write("[Remount] \(label): FAILED to launch process — \(error.localizedDescription)")
        }
    }

    func unmountVolume(_ id: String, label: String, mountPoint: String) {
        AppLog.shared.write("[Unmount] \(label): unmounting \(mountPoint)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["unmount", mountPoint]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.terminationHandler = { proc in
            let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = proc.terminationStatus
            var msg = "[Unmount] \(label): exit \(code) — \(code == 0 ? "success" : "FAILED")"
            if !stdout.isEmpty { msg += " | \(stdout)" }
            if !stderr.isEmpty { msg += " | stderr: \(stderr)" }
            AppLog.shared.write(msg)
        }
        do { try p.run() } catch {
            AppLog.shared.write("[Unmount] \(label): FAILED to launch process — \(error.localizedDescription)")
        }
    }

    /// Auto-run the boot sequence if the mount script hasn't run since the last boot.
    /// Uses a persisted timestamp so it works regardless of how long after boot
    /// the user logs in, and won't re-run if the app is merely reopened.
    func autoRunIfJustBooted() {
        // Gate HERE, not at call sites — there are several (App launch, ContentView
        // onAppear) and a missed one bypasses the first-run protection. Consuming
        // didAutoRun even when gated means finishing onboarding never fires a
        // surprise boot sequence mid-session; it participates from the next launch.
        guard !didAutoRun else { return }
        didAutoRun = true
        guard setupComplete else {
            AppLog.shared.write("Boot sequence gated — setup not complete (first run)")
            return
        }
        // The boot sequence is the NAS Refresh flow — if the user hid that action,
        // they don't want it auto-running at boot either. (Manual /run/boot still works.)
        guard isActionEnabled("mount") else {
            AppLog.shared.write("Boot sequence gated — NAS Refresh action is disabled")
            return
        }
        let boot = bootDate ?? Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        let lastRun = lastMountRunDate
        if lastRun == nil || lastRun! < boot {
            autoRanAtBoot = true
            runBootSequence()
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            AppLog.shared.write("Boot sequence skipped — mount last ran \(fmt.string(from: lastRun!))")
            // Re-adopt Ghost Monitor: kill any orphan from a previous session, restart under Runner tracking
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", "watch-duplicate-volumes"]
            try? pkill.run()
            pkill.waitUntilExit()
            if ghostMonitorEnabled, let watchItem = Self.items.first(where: { $0.id == "watch" }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run(watchItem) }
            }
        }
    }

    /// Removes timestamped log files older than 30 days; caps iperf3-server.log at 2 MB.
    private func cleanOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for url in files where url.pathExtension == "log" {
            if url.lastPathComponent == "iperf3-server.log" {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                   size > 2_000_000 {
                    try? fm.removeItem(at: url)
                }
            } else if let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// On the first launch of each new app version, probe every configured
    /// volume mount point so macOS fires any pending TCC permission prompts
    /// (network volumes, removable volumes) at startup rather than mid-operation.
    private func probeVolumeAccessIfNewVersion() {
        let configURL = configFileURL   // native location; loadConfig() has already migrated by now
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard json["probedVersion"] as? String != appVersion else { return }
        AppLog.shared.write("New version \(appVersion) — probing volume paths for TCC permission prompts")
        let paths = nasUnits.map(\.mountPoint) + localVolumes.map(\.mountPoint)
        let version = appVersion
        DispatchQueue.global(qos: .utility).async {
            for path in paths { _ = try? FileManager.default.contentsOfDirectory(atPath: path) }
            // Persist the marker on the main actor with a FRESH read-modify-write of just
            // this key. Writing back the whole snapshot captured before the (slow, network-
            // volume) probing raced concurrent config writers — a Preferences save landing
            // mid-probe was silently clobbered by the stale copy.
            Task { @MainActor in
                var fresh = (try? Data(contentsOf: configURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                fresh["probedVersion"] = version
                if let updated = try? JSONSerialization.data(withJSONObject: fresh, options: .prettyPrinted) {
                    try? updated.write(to: configURL)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
                }
            }
        }
    }

    /// Poll every 2 seconds: process states + log files.
    func startPolling() {
        guard pollTimer == nil else { return }
        loadConfig()
        // A certificate that changed under us is a security event, not a poll
        // failure, so it gets its own notification rather than surfacing as a
        // generic Service Down. Installed after loadConfig so the Prowl key is up.
        CertPinStore.shared.onMismatch { [weak self] event, detail in
            DispatchQueue.main.async { self?.sendProwlNotification(event: event, description: detail) }
        }
        probeVolumeAccessIfNewVersion()
        // Owner-only logs dir (v4.80): inventory logs enumerate every NAS filename,
        // so keep other local users/processes out. Re-asserted every launch.
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
        AppLog.shared.write("Charopos \(appVersion) started")
        cleanOldLogs()
        pollAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.pollAll() }
        }
        // Update checks (*arr via each app's own API, SABnzbd via GitHub) run hourly,
        // not per-tick.
        refreshUpdateChecks()
        arrCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.uiPreviewMode else { return }   // don't clobber mock state mid-preview
                self.refreshUpdateChecks()
            }
        }
        // CloudKey update check via SSH — every 2 minutes is plenty for update detection.
        pollCloudKey()
        cloudKeyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.uiPreviewMode else { return }   // don't clobber mock state mid-preview
                self.pollCloudKey()
            }
        }
    }

    private var isTerminating = false

    func stopPolling() {
        isTerminating = true
        pollTimer?.invalidate();     pollTimer = nil
        arrCheckTimer?.invalidate(); arrCheckTimer = nil
        cloudKeyTimer?.invalidate(); cloudKeyTimer = nil
        deletePiHoleSession()
    }

    /// Free our PiHole API session on quit. FTL has a small session pool
    /// (`max_sessions`, default 16); without this, every Charopos restart leaks a
    /// session until it times out (~30 min), eventually exhausting the seats
    /// ("api_seats_exceeded"). Best-effort, synchronous with a short timeout
    /// since the app is terminating.
    private func deletePiHoleSession() {
        guard let sid = piholeSID, let base = piholeAPIBase,
              let url = URL(string: "\(base)/auth") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
        let sem = DispatchSemaphore(value: 0)
        dsmSession.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
        piholeSID = nil
    }

    /// Runs a Process with a hard timeout; terminates it if the limit is exceeded.
    /// Returns false if the process could not be launched.
    @discardableResult
    nonisolated static func timedRun(_ p: Process, timeout: TimeInterval) -> Bool {
        guard (try? p.run()) != nil else { return false }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)
        p.waitUntilExit()
        kill.cancel()
        return true
    }

    /// *arr ports/keys, shared by the version/update/health checks.
    /// (id, base, key) per *arr app — base derived from each service's configured URL
    /// (no hardcoded port). Apps whose service URL isn't set/parseable are dropped (not polled).
    private var arrEndpoints: [(id: String, base: String, key: String)] {
        [("sonarr", sonarrAPIKey), ("radarr", radarrAPIKey),
         ("lidarr", lidarrAPIKey), ("prowlarr", prowlarrAPIKey)]
            .filter { isEnabled($0.0) }
            .compactMap { id, key in serviceBase(id).map { (id, $0, key) } }
    }

    /// Discovers each *arr's current API version from its unversioned `/api`
    /// endpoint and logs (alerts) if it changed from what we were using — so a
    /// future version bump auto-adapts AND is visible in the log, instead of
    /// silently 404ing the health/update checks.
    private func refreshArrApiVersions() {
        for app in arrEndpoints {
            guard !app.key.isEmpty, let url = URL(string: "\(app.base)/api") else { continue }
            var req = URLRequest(url: url)
            req.setValue(app.key, forHTTPHeaderField: "X-Api-Key")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = json["current"] as? String, !current.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.arrApiVersion[app.id] != current {
                        AppLog.shared.write("\(app.id.capitalized) API version is now \(current) (was \(self.arrApiVersion[app.id] ?? "?")) — adapting health/update checks")
                        self.arrApiVersion[app.id] = current
                    }
                }
            }.resume()
        }
    }

    /// Re-runs every update-availability check that isn't on the fast (2s/10s) poll:
    /// *arr (each app's own API, after rediscovering the API version), SABnzbd, Plex.
    /// CloudKey/PiHole update flags self-restore via their own polling. Called at
    /// launch, hourly, and after leaving UI Preview (which wipes the flags).
    private func refreshUpdateChecks() {
        refreshArrApiVersions()
        checkArrUpdates()
        checkSABUpdate()
        checkPlexUpdate()
        checkOverseerrUpdate()
        checkTautulliUpdate()
    }

    /// After an update run the target app restarts, so an immediate check can catch
    /// it mid-restart and see stale data — leaving the blue "update available" pill
    /// on a service that's already current. Re-check a few times with backoff so the
    /// flag clears once the app is back up (rather than waiting for the hourly tick).
    private func scheduleUpdateRecheck() {
        for delay in [10.0, 30.0, 60.0, 120.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.uiPreviewMode else { return }
                self.refreshUpdateChecks()
            }
        }
    }

    /// Checks each *arr's own update API (matches what the app's "Updates" page
    /// shows) and flags per-service. An update is available when the `latest`
    /// version isn't `installed`. Uses the discovered per-app API version.
    /// (The actual update still runs update-arr.sh.)
    private func checkArrUpdates() {
        for app in arrEndpoints {
            let ver = arrApiVersion[app.id] ?? "v3"
            guard !app.key.isEmpty,
                  let url = URL(string: "\(app.base)/api/\(ver)/update") else { continue }
            var req = URLRequest(url: url)
            req.setValue(app.key, forHTTPHeaderField: "X-Api-Key")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data,
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }
                // Update available when the newest version isn't the installed one.
                let latest = arr.first(where: { $0["latest"] as? Bool == true }) ?? arr.first
                let avail = (latest?["installed"] as? Bool) == false
                DispatchQueue.main.async {
                    guard let self else { return }
                    let had = self.arrUpdatesAvailable.contains(app.id)
                    if avail {
                        if !had { AppLog.shared.write("Update available: \(app.id.capitalized) \(latest?["version"] as? String ?? "")") }
                        self.arrUpdatesAvailable.insert(app.id)
                    } else {
                        self.arrUpdatesAvailable.remove(app.id)
                    }
                }
            }.resume()
        }
    }

    /// Runs update-sabnzbd.sh --check to see if a newer release exists on GitHub.
    private func checkSABUpdate() {
        guard !sabAPIKey.isEmpty else { return }
        let url = scriptsDir.appendingPathComponent("update-sabnzbd.sh")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        let p = Process()
        p.executableURL = url
        p.arguments = ["--check"]
        var env = ProcessInfo.processInfo.environment
        env["SAB_API_KEY"] = sabAPIKey
        env["SAB_URL"] = serviceBase("sab") ?? "http://127.0.0.1:8080"   // stock SABnzbd port
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        DispatchQueue.global(qos: .utility).async {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
            let available = out.contains("update available")
            DispatchQueue.main.async {
                if available && !self.sabUpdateAvailable {
                    AppLog.shared.write("Update available: SABnzbd")
                }
                self.sabUpdateAvailable = available
            }
        }
    }

    /// Checks the local Plex server's updater endpoint for a pending update.
    /// Reads .LocalAdminToken directly — no configuration required.
    private func checkPlexUpdate() {
        guard isEnabled("plex") else { return }
        let tokenFile = NSHomeDirectory() +
            "/Library/Application Support/Plex Media Server/.LocalAdminToken"
        guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
                                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        guard let base = serviceBase("plex"), let url = URL(string: "\(base)/updater/status") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mc   = json["MediaContainer"] as? [String: Any]
            else { return }
            let hasUpdate = (mc["size"] as? Int ?? 0) > 0
            DispatchQueue.main.async {
                if hasUpdate && !(self?.plexUpdateAvailable ?? false) {
                    AppLog.shared.write("Update available: Plex")
                }
                self?.plexUpdateAvailable = hasUpdate
            }
        }.resume()
    }

    func updatePlex() {
        let tokenFile = NSHomeDirectory() +
            "/Library/Application Support/Plex Media Server/.LocalAdminToken"
        guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
                                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let base = serviceBase("plex"),
              let url = URL(string: "\(base)/updater/apply?tonight=0") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "PUT"
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                AppLog.shared.write("Plex update apply: \(ok ? "triggered" : "failed")")
                if ok { self?.plexUpdateAvailable = false }
            }
        }.resume()
    }

    /// Polls the local Plex server for the number of active streams.
    /// Reads .LocalAdminToken directly — no configuration required.
    private func checkPlexSessions() {
        guard isEnabled("plex") else { return }
        let tokenFile = NSHomeDirectory() +
            "/Library/Application Support/Plex Media Server/.LocalAdminToken"
        guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
                                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        guard let base = serviceBase("plex"), let url = URL(string: "\(base)/status/sessions") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mc   = json["MediaContainer"] as? [String: Any]
            else { return }
            let count = mc["size"] as? Int ?? 0
            DispatchQueue.main.async { self?.plexStreamCount = count > 0 ? count : nil }
        }.resume()
    }

    // MARK: - Roster-expansion pollers (Jellyfin / Overseerr / Tautulli / qBittorrent)

    /// Overseerr pending-request count (badge). 10s group. On HTTP 401/403 the count is
    /// cleared; other request failures leave it as-is (transient).
    private func pollOverseerr() {
        guard isEnabled("overseerr") else { return }
        guard !overseerrApiKey.isEmpty else { overseerrPendingCount = nil; return }
        guard let base = serviceBase("overseerr"),
              let url = URL(string: "\(base)/api/v1/request/count") else { return }
        var req = URLRequest(url: url)
        req.setValue(overseerrApiKey, forHTTPHeaderField: "X-Api-Key")
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async {
                guard let self else { return }
                if code == 401 || code == 403 { self.overseerrPendingCount = nil; return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pending = json["pending"] as? Int
                else { return }   // transient failure: leave count as-is
                self.overseerrPendingCount = pending > 0 ? pending : nil
            }
        }.resume()
    }

    /// Overseerr update check (hourly). Silent no-op on failure.
    private func checkOverseerrUpdate() {
        guard isEnabled("overseerr"), !overseerrApiKey.isEmpty else { return }
        guard let base = serviceBase("overseerr"),
              let url = URL(string: "\(base)/api/v1/status") else { return }
        var req = URLRequest(url: url)
        req.setValue(overseerrApiKey, forHTTPHeaderField: "X-Api-Key")
        healthSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let avail = json["updateAvailable"] as? Bool
            else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if avail && !self.overseerrUpdateAvailable { AppLog.shared.write("Update available: Overseerr") }
                self.overseerrUpdateAvailable = avail
            }
        }.resume()
    }

    /// Tautulli update check (hourly). Silent no-op on failure.
    private func checkTautulliUpdate() {
        guard isEnabled("tautulli"), !tautulliApiKey.isEmpty else { return }
        guard let base = serviceBase("tautulli"),
              let url = URL(string: "\(base)/api/v2?apikey=\(tautulliApiKey)&cmd=update_check") else { return }
        healthSession.dataTask(with: URLRequest(url: url)) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? [String: Any],
                  (response["result"] as? String) == "success",
                  let d = response["data"] as? [String: Any],
                  let update = d["update"] as? Bool
            else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if update && !self.tautulliUpdateAvailable { AppLog.shared.write("Update available: Tautulli") }
                self.tautulliUpdateAvailable = update
            }
        }.resume()
    }

    /// Jellyfin active-session count → streaming spinner (mirrors checkPlexSessions).
    /// 10s group. Counts sessions with a non-null NowPlayingItem.
    private func checkJellyfinSessions() {
        guard isEnabled("jellyfin") else { return }
        guard !jellyfinApiKey.isEmpty else { jellyfinStreamCount = nil; return }
        guard let base = serviceBase("jellyfin"),
              let url = URL(string: "\(base)/Sessions") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(jellyfinApiKey, forHTTPHeaderField: "X-Emby-Token")
        healthSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return }
            let count = arr.filter { session in
                guard let npi = session["NowPlayingItem"], !(npi is NSNull) else { return false }
                return true
            }.count
            DispatchQueue.main.async { self?.jellyfinStreamCount = count > 0 ? count : nil }
        }.resume()
    }

    /// qBittorrent actively-downloading count (badge). 10s group. WebUI API v2 uses a
    /// form login → SID cookie (no API key), so mirror the PiHole session hygiene:
    /// cache the SID, back off 3 min after an auth failure, drop the SID on 403.
    private func pollQbit() {
        guard isEnabled("qbittorrent") else { return }
        guard !qbitUser.isEmpty else { qbitDownloadCount = nil; return }
        guard let base = serviceBase("qbittorrent") else { return }

        // Percent-encode form values: .urlQueryAllowed minus the sub-delimiters that are
        // significant in an application/x-www-form-urlencoded body.
        var formAllowed = CharacterSet.urlQueryAllowed
        formAllowed.remove(charactersIn: "&=+")
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? $0 }

        // With a cached SID, query the downloading torrents directly.
        if let sid = qbitSID {
            guard let url = URL(string: "\(base)/api/v2/torrents/info?filter=downloading") else { return }
            var req = URLRequest(url: url)
            req.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie")
            healthSession.dataTask(with: req) { [weak self] data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                DispatchQueue.main.async {
                    guard let self else { return }
                    if code == 403 { self.qbitSID = nil; return }   // stale session — re-login next tick
                    guard let data,
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                    else { return }
                    self.qbitDownloadCount = arr.count > 0 ? arr.count : nil
                }
            }.resume()
            return
        }

        // No SID: authenticate (respecting the post-failure backoff).
        guard Date() >= qbitNextAuth else { return }
        guard let loginURL = URL(string: "\(base)/api/v2/auth/login") else { return }
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(base, forHTTPHeaderField: "Referer")   // qBittorrent rejects logins without a matching Referer
        req.httpBody = "username=\(enc(qbitUser))&password=\(enc(qbitPass))".data(using: .utf8)
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            let body = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The SID arrives in the Set-Cookie header (e.g. "SID=abc123; HttpOnly; path=/").
            let setCookie = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") ?? ""
            let sid: String? = setCookie.range(of: "SID=").map {
                String(setCookie[$0.upperBound...].prefix { $0 != ";" })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if body == "Ok.", let sid, !sid.isEmpty {
                    self.qbitSID = sid
                    self.qbitNextAuth = .distantPast
                } else {
                    self.qbitSID = nil
                    self.qbitNextAuth = Date().addingTimeInterval(180)
                    AppLog.shared.write("qBittorrent: auth failed — backing off 3 min")
                }
            }
        }.resume()
    }

    private func pollAll() {
        guard !isTerminating else { return }
        guard !uiPreviewMode else { return }
        checkProcess(["-f", Self.watcherFileName]) { self.watcherAlive = $0 }
        checkProcess(["-x", "iperf3"]) { self.iperfAlive = $0 }
        pollLogTail()
        pollUpdateLastRuns()
        // Service health is cheaper to check less often: every 5th tick (10s)
        if healthTick % 5 == 0 {
            pollHealth()
            checkOSUpdates()
            pollNASHealth()
            pollDSMHealth()
            pollVolumeHealth()
            checkDiskSpace()
            pollSABnzbd()
            pollArrQueues()
            pollArrHealth()
            checkPlexSessions()
            checkJellyfinSessions()
            pollOverseerr()
            pollQbit()
            maybeAlertUpdates()
            pollHardwareHealth()
            pollTimeMachine()
            checkInventorySchedule()
            refreshAvailableLogs()
            // Tailscale-only bind requested but the tailnet was down at bind time →
            // we fell back to loopback; rebind as soon as the interface exists.
            if apiBindMode == "tailscale", apiBoundFallback, APIServer.tailscaleIPv4() != nil {
                AppLog.shared.write("Tailscale interface appeared — rebinding API to it")
                restartAPI()
            }
        }
        healthTick += 1
    }

    /// Reads Software Update's cached state (no network check involved).
    /// Uses RecommendedUpdates array rather than LastUpdatesAvailable — the
    /// latter is a cached count that macOS doesn't always zero out after
    /// updates are applied, causing false positives.
    private func checkOSUpdates() {
        DispatchQueue.global(qos: .utility).async {
            let dict = NSDictionary(contentsOfFile:
                "/Library/Preferences/com.apple.SoftwareUpdate.plist")
            let recommended = dict?["RecommendedUpdates"] as? [Any] ?? []
            DispatchQueue.main.async {
                let pending = !recommended.isEmpty
                if pending && !self.pendingOSUpdates {
                    AppLog.shared.write("Update available: macOS (\(recommended.count) update\(recommended.count == 1 ? "" : "s"))")
                }
                self.pendingOSUpdates = pending
            }
        }
    }

    // MARK: Config

    /// Native macOS config location: ~/Library/Application Support/Charopos/config.json
    /// (migrated from the legacy path next to the app bundle — see migrateConfigIfNeeded).
    var configFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Charopos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Legacy config location (next to the app bundle) — migration source / read fallback.
    private var legacyConfigURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("charopos-config.json")
    }

    /// One-time copy of the legacy config into the native location. Non-destructive:
    /// the legacy file is left in place as a backup. No-op once the native file exists.
    private func migrateConfigIfNeeded() {
        let new = configFileURL
        guard !FileManager.default.fileExists(atPath: new.path),
              FileManager.default.fileExists(atPath: legacyConfigURL.path) else { return }
        try? FileManager.default.copyItem(at: legacyConfigURL, to: new)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: new.path)
        AppLog.shared.write("Config migrated to ~/Library/Application Support/Charopos/config.json (legacy file kept as backup)")
    }

    /// Read-modify-write a single boolean config key without disturbing the rest of the
    /// file. Used by the menu-bar toggles (Show Window at Startup, Hide Dock Icon) so they
    /// persist without going through the full PreferencesView save.
    func setConfigFlag(_ key: String, _ value: Bool) {
        let url = configFileURL
        var json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json[key] = value ? "true" : "false"
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// One-time migration: persist the current EFFECTIVE service URLs (override-or-default)
    /// into `config.serviceURLs` for every service, so genericizing the hardcoded
    /// `serviceDefaults` later can't change a personal install's behavior. Only fills gaps
    /// — never overwrites an existing override. No-op once every service is fully specified
    /// (and on fresh installs, where the defaults are already neutral). Must run while the
    /// personal defaults are still present (i.e. before that genericize commit).
    private func seedServiceURLsIfNeeded() {
        let fileURL = configFileURL
        guard var json = (try? Data(contentsOf: fileURL))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
        // One-time marker. This migration captured personal effective URLs into
        // config.serviceURLs before serviceDefaults were genericized — long done on
        // every existing install. It MUST run at most once: loadConfig() (which this is
        // called from) also runs after every PreferencesView.save(), and save() strips
        // serviceURLs entries equal to the now-generic default. Without the marker the
        // seeder re-adds those default-equal entries on the very next load, so each save
        // triggered a redundant config write + "Seeded…" log line — an endless ping-pong.
        if (json["seededServiceURLs"] as? String) == "true" { return }
        var su = json["serviceURLs"] as? [String: [String: String]] ?? [:]
        for s in services {
            var entry = su[s.id] ?? [:]
            if entry["url"]     == nil, let u = s.url     { entry["url"] = u }
            if entry["openURL"] == nil, let o = s.openURL { entry["openURL"] = o }
            if !entry.isEmpty { su[s.id] = entry }
        }
        json["serviceURLs"] = su
        json["seededServiceURLs"] = "true"   // never run again — the migration is complete
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        try? data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        AppLog.shared.write("Seeded effective service URLs into config (one-time migration complete)")
    }

    /// Inject `nasMountUser` into a mount URL whose authority has no `user@`
    /// (e.g. `afp://host/share` → `afp://user@host/share`). Leaves URLs that already
    /// specify a user, and URLs when no mount user is set, unchanged.
    private func mountURLWithUser(_ source: String) -> String {
        guard !nasMountUser.isEmpty, let r = source.range(of: "://") else { return source }
        let afterScheme = source[r.upperBound...]
        let authority = afterScheme.prefix { $0 != "/" }
        if authority.contains("@") { return source }
        return String(source[..<r.upperBound]) + nasMountUser + "@" + String(afterScheme)
    }

    func loadConfig() {
        migrateConfigIfNeeded()
        let url = configFileURL
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // No config yet — use hardcoded defaults and flag first-run so the app
            // shows onboarding instead of auto-running the boot sequence. All services
            // start disabled in-memory ("nothing red until the user says they run it"):
            // the placeholder roster must not poll localhost and go red behind the
            // onboarding window. Finish writes the user's real enable/disable choices.
            setupComplete = false
            disabledServices = Set(Self.serviceDefaults.map(\.id))
            // Same for optional action rows: start with only Reboot in the main window
            // (it applies to any Mac); onboarding's Actions step writes the real choices.
            disabledActions = Self.optionalActionIDs.subtracting(["reboot"])
            actionPlacements = ["reboot": ActionPlacement.main.rawValue]
            if nasUnits.isEmpty { nasUnits = Self.defaultNASUnits }
            if localVolumes.isEmpty { localVolumes = Self.defaultLocalVolumes }
            if services.isEmpty { services = Self.serviceDefaults.map { ($0.id, $0.label, $0.url, $0.openURL) } }
            return
        }
        prowlAPIKey    = json["prowlApiKey"]    as? String ?? ""
        sabAPIKey      = json["sabnzbdApiKey"]  as? String ?? ""
        sonarrAPIKey   = json["sonarrApiKey"]   as? String ?? ""
        radarrAPIKey   = json["radarrApiKey"]   as? String ?? ""
        lidarrAPIKey   = json["lidarrApiKey"]   as? String ?? ""
        prowlarrAPIKey = json["prowlarrApiKey"] as? String ?? ""
        overseerrApiKey = json["overseerrApiKey"] as? String ?? ""
        tautulliApiKey  = json["tautulliApiKey"]  as? String ?? ""
        jellyfinApiKey  = json["jellyfinApiKey"]  as? String ?? ""
        bazarrApiKey    = json["bazarrApiKey"]    as? String ?? ""
        qbitUser        = json["qbitUser"]        as? String ?? ""
        qbitPass        = json["qbitPass"]        as? String ?? ""
        synologyUser   = json["synologyUser"]   as? String ?? ""
        nasMountUser   = json["nasMountUser"]    as? String ?? ""
        disabledServices = Set((json["disabledServices"] as? [String]) ?? [])
        // Roster expansions must not surprise existing installs: any service id this
        // config has never seen starts DISABLED (no new red pills for services the
        // user doesn't run). knownServices records the roster this config has seen;
        // an absent key means the pre-expansion 9-service roster.
        let preExpansionRoster = ["sab", "sonarr", "radarr", "prowlarr", "lidarr", "plex", "tailscale", "pihole", "cloudkey"]
        let known = Set((json["knownServices"] as? [String]) ?? preExpansionRoster)
        let unseen = Set(Self.serviceDefaults.map(\.id)).subtracting(known)
        if !unseen.isEmpty {
            disabledServices.formUnion(unseen)
            // Persist both (read-modify-write so concurrent keys survive, like setConfigFlag)
            var fresh = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            fresh["disabledServices"] = Array(disabledServices)
            fresh["knownServices"] = Self.serviceDefaults.map(\.id)
            if let data = try? JSONSerialization.data(withJSONObject: fresh, options: .prettyPrinted) {
                try? data.write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            AppLog.shared.write("Service roster expanded — new services start disabled: \(unseen.sorted().joined(separator: ", "))")
        }
        clearDisabledServiceState()   // disabled services must leave no stale menubar/alert state
        disabledActions  = Set((json["disabledActions"] as? [String]) ?? [])   // default: all rows shown
        // Action roster growth mirrors the service policy: any optional action id this
        // config has never seen starts HIDDEN, so existing installs don't sprout new
        // rows on upgrade. knownActions records the optional-action roster seen so far;
        // an absent key means the pre-expansion 5-action set.
        let knownActions = Set((json["knownActions"] as? [String]) ?? Self.preExpansionActions)
        let unseenActions = Self.optionalActionIDs.subtracting(knownActions)
        if !unseenActions.isEmpty {
            disabledActions.formUnion(unseenActions)
            var fresh = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            fresh["disabledActions"] = Array(disabledActions)
            fresh["knownActions"] = Array(Self.optionalActionIDs)
            if let data = try? JSONSerialization.data(withJSONObject: fresh, options: .prettyPrinted) {
                try? data.write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            AppLog.shared.write("Action roster expanded — new actions start hidden: \(unseenActions.sorted().joined(separator: ", "))")
        }
        // Placement (v4.66): the `actionPlacements` map (id → none/menu/main) is the
        // source of truth for where each action appears. When it's absent — the first
        // launch after upgrading from the disabledActions era — derive it once (a shown
        // action → .main, a hidden one → .none) and persist, so the install keeps exactly
        // the actions it was already showing.
        if let stored = json["actionPlacements"] as? [String: String] {
            actionPlacements = stored
        } else {
            var derived: [String: String] = [:]
            for id in Self.optionalActionIDs {
                derived[id] = disabledActions.contains(id) ? ActionPlacement.none.rawValue
                                                           : ActionPlacement.main.rawValue
            }
            actionPlacements = derived
            var fresh = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            fresh["actionPlacements"] = derived
            if let data = try? JSONSerialization.data(withJSONObject: fresh, options: .prettyPrinted) {
                try? data.write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            AppLog.shared.write("Migrated action visibility to placements (\(derived.values.filter { $0 == "main" }.count) in main window)")
        }
        // Defensively enforce the 6-slot cap in memory on whatever we loaded (migration,
        // hand-edit, or downgrade could exceed it). The corrective write is deferred:
        // a failure here must never be able to abort loadConfig mid-function. (History:
        // an earlier persist fed JSONSerialization a Set — Set.filter returns a Set —
        // raising an ObjC NSException. Thrown inside applicationDidFinishLaunching,
        // AppKit SWALLOWED it: the app stayed alive but loadConfig aborted midway, so
        // every key below this line silently never loaded. The type bug is fixed; the
        // deferral stays as isolation so no future persist failure can re-create a
        // half-loaded config.)
        if clampMainWindowPlacements() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.persistActionPlacements()
            }
        }
        synologyPass   = json["synologyPass"]   as? String ?? ""
        cloudKeyHost   = json["cloudKeyHost"]   as? String ?? ""
        let rawSshKey  = json["cloudKeySshKey"] as? String ?? ""
        cloudKeySshKey = rawSshKey.isEmpty ? (NSHomeDirectory() + "/.ssh/cloudkey_ed25519") : rawSshKey
        piholePassword = json["piholePassword"] as? String ?? ""
        piholeSshTarget = json["piholeSshTarget"] as? String ?? "pi@pihole.local"
        let rawPiKey   = json["piholeSshKey"] as? String ?? ""
        piholeSshKey   = rawPiKey.isEmpty ? (NSHomeDirectory() + "/.ssh/pihole_ed25519") : rawPiKey
        diskAlertThreshold    = Double(json["diskAlertThreshold"] as? String ?? "") ?? 90.0
        notifyServices        = (json["notifyServices"]       as? String ?? "true") != "false"
        notifyStorage         = (json["notifyStorage"]        as? String ?? "true") != "false"
        notifyHost            = (json["notifyHost"]           as? String ?? "true") != "false"
        alertNASOfflineEnabled        = (json["alertNASOffline"]       as? String ?? "true") != "false"
        alertServiceDownEnabled       = (json["alertServiceDown"]      as? String ?? "true") != "false"
        alertUpdatesAvailableEnabled  = (json["alertUpdatesAvailable"] as? String ?? "true") != "false"
        alertDiskSpaceEnabled         = (json["alertDiskSpace"]        as? String ?? "true") != "false"
        inventoryEnabled      = (json["inventoryEnabled"]      as? String ?? "false") == "true"
        inventoryDays         = Int(json["inventoryDays"] as? String ?? "") ?? 7
        alertUPSOnBatteryEnabled      = (json["alertUPSOnBattery"]     as? String ?? "true") != "false"
        alertUPSLowBatteryEnabled     = (json["alertUPSLowBattery"]    as? String ?? "true") != "false"
        alertMemoryPressureEnabled    = (json["alertMemoryPressure"]   as? String ?? "true") != "false"
        alertSwapHighEnabled          = (json["alertSwapHigh"]         as? String ?? "true") != "false"
        alertExternalIPChangeEnabled  = (json["alertExternalIPChange"] as? String ?? "true") != "false"
        alertZombieProcessEnabled     = (json["alertZombieProcess"]    as? String ?? "true") != "false"
        alertNTPDriftEnabled          = (json["alertNTPDrift"]         as? String ?? "true") != "false"
        alertSMARTFailureEnabled      = (json["alertSMARTFailure"]     as? String ?? "true") != "false"
        alertSMARTReallocatedEnabled  = (json["alertSMARTReallocated"] as? String ?? "true") != "false"
        alertTimeMachineErrorEnabled  = (json["alertTimeMachineError"] as? String ?? "true") != "false"
        dashboardURLOverride  = json["dashboardURL"] as? String ?? ""
        if let v = json["setupComplete"] as? String {
            setupComplete = (v == "true")
        } else {
            // A config file exists but predates onboarding → this install is already
            // set up. Persist the flag so the state is explicit from here on.
            setupComplete = true
            setConfigFlag("setupComplete", true)
        }
        if let mode = json["apiBindMode"] as? String, ["loopback", "tailscale", "all"].contains(mode) {
            apiBindMode = mode
            allowRemoteAccess = (mode != "loopback")
        } else if let v = json["allowRemoteAccess"] as? String {
            // Pre-v4.80 config: derive the mode from the old Bool (true = the old
            // all-interfaces behavior). Settings save() writes apiBindMode from here on.
            allowRemoteAccess = (v == "true")
            apiBindMode = allowRemoteAccess ? "all" : "loopback"
        } else {
            // Existing install (has a config) with no explicit setting → preserve the prior
            // all-interfaces behavior so remote clients keep working, and persist it. A fresh
            // install (no config file at all) skips this branch and keeps the secure loopback default.
            allowRemoteAccess = true
            apiBindMode = "all"
            setConfigFlag("allowRemoteAccess", true)
        }
        ghostMonitorEnabled   = (json["ghostMonitorEnabled"]   as? String ?? "true") != "false"
        svcDownMinutes   = Int(json["svcDownMinutes"]   as? String ?? "") ?? 5
        upsBatteryLowPct = Int(json["upsBatteryLowPct"] as? String ?? "") ?? 20
        swapAlertPctRAM  = Double(json["swapAlertPct"]  as? String ?? "") ?? 25.0

        // Load NAS units — fall back to hardcoded defaults if key absent (first-run migration)
        if let arr = json["nasUnits"] as? [[String: Any]], !arr.isEmpty {
            nasUnits = arr.compactMap { d in
                guard let id        = d["id"]         as? String,
                      let label     = d["label"]       as? String,
                      let checkURL  = d["checkURL"]    as? String,
                      let openURL   = d["openURL"]     as? String,
                      let mountPoint = d["mountPoint"] as? String
                else { return nil }
                return NASUnit(id: id, label: label, checkURL: checkURL,
                               openURL: openURL, mountPoint: mountPoint,
                               mountSource: (d["mountSource"] as? String) ?? "",
                               suppressSpaceAlert: (d["suppressSpaceAlert"] as? Bool) ?? false)
            }
        } else {
            nasUnits = Self.defaultNASUnits
        }

        // Load local volumes
        if let arr = json["localVolumes"] as? [[String: Any]], !arr.isEmpty {
            localVolumes = arr.compactMap { d in
                guard let id         = d["id"]         as? String,
                      let label      = d["label"]       as? String,
                      let mountPoint = d["mountPoint"]  as? String
                else { return nil }
                return LocalVolume(id: id, label: label, mountPoint: mountPoint,
                                   suppressSpaceAlert: (d["suppressSpaceAlert"] as? Bool) ?? false)
            }
        } else {
            localVolumes = Self.defaultLocalVolumes
        }

        // Build resolved services list: defaults merged with any URL overrides from config
        let urlOverrides = json["serviceURLs"] as? [String: [String: String]] ?? [:]
        services = Self.serviceDefaults.map { svc in
            let ov = urlOverrides[svc.id]
            let resolvedURL     = ov?["url"]     ?? svc.url
            let resolvedOpenURL = ov?["openURL"] ?? svc.openURL
            return (svc.id, svc.label, resolvedURL, resolvedOpenURL)
        }
        seedServiceURLsIfNeeded()   // capture default-derived URLs into config before defaults are genericized

        // Remove stale health state for NAS IDs no longer in the list
        let liveNASIDs = Set(nasUnits.map(\.id))
        nasHealth.keys.filter     { !liveNASIDs.contains($0) }.forEach { nasHealth.removeValue(forKey: $0) }
        nasAlertState.keys.filter { !liveNASIDs.contains($0) }.forEach { nasAlertState.removeValue(forKey: $0) }
        synoSessions.keys.filter  { !liveNASIDs.contains($0) }.forEach { synoSessions.removeValue(forKey: $0) }
        // Offline counters/latches too — a NAS id removed then re-added must not
        // inherit old counts (instant offline alert on the first red poll).
        nasOfflineCount.keys.filter            { !liveNASIDs.contains($0) }.forEach { nasOfflineCount.removeValue(forKey: $0) }
        nasMountedUnreachableCount.keys.filter { !liveNASIDs.contains($0) }.forEach { nasMountedUnreachableCount.removeValue(forKey: $0) }
        nasOfflineAlerted = nasOfflineAlerted.intersection(liveNASIDs)
        let liveVolIDs = Set(localVolumes.map(\.id))
        volumeHealth.keys.filter  { !liveVolIDs.contains($0) }.forEach { volumeHealth.removeValue(forKey: $0) }
        // Disk-space Prowl debounce is keyed by NAS *and* local-volume ids — prune
        // against the union so a removed-then-readded id gets a fresh hourly window.
        let liveDiskIDs = liveNASIDs.union(liveVolIDs)
        prowlNotifiedAt.keys.filter { !liveDiskIDs.contains($0) }.forEach { prowlNotifiedAt.removeValue(forKey: $0) }

        hideDockIcon = (json["hideDockIcon"] as? String) == "true"
        NSApplication.shared.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        showWindowAtStartup = (json["showWindowAtStartup"] as? String) == "true"

        AppLog.shared.write("Config loaded")
    }

    // MARK: NAS health

    /// Consecutive failed reachability checks (~10s each) a *mounted* NAS must rack up
    /// before its light goes orange. Mounted = the volume works; an unreachable DSM web
    /// endpoint is a soft signal that blips often, so tolerate ~1 min before flagging.
    private static let nasUnreachableHoldPolls = 6

    private func pollNASHealth() {
        let fm = FileManager.default
        for nas in nasUnits {
            let mounted = fm.fileExists(atPath: nas.mountPoint)
            let id    = nas.id
            let label = nas.label
            guard let url = URL(string: nas.checkURL) else {
                let state  = mounted ? "orange" : "red"
                let reason = mounted ? "mounted (no reachability check)" : "not mounted"
                if state != nasHealth[id] { AppLog.shared.write("NAS \(label): \(reason)") }
                nasHealth[id] = state
                handleNASHealthUpdate(id: id, label: label, state: state)
                continue
            }
            healthSession.dataTask(with: url) { [weak self] _, response, error in
                let reachable = error == nil && response != nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    let state: String
                    let reason: String
                    switch (reachable, mounted) {
                    case (true,  true):
                        self.nasMountedUnreachableCount[id] = 0
                        state = "green";  reason = "online"
                    case (false, false):
                        self.nasMountedUnreachableCount[id] = 0
                        state = "red";    reason = "offline — not reachable, not mounted"
                    case (true,  false):
                        self.nasMountedUnreachableCount[id] = 0
                        state = "orange"; reason = "reachable but not mounted"
                    default: // mounted but not reachable — the volume is fine; the DSM web
                             // endpoint just blipped. Hold (staying green) until it's been
                             // unreachable for several consecutive checks before going orange,
                             // and DON'T log each holding poll — a flapping endpoint that
                             // recovers between checks would otherwise spam "(n/N, holding)".
                        let n = (self.nasMountedUnreachableCount[id] ?? 0) + 1
                        self.nasMountedUnreachableCount[id] = n
                        if n < Self.nasUnreachableHoldPolls {
                            return   // transient blip: stay green, log nothing (~10s/check)
                        }
                        state = "orange"; reason = "mounted but not reachable for \(n) checks"
                    }
                    if state != self.nasHealth[id] { AppLog.shared.write("NAS \(label): \(reason)") }
                    self.nasHealth[id] = state
                    self.handleNASHealthUpdate(id: id, label: label, state: state)
                }
            }.resume()
        }
    }

    private func handleNASHealthUpdate(id: String, label: String, state: String) {
        if state == "red" {
            let n = (nasOfflineCount[id] ?? 0) + 1
            nasOfflineCount[id] = n
            // >= 3, not == 3: with the alert toggle/master off, the count climbs past 3;
            // an exact match would then never fire after the user re-enables the alert.
            if alertNASOffline && n >= 3 && !nasOfflineAlerted.contains(id) {
                nasOfflineAlerted.insert(id)
                sendProwlNotification(event: "NAS Offline",
                                      description: "\(label) is unreachable")
            }
        } else {
            nasOfflineCount[id] = 0
            nasOfflineAlerted.remove(id)
        }
    }

    /// The display state for a NAS light, overlaying DSM status onto the base state.
    /// Health-only color, independent of any pending update: `crashed` → red,
    /// otherwise the base reachability/mount state (`nil` not-yet-polled → red).
    /// The update is reported separately via `nasHasUpdate(for:)` so the status
    /// dot can keep its real health color while a blue pill signals the update.
    func nasHealthState(for id: String) -> String {
        nasAlertState[id] == "crashed" ? "red" : (nasHealth[id] ?? "red")
    }

    /// Whether the unit has a DSM update pending — independent of its health
    /// color, so an update still surfaces on a degraded (orange/red) unit.
    func nasHasUpdate(for id: String) -> Bool {
        nasAlertState[id] == "upgrade"
    }

    // MARK: Synology DSM health alerts

    private func pollDSMHealth() {
        guard !synologyUser.isEmpty, !synologyPass.isEmpty else { return }
        for nas in nasUnits {
            // Only proceed once reachability is confirmed — nil means not yet polled
            guard nasHealth[nas.id] == "green" || nasHealth[nas.id] == "orange" else { continue }
            queryOrLogin(nas: nas)
        }
    }

    private func queryOrLogin(nas: NASUnit) {
        let id      = nas.id
        let baseURL = nas.checkURL

        func queryStatus(sid: String) {
            let path = "\(baseURL)/webapi/entry.cgi?api=SYNO.Core.System.Status&version=1&method=get&_sid=\(sid)"
            guard let url = URL(string: path) else { return }
            dsmSession.dataTask(with: url) { [weak self] data, _, error in
                guard let self else { return }
                if let error { print("[DSM:\(id)] status error: \(error)"); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { print("[DSM:\(id)] status: bad/empty response"); return }
                // Session expired or auth failure → invalidate so we re-login next poll
                guard json["success"] as? Bool == true else {
                    print("[DSM:\(id)] status: success=false — \(json)")
                    DispatchQueue.main.async { self.synoSessions.removeValue(forKey: id) }
                    return
                }
                let d = json["data"] as? [String: Any] ?? [:]
                let crashed = d["is_system_crashed"] as? Bool ?? false
                let upgrade = d["upgrade_ready"]     as? Bool ?? false
                let alertState = crashed ? "crashed" : (upgrade ? "upgrade" : "ok")
                print("[DSM:\(id)] is_system_crashed=\(crashed) upgrade_ready=\(upgrade) → \(alertState)")
                DispatchQueue.main.async { self.nasAlertState[id] = alertState }
            }.resume()
        }

        // Use cached session if still valid
        if let cached = synoSessions[id], cached.expires > Date() {
            queryStatus(sid: cached.sid)
            return
        }

        // Authenticate — credentials in query string (DSM API design)
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        let loginPath = "\(baseURL)/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=\(enc(synologyUser))&passwd=\(enc(synologyPass))&session=Charopos&format=sid"
        guard let loginURL = URL(string: loginPath) else { return }

        dsmSession.dataTask(with: loginURL) { [weak self] data, _, error in
            guard let self else { return }
            if let error { print("[DSM:\(id)] login error: \(error)"); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { print("[DSM:\(id)] login: bad/empty response"); return }
            guard json["success"] as? Bool == true,
                  let sid = (json["data"] as? [String: Any])?["sid"] as? String
            else { print("[DSM:\(id)] login failed: \(json)"); return }
            print("[DSM:\(id)] login ok, querying status…")
            let session = SynoSession(sid: sid, expires: Date().addingTimeInterval(1800))
            DispatchQueue.main.async {
                self.synoSessions[id] = session
                queryStatus(sid: sid)
            }
        }.resume()
    }

    // MARK: NAS file inventory

    /// Writes a text log of every file on every NAS mountPoint, rotates (new file each
    /// run), and prunes to the 10 most recent. Runs off the main thread.
    func runInventory() {
        guard states["inventory"] != .running else { return }
        states["inventory"] = .running
        let mounts = nasUnits.map { (label: $0.label, mp: $0.mountPoint) }
        let dir = logsDir.path
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        AppLog.shared.write("Inventory: starting (\(mounts.count) NAS units)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let file = "\(dir)/inventory_\(stamp).log"
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
            var script = "exec > \"\(esc(file))\" 2>&1\n"
            script += "echo \"Charopos NAS inventory — $(date)\"\n"
            for m in mounts {
                script += "echo; echo \"===== \(esc(m.label)) (\(esc(m.mp))) =====\"\n"
                script += "if [ -d \"\(esc(m.mp))\" ]; then find \"\(esc(m.mp))\" -type f; else echo '(not mounted)'; fi\n"
            }
            // Keep only the 10 most recent inventory logs.
            script += "ls -1t \"\(esc(dir))\"/inventory_*.log 2>/dev/null | tail -n +11 | while IFS= read -r f; do rm -f \"$f\"; done\n"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script]
            try? p.run()
            p.waitUntilExit()
            let code = p.terminationStatus
            DispatchQueue.main.async {
                self?.states["inventory"] = .finished(code: code, at: Date())
                self?.lastInventoryRun = Date()
                AppLog.shared.write("Inventory: wrote inventory_\(stamp).log (exit \(code))")
            }
        }
    }

    /// Auto-run the inventory when enabled and the configured interval has elapsed.
    private func checkInventorySchedule() {
        guard inventoryEnabled, inventoryDays > 0, states["inventory"] != .running else { return }
        // Preferred run time is 4 AM. We don't fire before then, but any tick at
        // or after 4 AM is eligible — so a run the schedule missed (Mac asleep or
        // off through the 4 o'clock hour) catches up the next time the app is
        // running. The "already ran today" guard below keeps it to once a day.
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= 4 else { return }
        let due: Bool
        if let last = lastInventoryRun {
            guard !cal.isDate(last, inSameDayAs: now) else { return }
            let days = cal.dateComponents([.day],
                                          from: cal.startOfDay(for: last),
                                          to: cal.startOfDay(for: now)).day ?? 0
            due = days >= inventoryDays
        } else {
            due = true   // never run — fire on the first 4 AM tick
        }
        if due { runInventory() }
    }

    private func checkDiskSpace() {
        let threshold = diskAlertThreshold
        // NAS units + local volumes, skipping any flagged "suppress space alerts".
        // (maybeSendDiskProwl gates on the global alertDiskSpace toggle and debounces.)
        let targets: [(id: String, label: String, mp: String)] =
            nasUnits.filter      { !$0.suppressSpaceAlert }.map { ($0.id, $0.label, $0.mountPoint) }
            + localVolumes.filter { !$0.suppressSpaceAlert }.map { ($0.id, $0.label, $0.mountPoint) }
        for t in targets {
            guard FileManager.default.fileExists(atPath: t.mp) else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: t.mp),
                      let total = (attrs[.systemSize]     as? NSNumber)?.int64Value,
                      let free  = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
                      total > 0
                else { return }
                let pct = Double(total - free) / Double(total) * 100.0
                guard pct >= threshold else { return }
                DispatchQueue.main.async { self?.maybeSendDiskProwl(id: t.id, label: t.label, pct: pct) }
            }
        }
    }

    private func maybeSendDiskProwl(id: String, label: String, pct: Double) {
        guard alertDiskSpace else { return }
        guard !prowlAPIKey.isEmpty else {
            AppLog.shared.write("Prowl: disk space alert for \(label) suppressed — API key not configured")
            return
        }
        let now = Date()
        if let last = prowlNotifiedAt[id], now.timeIntervalSince(last) < 3600 { return }
        prowlNotifiedAt[id] = now
        sendProwlNotification(event: "Disk Space Warning",
                              description: "\(label) is \(String(format: "%.1f", pct))% full")
    }

    private func maybeAlertUpdates() {
        guard alertUpdatesAvailable else { return }
        let now = Date()
        if let last = lastUpdateAlertDate, now.timeIntervalSince(last) < 86400 { return }
        var pending: [String] = []
        if !arrUpdatesAvailable.isEmpty { pending.append(arrUpdatesAvailable.map { $0.capitalized }.sorted().joined(separator: "/")) }
        if sabUpdateAvailable       { pending.append("SABnzbd") }
        if plexUpdateAvailable      { pending.append("Plex") }
        if overseerrUpdateAvailable { pending.append("Overseerr") }
        if tautulliUpdateAvailable  { pending.append("Tautulli") }
        if cloudKeyUpdateAvailable  { pending.append("UniFi") }
        if piholeUpdateAvailable    { pending.append("PiHole") }
        if dsmUpdateAvailable       { pending.append("DSM") }
        if pendingOSUpdates         { pending.append("macOS") }
        guard !pending.isEmpty else { return }
        lastUpdateAlertDate = now
        sendProwlNotification(event: "Updates Available",
                              description: pending.joined(separator: ", "))
    }

    private func flushServiceDownDigest() {
        svcDownDigestTimer = nil
        guard !svcDownPending.isEmpty else { return }
        let labels = svcDownPending.compactMap { id in services.first(where: { $0.id == id })?.label ?? id }
        svcDownPending = []
        let joined = labels.joined(separator: ", ")
        let verb   = labels.count == 1 ? "has" : "have"
        sendProwlNotification(event: "Service Down",
            description: "\(joined) \(verb) been unreachable for \(svcDownMinutes)+ minutes")
    }

    /// The machine's mDNS hostname (e.g. "MyMac.local"), read once from scutil's
    /// LocalHostName — NOT `ProcessInfo.hostName`, which returns the DDNS/WAN name.
    private static let localBonjourHost: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        let name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : "\(name).local"
    }()

    /// Link attached to Prowl notifications so a tap opens the web dashboard.
    /// Uses `dashboardURLOverride` if set, else this machine's mDNS host + API port
    /// (e.g. http://MyMac.local:8787). Empty if neither is available (→ no link).
    var dashboardURL: String {
        if !dashboardURLOverride.isEmpty { return dashboardURLOverride }
        return Self.localBonjourHost.isEmpty ? "" : "http://\(Self.localBonjourHost):\(APIServer.port)"
    }

    private func sendProwlNotification(event: String, description: String) {
        guard !prowlAPIKey.isEmpty else {
            AppLog.shared.write("Prowl: '\(event)' suppressed — API key not configured")
            return
        }
        guard let url = URL(string: "https://api.prowlapp.com/publicapi/add") else { return }
        AppLog.shared.write("Prowl: \(event) — \(description)")
        Self.prowlPOST(url: url, apiKey: prowlAPIKey, event: event, description: description,
                       priority: 1, tag: "Prowl", link: dashboardURL)
    }

    func testProwlNotification(apiKey: String) {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.prowlapp.com/publicapi/add")
        else {
            AppLog.shared.write("[Prowl Test] FAILED — API key is empty")
            return
        }
        AppLog.shared.write("[Prowl Test] Sending test notification...")
        Self.prowlPOST(url: url, apiKey: apiKey, event: "Test",
                       description: "Test notification from Charopos", priority: 0, tag: "Prowl Test",
                       link: dashboardURL)
    }

    private static func prowlPOST(url: URL, apiKey: String, event: String,
                                   description: String, priority: Int, tag: String, link: String = "") {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
              .replacingOccurrences(of: "+", with: "%2B")
              .replacingOccurrences(of: "&", with: "%26")
              .replacingOccurrences(of: "=", with: "%3D") ?? $0
        }
        // Prowl's `url` param renders as a tappable link on the notification.
        let urlParam = link.isEmpty ? "" : "&url=\(enc(link))"
        req.httpBody = "apikey=\(enc(apiKey))&application=Charopos&event=\(enc(event))&description=\(enc(description))&priority=\(priority)\(urlParam)".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                AppLog.shared.write("[\(tag)] Network error: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if status == 200 {
                AppLog.shared.write("[\(tag)] Sent '\(event)' — HTTP \(status) OK")
            } else {
                AppLog.shared.write("[\(tag)] FAILED '\(event)' — HTTP \(status)\(body.isEmpty ? "" : ": \(body)")")
            }
        }.resume()
    }

    // MARK: SABnzbd queue

    private func pollSABnzbd() {
        guard isEnabled("sab"), !sabAPIKey.isEmpty, let base = serviceBase("sab"),
              let url = URL(string: "\(base)/api?mode=queue&output=json&apikey=\(sabAPIKey)")
        else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, error == nil, let data,
                  let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let queue = json["queue"] as? [String: Any]
            else { return }
            // noofslots_total is a String in older SABnzbd versions, Int in newer ones
            let count: Int
            if let s = queue["noofslots_total"] as? String      { count = Int(s) ?? 0 }
            else if let n = queue["noofslots_total"] as? Int    { count = n }
            else                                                 { count = 0 }
            let speedKB = Double(queue["kbpersec"]   as? String ?? "0") ?? 0
            let timeleft = queue["timeleft"] as? String ?? "0:00:00"
            let parts = timeleft.split(separator: ":").compactMap { Int($0) }
            let eta   = parts.count == 3 ? parts[0] * 60 + parts[1] : nil
            let paused = queue["paused"] as? Bool ?? false
            let haveWarnings: Int
            if let s = queue["have_warnings"] as? String    { haveWarnings = Int(s) ?? 0 }
            else if let n = queue["have_warnings"] as? Int  { haveWarnings = n }
            else                                             { haveWarnings = 0 }
            DispatchQueue.main.async {
                let warning = paused || haveWarnings > 0
                if warning != (self.serviceWarnings["sab"] ?? false) {
                    if warning {
                        var detail = [String]()
                        if paused { detail.append("paused") }
                        if haveWarnings > 0 { detail.append("\(haveWarnings) warning\(haveWarnings == 1 ? "" : "s")") }
                        AppLog.shared.write("Warning: SABnzbd entered warning state (\(detail.joined(separator: ", ")))")
                    } else {
                        AppLog.shared.write("Warning: SABnzbd warning cleared")
                    }
                }
                self.sabPaused      = paused
                self.sabQueueCount  = count > 0 ? count : nil
                self.sabSpeedMBps   = count > 0 ? speedKB / 1024.0 : 0
                self.sabETAMinutes  = count > 0 ? eta : nil
                self.serviceWarnings["sab"] = warning
            }
        }.resume()
    }

    // MARK: *arr queue counts

    private func pollArrQueues() {
        if isEnabled("sonarr"), !sonarrAPIKey.isEmpty, let base = serviceBase("sonarr") {
            pollArrQueue(base: base, key: sonarrAPIKey) { [weak self] n in self?.sonarrQueueCount = n }
        }
        if isEnabled("radarr"), !radarrAPIKey.isEmpty, let base = serviceBase("radarr") {
            pollArrQueue(base: base, key: radarrAPIKey) { [weak self] n in self?.radarrQueueCount = n }
        }
        if isEnabled("lidarr"), !lidarrAPIKey.isEmpty, let base = serviceBase("lidarr") {
            pollArrQueue(base: base, key: lidarrAPIKey) { [weak self] n in self?.lidarrQueueCount = n }
        }
    }

    private func pollArrHealth() {
        for c in arrEndpoints where !c.key.isEmpty {
            let ver = arrApiVersion[c.id] ?? "v3"   // discovered per app (Sonarr/Radarr v3, Lidarr/Prowlarr v1)
            guard let url = URL(string: "\(c.base)/api/\(ver)/health") else { continue }
            var req = URLRequest(url: url)
            req.setValue(c.key, forHTTPHeaderField: "X-Api-Key")
            let id = c.id
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
                guard let self, error == nil,
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }
                let hasIssue = items.contains {
                    let t = $0["type"] as? String ?? ""
                    guard t == "warning" || t == "error" else { return false }
                    // Ignore the "update available" health warning (source "UpdateCheck") —
                    // that's already shown by the blue update pill, so it shouldn't also
                    // turn the dot orange and risk masking a real issue.
                    let src = $0["source"] as? String ?? ""
                    let msg = ($0["message"] as? String ?? "").lowercased()
                    if src == "UpdateCheck" || msg.contains("update is available") { return false }
                    return true
                }
                DispatchQueue.main.async {
                    if hasIssue != (self.serviceWarnings[id] ?? false) {
                        let label = self.services.first(where: { $0.id == id })?.label ?? id
                        AppLog.shared.write("Warning: \(label) \(hasIssue ? "entered warning state" : "warning cleared")")
                    }
                    self.serviceWarnings[id] = hasIssue
                }
            }.resume()
        }
    }

    // MARK: CloudKey update check

    private func pollCloudKey() {
        guard isEnabled("cloudkey"), !cloudKeyHost.isEmpty else { return }
        let host = cloudKeyHost
        let keyPath = cloudKeySshKey
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-i", keyPath,
                "-o", "StrictHostKeyChecking=accept-new",   // TOFU: trust+save on first connect, refuse if a saved key changes (MITM)
                "-o", "ConnectTimeout=5",
                "-o", "BatchMode=yes",
                "--", "root@\(host)",   // -- so a crafted host can't be parsed as an ssh option
                // Line 1: 1 if CloudKey OS firmware update available (firmware.yaml vs /usr/lib/version)
                // Line 2: count of adopted managed devices behind latest firmware (firmware.json vs MongoDB)
                "LATEST=$(awk '/^latest:/{f=1} /^[a-z]/{if(!/^latest:/)f=0} f && /^  version:/{print; exit}' " +
                    "/data/unifi-core/config/firmware.yaml | grep -oE 'v[0-9]+\\.[0-9]+\\.[0-9]+'); " +
                "RUNNING=$(cat /usr/lib/version 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+\\.[0-9]+' | head -1); " +
                "[ -n \"$LATEST\" ] && [ -n \"$RUNNING\" ] && [ \"$LATEST\" != \"$RUNNING\" ] && echo 1 || echo 0; " +
                "mongo --quiet --port 27117 ace --eval " +
                    "\"db.device.find({adopted:true},{model:1,version:1,_id:0}).forEach(function(d){print(d.model+' '+d.version)})\" " +
                    "2>/dev/null | python3 -c \"" +
                    "import json,sys; devs=sys.stdin.read().strip(); " +
                    "fw=json.load(open('/data/unifi/data/firmware.json')); " +
                    "vkey=[k for k in fw if k not in('last_checked','last_changed')][0]; " +
                    "models=fw[vkey].get('release',{}); " +
                    "count=sum(1 for line in devs.split(chr(10)) if len(line.split(' ',1))==2 and " +
                        "models.get(line.split(' ',1)[0],{}).get('version','') not in ('',line.split(' ',1)[1])); " +
                    "print(count)\""
            ]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = Pipe()
            guard Runner.timedRun(p, timeout: 10) else { return }
            guard p.terminationStatus == 0 else { return }
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = out.components(separatedBy: .newlines)
            let osUpdate = lines.first == "1"
            let deviceUpdate = (lines.dropFirst().first.flatMap(Int.init) ?? 0) > 0
            let hasUpdate = osUpdate || deviceUpdate
            DispatchQueue.main.async {
                if hasUpdate && !(self?.cloudKeyUpdateAvailable ?? false) {
                    let what = [osUpdate ? "OS firmware" : nil, deviceUpdate ? "device firmware" : nil]
                        .compactMap { $0 }.joined(separator: " + ")
                    AppLog.shared.write("Update available: CloudKey (\(what))")
                }
                self?.cloudKeyUpdateAvailable = hasUpdate
            }
        }
    }

    func updateCloudKey() {
        guard !cloudKeyHost.isEmpty else { return }
        let host = cloudKeyHost
        let keyPath = cloudKeySshKey
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-i", keyPath,
                "-o", "StrictHostKeyChecking=accept-new",   // TOFU: trust+save on first connect, refuse if a saved key changes (MITM)
                "-o", "ConnectTimeout=10",
                "-o", "BatchMode=yes",
                "--", "root@\(host)",   // -- so a crafted host can't be parsed as an ssh option
                // Read owner user ID, stage firmware via unifi-core Unix socket, wait for
                // download to complete, then apply (triggers reboot — SSH disconnects, expected).
                "USERID=$(python3 -c \"import json; u=json.load(open('/data/unifi-core/config/cache/users.json')); print((u[0] if isinstance(u,list) else u)['unique_id'])\"); " +
                "HDRS=\"-H X-UserId:\\ $USERID -H X-UserRole:\\ superadmin -H X-UserAccessMask:\\ 2147483647 -H X-UserPermissionMask:\\ 2147483647 -H Content-Type:\\ application/json\"; " +
                "SOCK=/data/unifi-core/config/http/uos-http.sock; " +
                "curl -s --max-time 30 --unix-socket \"$SOCK\" $HDRS -X POST http://localhost/api/firmware/update; " +
                "for i in $(seq 1 72); do " +
                    "state=$(awk '/^progress:/{f=1} f && /state:/{print $2;exit}' /data/unifi-core/config/firmware.yaml); " +
                    "[ \"$state\" = \"done\" ] && break; sleep 5; done; " +
                "[ \"$state\" = \"done\" ] || exit 1; " +
                "curl -s --max-time 10 --unix-socket \"$SOCK\" $HDRS -X POST http://localhost/api/firmware/start"
            ]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            // 10 min total: up to 6 min download + install.
            // SSH disconnects with status 255 when CloudKey reboots — expected success path.
            // Status 1 means the download guard (state != done) fired — incomplete firmware, abort.
            _ = Runner.timedRun(p, timeout: 600)
            let status = p.terminationStatus
            DispatchQueue.main.async { [weak self] in
                if status == 0 || status == 255 {
                    AppLog.shared.write("CloudKey firmware update: apply triggered (SSH exit \(status))")
                    // Optimistically clear the blue pill (matches Plex/PiHole); the 2-min
                    // pollCloudKey re-confirms once the device finishes rebooting, and re-flags
                    // if the firmware didn't actually take — so it doesn't linger blue meanwhile.
                    self?.cloudKeyUpdateAvailable = false
                } else {
                    AppLog.shared.write("CloudKey firmware update: failed — download incomplete or SSH error (exit \(status))")
                }
            }
        }
    }

    /// Runs `sudo pihole -up` on the PiHole host over SSH (key auth + NOPASSWD
    /// sudo). Output is captured to a timestamped UpdatePiHole_*.log (visible in
    /// the Latest log tab). PiHole has no update API, so this is the only path.
    func updatePiHole() {
        guard !piholeSshTarget.isEmpty else {
            AppLog.shared.write("PiHole update: no SSH target configured")
            return
        }
        let target = piholeSshTarget, keyPath = piholeSshKey
        let dir = logsDir.path
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        AppLog.shared.write("PiHole update: starting (ssh \(target))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let logFile = "\(dir)/UpdatePiHole_\(stamp).log"
            FileManager.default.createFile(atPath: logFile, contents: nil)
            let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-i", keyPath,
                "-o", "StrictHostKeyChecking=accept-new",   // TOFU: trust+save on first connect, refuse if a saved key changes (MITM)
                "-o", "ConnectTimeout=10",
                "-o", "BatchMode=yes",   // never prompt — fail fast if the key/sudo isn't set up
                "--", target,   // -- so a crafted target can't be parsed as an ssh option
                // Refresh the apt cache first (pihole -up's internal cache step fails if it's
                // stale), then update. ';' so pihole -up still runs and the overall exit
                // reflects the update itself. Needs NOPASSWD sudo for apt-get update + pihole.
                "sudo apt-get update; sudo pihole -up",
            ]
            p.standardOutput = fh ?? FileHandle.nullDevice
            p.standardError  = fh ?? FileHandle.nullDevice
            // pihole -up downloads core/web/FTL and restarts FTL; allow up to 10 min.
            _ = Runner.timedRun(p, timeout: 600)
            let status = p.terminationStatus
            try? fh?.close()
            DispatchQueue.main.async {
                guard let self else { return }
                if status == 0 {
                    AppLog.shared.write("PiHole update: completed (full output in the Updater log tab)")
                    self.piholeUpdateAvailable = false   // clear the light; next version poll re-confirms
                } else {
                    AppLog.shared.write("PiHole update: FAILED (ssh exit \(status)) — see the Updater log tab")
                    self.sendProwlNotification(event: "PiHole Update Failed",
                        description: "pihole -up exited \(status). The update may be incomplete — see the Updater log tab (common causes: SSH key/sudo not set up, or apt package cache error on the PiHole).")
                }
                self.piholeSID = nil   // FTL restarted during the update; force re-auth next poll
            }
        }
    }

    // MARK: - v4.65 Tier 1 + Tier 2 actions

    /// Row status text for a momentary action: bare last-run date/time if we have
    /// one (the "last run" label is dropped everywhere — the timestamp under a
    /// run button implies it), else the caller's fallback (empty for actions whose
    /// description would just restate the button).
    private func lastRunText(for id: String, fallback: String) -> String {
        if let last = actionLastRun[id] {
            return last.formatted(date: .abbreviated, time: .shortened)
        }
        return fallback
    }

    private func markFinished(_ id: String, ok: Bool = true) {
        states[id] = .finished(code: ok ? 0 : 1, at: Date())
        if ok { actionLastRun[id] = Date() }
    }

    /// Back Up Now — kicks off a Time Machine backup immediately. Requires a TM
    /// destination already configured in System Settings (we don't create one).
    func backupNow() {
        states["backup"] = .running
        AppLog.shared.write("Back Up Now: starting Time Machine backup (tmutil startbackup)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            p.arguments = ["startbackup"]   // returns once the backup is kicked off
            let ok = Runner.timedRun(p, timeout: 120) && p.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                AppLog.shared.write(ok ? "Back Up Now: backup started"
                                       : "Back Up Now: FAILED — is a Time Machine destination configured?")
                self.markFinished("backup", ok: ok)
            }
        }
    }

    /// Check for Updates — forces an immediate refresh of every update badge that
    /// isn't on the fast poll, instead of waiting for the hourly cycle. Check-only.
    func checkForUpdatesNow() {
        states["check-updates"] = .running
        AppLog.shared.write("Check for Updates: refreshing all update checks")
        refreshUpdateChecks()
        // The checks are fire-and-forget network calls; give them a beat to land,
        // then clear the progress state so the row settles back to "Last run …".
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.markFinished("check-updates", ok: true)
        }
    }

    /// Update Pi-hole Gravity — SSH to the Pi-hole host and run `pihole -g` to
    /// rebuild the blocklist (gravity) database. Mirrors updatePiHole()'s SSH setup.
    func updatePiHoleGravity() {
        guard !piholeSshTarget.isEmpty else {
            AppLog.shared.write("Update Pi-hole Gravity: no SSH target configured")
            markFinished("pihole-gravity", ok: false)
            return
        }
        states["pihole-gravity"] = .running
        let target = piholeSshTarget, keyPath = piholeSshKey
        let dir = logsDir.path
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        AppLog.shared.write("Update Pi-hole Gravity: starting (ssh \(target))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let logFile = "\(dir)/UpdatePiHoleGravity_\(stamp).log"
            FileManager.default.createFile(atPath: logFile, contents: nil)
            let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-i", keyPath,
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=10",
                "-o", "BatchMode=yes",
                "--", target,
                "sudo pihole -g",   // rebuild gravity from configured blocklists
            ]
            p.standardOutput = fh ?? FileHandle.nullDevice
            p.standardError  = fh ?? FileHandle.nullDevice
            _ = Runner.timedRun(p, timeout: 600)
            let status = p.terminationStatus
            try? fh?.close()
            DispatchQueue.main.async {
                guard let self else { return }
                let ok = (status == 0)
                AppLog.shared.write(ok ? "Update Pi-hole Gravity: completed (full output in the Updater log tab)"
                                       : "Update Pi-hole Gravity: FAILED (ssh exit \(status)) — see the Updater log tab")
                self.markFinished("pihole-gravity", ok: ok)
            }
        }
    }

    /// Kickstart Jellyfin — cleanly restart the Jellyfin server process, then relaunch.
    /// Jellyfin's counterpart to Kickstart Plex (but standalone: no mount chain).
    func kickstartJellyfin() {
        guard states["kickstart-jellyfin"] != .running else { return }
        states["kickstart-jellyfin"] = .running
        AppLog.shared.write("Kickstart Jellyfin: stopping Jellyfin")
        // The macOS app registers under a couple of process names across builds;
        // target both, SIGTERM with a 20s grace, then SIGKILL, then relaunch.
        let script = """
        apps=("Jellyfin" "jellyfin")
        for a in "${apps[@]}"; do pkill -TERM -x "$a" 2>/dev/null; done
        for i in $(seq 1 20); do
            alive=0
            for a in "${apps[@]}"; do pgrep -x "$a" >/dev/null && alive=1; done
            [ $alive -eq 0 ] && break
            sleep 1
        done
        for a in "${apps[@]}"; do pkill -KILL -x "$a" 2>/dev/null; done
        sleep 1
        open -a Jellyfin 2>/dev/null || true
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.terminationHandler = { _ in
            DispatchQueue.main.async { [weak self] in
                AppLog.shared.write("Kickstart Jellyfin: restarted")
                self?.markFinished("kickstart-jellyfin", ok: true)
            }
        }
        do { try p.run() } catch { markFinished("kickstart-jellyfin", ok: false) }
    }

    /// Scan Libraries — trigger an on-demand library rescan on the enabled media
    /// servers (Plex and Jellyfin) so newly added files appear without waiting.
    func scanLibraries() {
        states["scan-libraries"] = .running
        var pending = 0
        // Plex: refresh all sections. Uses the local admin token (no config needed).
        if isEnabled("plex") {
            let tokenFile = NSHomeDirectory() +
                "/Library/Application Support/Plex Media Server/.LocalAdminToken"
            if let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
                                     .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty,
               let base = serviceBase("plex"),
               let url = URL(string: "\(base)/library/sections/all/refresh") {
                pending += 1
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                URLSession.shared.dataTask(with: req) { _, resp, _ in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    AppLog.shared.write("Scan Libraries: Plex refresh \(code == 200 ? "triggered" : "HTTP \(code)")")
                }.resume()
            }
        }
        // Jellyfin: POST /Library/Refresh with the configured API key.
        if isEnabled("jellyfin"), !jellyfinApiKey.isEmpty,
           let base = serviceBase("jellyfin"),
           let url = URL(string: "\(base)/Library/Refresh") {
            pending += 1
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue(jellyfinApiKey, forHTTPHeaderField: "X-Emby-Token")
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.shared.write("Scan Libraries: Jellyfin refresh \((204...204).contains(code) || code == 200 ? "triggered" : "HTTP \(code)")")
            }.resume()
        }
        if pending == 0 {
            AppLog.shared.write("Scan Libraries: no enabled media server to scan (Plex/Jellyfin)")
        }
        // Fire-and-forget: settle the row shortly after dispatching the requests.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.markFinished("scan-libraries", ok: true)
        }
    }

    /// Clear Transcode Cache — delete the temporary transcode files Plex/Jellyfin
    /// generate. Safe: only known transcode temp dirs are emptied; media/settings
    /// are untouched and the servers regenerate these on demand.
    func clearTranscodeCache() {
        states["clear-transcode"] = .running
        let home = NSHomeDirectory()
        // Only ever the contents of these specific, regenerable cache directories.
        let dirs = [
            "\(home)/Library/Application Support/Plex Media Server/Cache/Transcode",
            "\(home)/Library/Caches/PlexMediaServer/Transcode",
            "\(home)/Library/Application Support/jellyfin/transcodes",
            "\(home)/.local/share/jellyfin/transcodes",
        ]
        AppLog.shared.write("Clear Transcode Cache: clearing transcode temp directories")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var removed = 0
            for dir in dirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries {
                    if (try? fm.removeItem(atPath: "\(dir)/\(entry)")) != nil { removed += 1 }
                }
            }
            DispatchQueue.main.async {
                AppLog.shared.write("Clear Transcode Cache: removed \(removed) item\(removed == 1 ? "" : "s")")
                self?.markFinished("clear-transcode", ok: true)
            }
        }
    }

    /// Search Subtitles (Bazarr) — best-effort trigger of Bazarr's "search for
    /// missing subtitles" over its API. Unverified against a live Bazarr; if the
    /// endpoint/version differs it logs a non-2xx and does no harm.
    func bazarrSearchSubtitles() {
        guard isEnabled("bazarr") else {
            AppLog.shared.write("Search Subtitles: Bazarr is not enabled")
            markFinished("bazarr-search", ok: false)
            return
        }
        guard !bazarrApiKey.isEmpty, let base = serviceBase("bazarr") else {
            AppLog.shared.write("Search Subtitles: no Bazarr API key configured (Settings → Services → Bazarr)")
            markFinished("bazarr-search", ok: false)
            return
        }
        states["bazarr-search"] = .running
        AppLog.shared.write("Search Subtitles: asking Bazarr to search for missing subtitles")
        // Bazarr's UI triggers "search all wanted" per media type; hit both.
        for path in ["/api/episodes/wanted/search", "/api/movies/wanted/search"] {
            guard let url = URL(string: "\(base)\(path)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue(bazarrApiKey, forHTTPHeaderField: "X-API-KEY")
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.shared.write("Search Subtitles: \(path) → \((200...299).contains(code) ? "accepted" : "HTTP \(code)")")
            }.resume()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.markFinished("bazarr-search", ok: true)
        }
    }

    /// Pause Downloads / Resume Downloads — toggle pause across the enabled download
    /// clients (SABnzbd + qBittorrent) in one tap. State is derived by downloadsPaused;
    /// we flip toward its opposite and update optimistically for immediate feedback.
    func toggleDownloadsPaused() {
        let pause = !downloadsPaused   // target state
        AppLog.shared.write("\(pause ? "Pause" : "Resume") Downloads: applying to enabled clients")

        // SABnzbd: mode=pause / mode=resume.
        if isEnabled("sab"), !sabAPIKey.isEmpty, let base = serviceBase("sab"),
           let url = URL(string: "\(base)/api?mode=\(pause ? "pause" : "resume")&output=json&apikey=\(sabAPIKey)") {
            URLSession.shared.dataTask(with: url) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.shared.write("\(pause ? "Pause" : "Resume") Downloads: SABnzbd \(code == 200 ? "ok" : "HTTP \(code)")")
            }.resume()
            sabPaused = pause   // optimistic; next SAB poll confirms
        }

        // qBittorrent: authenticate, then POST torrents/pause|resume hashes=all.
        if isEnabled("qbittorrent"), !qbitUser.isEmpty, let base = serviceBase("qbittorrent") {
            qbitPauseIntent = pause   // qBit has no global flag; track our intent
            qbitAuthenticated(base: base) { sid in
                guard let sid, let url = URL(string: "\(base)/api/v2/torrents/\(pause ? "pause" : "resume")") else { return }
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.httpMethod = "POST"
                req.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie")
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue(base, forHTTPHeaderField: "Referer")
                req.httpBody = "hashes=all".data(using: .utf8)
                URLSession.shared.dataTask(with: req) { _, resp, _ in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    AppLog.shared.write("\(pause ? "Pause" : "Resume") Downloads: qBittorrent \(code == 200 ? "ok" : "HTTP \(code)")")
                }.resume()
            }
        }
        objectWillChange.send()   // reflect the optimistic toggle immediately
    }

    /// One-shot qBittorrent login → SID for a manual action (uses the cached SID if
    /// the poller already has one; otherwise logs in fresh). Mirrors pollQbit's auth.
    private func qbitAuthenticated(base: String, completion: @escaping (String?) -> Void) {
        if let sid = qbitSID { completion(sid); return }
        var formAllowed = CharacterSet.urlQueryAllowed
        formAllowed.remove(charactersIn: "&=+")
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? $0 }
        guard let loginURL = URL(string: "\(base)/api/v2/auth/login") else { completion(nil); return }
        var req = URLRequest(url: loginURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(base, forHTTPHeaderField: "Referer")
        req.httpBody = "username=\(enc(qbitUser))&password=\(enc(qbitPass))".data(using: .utf8)
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            let body = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let setCookie = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") ?? ""
            let sid: String? = setCookie.range(of: "SID=").map {
                String(setCookie[$0.upperBound...].prefix { $0 != ";" })
            }
            DispatchQueue.main.async {
                if body == "Ok.", let sid, !sid.isEmpty { self?.qbitSID = sid; completion(sid) }
                else { completion(nil) }
            }
        }.resume()
    }

    /// Unified "run this service's update" entry point, so every surface (web,
    /// server desktop, Remote) kicks off the same action. Arr/SAB run their update
    /// scripts; CloudKey/Plex/PiHole call their dedicated update methods.
    func runServiceUpdate(_ serviceId: String) {
        switch serviceId {
        case "sonarr", "radarr", "lidarr", "prowlarr":
            if let item = Self.items.first(where: { $0.id == "arr" }) { run(item) }
        case "sab":
            if let item = Self.items.first(where: { $0.id == "sab-update" }) { run(item) }
        case "cloudkey": updateCloudKey()
        case "plex":     updatePlex()
        case "pihole":   updatePiHole()
        default: break
        }
    }

    private func pollArrQueue(base: String, key: String, completion: @escaping (Int) -> Void) {
        guard let url = URL(string: "\(base)/api/v3/queue?pageSize=1") else { return }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard error == nil, let data,
                  let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = json["totalRecords"] as? Int
            else { return }
            DispatchQueue.main.async { completion(total) }
        }.resume()
    }

    // MARK: Local volume health

    private func pollVolumeHealth() {
        for vol in localVolumes {
            let id    = vol.id
            let label = vol.label
            let mp    = vol.mountPoint
            let suppress = vol.suppressSpaceAlert
            guard FileManager.default.fileExists(atPath: mp) else {
                // Local drives are optional: unmounted is "grey" (idle), NOT red — it is
                // not a fault and must not raise the overall status / menubar icon.
                if volumeHealth[id] != "grey" { AppLog.shared.write("Volume \(label): unmounted") }
                volumeHealth[id] = "grey"
                // Allow re-capture of the device id on the next mount; keep the
                // persisted value so it's available for a remount in the meantime.
                deviceCapturedThisMount.remove(id)
                continue
            }
            // Mounted: remember its BSD device once per mount so we can remount later.
            captureVolumeDeviceIfNeeded(id: id, mountPoint: mp)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mp),
                      let total = (attrs[.systemSize]     as? NSNumber)?.int64Value,
                      let free  = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
                      total > 0
                else {
                    DispatchQueue.main.async {
                        if self?.volumeHealth[id] != "orange" {
                            AppLog.shared.write("Volume \(label): disk attributes unavailable")
                        }
                        self?.volumeHealth[id] = "orange"
                    }
                    return
                }
                let pct = Double(total - free) / Double(total) * 100.0
                DispatchQueue.main.async {
                    let threshold = self?.diskAlertThreshold ?? 90.0
                    // Raw toggle, NOT the gated alertDiskSpace: the light is a health
                    // indicator, so muting Storage *notifications* must not turn it off.
                    let alertOn   = self?.alertDiskSpaceEnabled ?? true
                    // Orange only when disk alerts are enabled globally AND this drive isn't exempt.
                    let newState  = (pct >= threshold && alertOn && !suppress) ? "orange" : "green"
                    let prev      = self?.volumeHealth[id]
                    if newState != prev {
                        if newState == "orange" {
                            AppLog.shared.write("Volume \(label): \(String(format: "%.1f", pct))% used (above \(Int(threshold))% threshold)")
                        } else {
                            AppLog.shared.write("Volume \(label): \(prev == "grey" ? "mounted, " : "")\(String(format: "%.1f", pct))% used")
                        }
                    }
                    self?.volumeHealth[id] = newState
                }
            }
        }
    }

    /// Records the BSD device identifier backing a mounted volume so a later
    /// remount can target the device directly. Runs `diskutil` at most once per
    /// mount session (cleared when the volume unmounts) to avoid per-tick cost.
    private func captureVolumeDeviceIfNeeded(id: String, mountPoint: String) {
        guard !deviceCapturedThisMount.contains(id) else { return }
        deviceCapturedThisMount.insert(id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["info", mountPoint]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch {
                DispatchQueue.main.async { self?.deviceCapturedThisMount.remove(id) }
                return
            }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            // Line looks like "   Device Identifier:        disk10s1"
            let dev = out.split(separator: "\n")
                .first(where: { $0.contains("Device Identifier:") })?
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
            guard let dev, !dev.isEmpty else {
                DispatchQueue.main.async { self?.deviceCapturedThisMount.remove(id) }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.volumeDevice[id] != dev {
                    self.volumeDevice[id] = dev
                    AppLog.shared.write("Volume \(id): remembered device /dev/\(dev) for remount")
                }
            }
        }
    }

    // MARK: Host hardware health

    private func pollHardwareHealth() {
        pollUPS()
        pollMemoryPressure()
        pollSwapUsage()
        pollZombieProcesses()
        pollExternalIP()
        pollNTPDrift()
        pollSMARTStatus()
    }

    private func pollUPS() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["-g", "batt"]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError  = Pipe()
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let onBattery = out.contains("'Battery Power'")
            // Parse percentage from e.g. "85%;"
            var pct: Int? = nil
            for line in out.components(separatedBy: "\n") where line.contains("%") {
                for part in line.components(separatedBy: .whitespaces) {
                    let clean = part.replacingOccurrences(of: ";", with: "")
                    if clean.hasSuffix("%"), let val = Int(clean.dropLast()) {
                        pct = val; break
                    }
                }
                if pct != nil { break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let pctStr = pct.map { " (\($0)%)" } ?? ""
                if onBattery != self.upsOnBattery {
                    if onBattery {
                        AppLog.shared.write("UPS: switched to battery power\(pctStr)")
                        if self.alertUPSOnBattery {
                            self.sendProwlNotification(event: "UPS on Battery",
                                description: "Server running on battery power\(pct.map { " — \($0)% remaining" } ?? "")")
                        }
                    } else {
                        AppLog.shared.write("UPS: mains power restored\(pctStr)")
                        self.lowBatteryAlerted = false
                    }
                }
                self.upsOnBattery = onBattery
                if let p = pct {
                    let lowThreshold = self.upsBatteryLowPct
                    // Gate BEFORE latching: if the toggle/master is off when the level first
                    // drops, stay unlatched so re-enabling mid-outage still alerts.
                    if p <= lowThreshold && onBattery && !self.lowBatteryAlerted, self.alertUPSLowBattery {
                        self.lowBatteryAlerted = true
                        AppLog.shared.write("UPS: battery low (\(p)%)")
                        self.sendProwlNotification(event: "UPS Battery Low",
                            description: "UPS battery at \(p)% — server may shut down soon")
                    } else if p > lowThreshold + 10 {
                        self.lowBatteryAlerted = false
                    }
                    self.upsBatteryPct = p
                }
            }
        }
    }

    private func pollMemoryPressure() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError  = Pipe()
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let level: String
            if out.contains("Critical") { level = "critical" }
            else if out.contains("Warn") { level = "warn" }
            else                         { level = "normal" }
            DispatchQueue.main.async {
                guard let self else { return }
                if level == "critical" {
                    self.memPressureCriticalCount += 1
                } else {
                    self.memPressureCriticalCount = 0
                    if level == "normal" { self.memPressureAlerted = false }
                }
                if level != self.memoryPressure {
                    AppLog.shared.write("Memory pressure: \(level)")
                }
                self.memoryPressure = level
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if level == "critical" && self.memPressureCriticalCount >= 3 && !self.memPressureAlerted,
                   self.alertMemoryPressure {
                    self.memPressureAlerted = true
                    self.sendProwlNotification(event: "Memory Pressure Critical",
                        description: "System memory pressure is critical")
                }
            }
        }
    }

    /// Physical RAM in GB.
    private var physicalMemoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0 }
    /// Swap-high threshold in GB, derived as a percent of physical RAM so it
    /// self-sizes across hardware (4 GB swap means very different things on a
    /// 16 GB vs a 192 GB machine). The alert still also requires elevated pressure.
    private var swapThresholdGB: Double { physicalMemoryGB * swapAlertPctRAM / 100.0 }

    private func pollSwapUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
            p.arguments     = ["vm.swapusage"]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError  = Pipe()
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let out   = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let words = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            var usedGB: Double = 0
            for (i, word) in words.enumerated() where word == "used" {
                if i + 2 < words.count, words[i + 1] == "=" {
                    let valStr = words[i + 2]
                    if valStr.hasSuffix("M"), let val = Double(valStr.dropLast()) { usedGB = val / 1024 }
                    else if valStr.hasSuffix("G"), let val = Double(valStr.dropLast()) { usedGB = val }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let isHigh = usedGB > self.swapThresholdGB
                if isHigh {
                    self.swapHighCount += 1
                    self.swapLowCount   = 0
                } else {
                    self.swapLowCount  += 1
                    self.swapHighCount  = 0
                    self.swapSeenNormal = true
                }
                let gb = String(format: "%.1f", usedGB)
                if self.swapHighCount == 1 { AppLog.shared.write("Swap: \(gb) GB in use") }
                // High swap ALONE is normal on modern macOS — it swaps proactively even with
                // plenty of free RAM, so swap routinely sits at 1–3 GB with no real pressure.
                // Only alert when swap is high AND the kernel actually reports elevated memory
                // pressure (warn/critical); otherwise this fires constantly on healthy swap.
                let pressureElevated = self.memoryPressure != "normal"
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if isHigh && pressureElevated && self.swapHighCount >= 3 && self.swapSeenNormal && !self.swapHighAlerted,
                   self.alertSwapHigh {
                    self.swapHighAlerted = true
                    self.sendProwlNotification(event: "High Swap Usage",
                        description: "\(gb) GB swap in use under \(self.memoryPressure) memory pressure")
                } else if !isHigh && self.swapLowCount >= 3 && self.swapHighAlerted {
                    AppLog.shared.write("Swap: usage returned to normal")
                    self.swapHighAlerted = false
                }
                self.swapUsedGB = usedGB
            }
        }
    }

    private func pollZombieProcesses() {
        guard !zombiePolling else { return }
        zombiePolling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["aux"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()
            guard (try? p.run()) != nil else {
                DispatchQueue.main.async { self?.zombiePolling = false }
                return
            }
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let zombies = out.components(separatedBy: "\n").compactMap { line -> String? in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard parts.count > 10 else { return nil }
                // `ps aux` STAT column is index 7; a zombie's state starts with "Z".
                // Match the column specifically — not a " Z " substring, which would
                // misfire on any command line containing a standalone "Z" token.
                guard parts[7].hasPrefix("Z") || line.contains("<defunct>") else { return nil }
                return parts[10...].joined(separator: " ")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.zombiePolling = false
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if !zombies.isEmpty && !self.zombieAlerted, self.alertZombieProcess {
                    self.zombieAlerted = true
                    AppLog.shared.write("Zombie processes (\(zombies.count)): \(zombies.joined(separator: ", "))")
                    self.sendProwlNotification(event: "Zombie Processes",
                        description: "\(zombies.count) zombie process(es) detected")
                } else if zombies.isEmpty {
                    self.zombieAlerted = false
                }
            }
        }
    }

    private func pollExternalIP() {
        let now = Date()
        guard lastExternalIPCheck.map({ now.timeIntervalSince($0) > 300 }) ?? true else { return }
        lastExternalIPCheck = now
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.ipify.org")!) { [weak self] data, _, _ in
            guard let data,
                  let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.externalIP.isEmpty {
                    AppLog.shared.write("External IP: \(ip)")
                } else if ip != self.externalIP {
                    AppLog.shared.write("External IP changed: \(self.externalIP) → \(ip)")
                    if self.alertExternalIPChange {
                        self.sendProwlNotification(event: "External IP Changed",
                            description: "IP changed from \(self.externalIP) to \(ip)")
                    }
                }
                self.externalIP = ip
            }
        }
        task.resume()
    }

    private func pollNTPDrift() {
        let now = Date()
        guard lastNTPCheck.map({ now.timeIntervalSince($0) > 300 }) ?? true else { return }
        lastNTPCheck = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sntp")
            p.arguments = ["-t", "5", "time.apple.com"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe
            guard Runner.timedRun(p, timeout: 8) else { return }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // Output: "+0.004791 +/- 0.073027 time.apple.com 17.x.x.x"
            var offsetSec: Double? = nil
            for line in out.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let first = parts.first, let val = Double(first) {
                    offsetSec = val; break
                }
            }
            DispatchQueue.main.async {
                guard let self, let offset = offsetSec else { return }
                let ms = abs(offset) * 1000
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if ms > 500 && !self.ntpDriftAlerted, self.alertNTPDrift {
                    self.ntpDriftAlerted = true
                    let msStr = String(format: "%.0f", ms)
                    AppLog.shared.write("NTP drift: \(msStr) ms — clock may be unsynchronised")
                    self.sendProwlNotification(event: "Clock Drift",
                        description: "NTP offset \(msStr) ms — check system time settings")
                } else if ms <= 100 {
                    self.ntpDriftAlerted = false
                }
            }
        }
    }

    private func pollSMARTStatus() {
        let now = Date()
        guard lastSMARTCheck.map({ now.timeIntervalSince($0) > 3600 }) ?? true else { return }
        lastSMARTCheck = now
        let smartctlCandidates = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"]
        guard let smartctl = smartctlCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Enumerate physical disks via diskutil list.
            let lp = Process()
            lp.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            lp.arguments = ["list"]
            let listPipe = Pipe()
            lp.standardOutput = listPipe
            lp.standardError  = Pipe()
            guard Runner.timedRun(lp, timeout: 5) else { return }
            let listOut = String(decoding: listPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let disks = listOut.components(separatedBy: "\n")
                .filter { $0.hasPrefix("/dev/disk") }
                .compactMap { line -> String? in
                    guard !line.contains("synthesized") && !line.contains("virtual") && !line.contains("disk image") else { return nil }
                    return line.components(separatedBy: .whitespaces).first
                }
            var failedDisks:      [String]         = []
            var reallocated:      [(String, Int)]  = []
            var healthyDisks:     [String]         = []
            for disk in disks {
                // Health status.
                let hp = Process()
                hp.executableURL = URL(fileURLWithPath: smartctl)
                hp.arguments = ["-H", disk]
                let hPipe = Pipe()
                hp.standardOutput = hPipe
                hp.standardError  = Pipe()
                guard Runner.timedRun(hp, timeout: 15) else { continue }
                let hOut = String(decoding: hPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if hOut.contains("FAILED") { failedDisks.append(disk) }
                else if hOut.contains("PASSED") { healthyDisks.append(disk) }
                // Reallocated sector count (SATA attribute 5).
                let ap = Process()
                ap.executableURL = URL(fileURLWithPath: smartctl)
                ap.arguments = ["-A", disk]
                let aPipe = Pipe()
                ap.standardOutput = aPipe
                ap.standardError  = Pipe()
                guard Runner.timedRun(ap, timeout: 15) else { continue }
                let aOut = String(decoding: aPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for line in aOut.components(separatedBy: "\n") where line.contains("Reallocated_Sector_Ct") {
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let raw = parts.last, let count = Int(raw), count > 0 {
                        reallocated.append((disk, count))
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !healthyDisks.isEmpty || !failedDisks.isEmpty {
                    AppLog.shared.write("SMART: \(healthyDisks.map { "\($0) PASSED" }.joined(separator: ", "))\(failedDisks.isEmpty ? "" : " | FAILED: \(failedDisks.joined(separator: ", "))")")
                }
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if self.alertSMARTFailure {
                    for disk in failedDisks where !self.smartFailedAlerted.contains(disk) {
                        self.smartFailedAlerted.insert(disk)
                        self.sendProwlNotification(event: "SMART Failure",
                            description: "\(disk) health check FAILED — drive may be failing")
                    }
                }
                // Clear alerted state for disks that are no longer failing.
                self.smartFailedAlerted = self.smartFailedAlerted.intersection(Set(failedDisks))
                // Gate before latching so re-enabling the alert mid-condition still fires.
                if self.alertSMARTReallocated {
                    for (disk, count) in reallocated where !self.smartReallocatedAlerted.contains(disk) {
                        self.smartReallocatedAlerted.insert(disk)
                        AppLog.shared.write("SMART: \(disk) has \(count) reallocated sector(s)")
                        self.sendProwlNotification(event: "SMART Warning",
                            description: "\(disk) — \(count) reallocated sector(s) detected (early degradation)")
                    }
                }
            }
        }
    }

    private func pollHealth() {
        for service in services where isEnabled(service.id) {
            if let urlString = service.url, let url = URL(string: urlString) {
                let id = service.id
                healthSession.dataTask(with: url) { _, response, error in
                    let ok = (error == nil && response != nil)
                    DispatchQueue.main.async {
                        let svcLabel = self.services.first(where: { $0.id == id })?.label ?? id
                        if ok {
                            if self.serviceHealth[id] == false {
                                AppLog.shared.write("Service \(svcLabel): recovered")
                            }
                            self.serviceHealth[id] = true
                            self.serviceFailCount[id] = 0
                            self.svcDownSince.removeValue(forKey: id)
                            self.svcDownAlerted.remove(id)
                            self.svcDownPending.removeAll(where: { $0 == id })
                        } else {
                            let n = (self.serviceFailCount[id] ?? 0) + 1
                            self.serviceFailCount[id] = n
                            if n >= 2 {
                                if self.serviceHealth[id] != false {
                                    AppLog.shared.write("Service \(svcLabel): unreachable")
                                }
                                self.serviceHealth[id] = false
                                if self.svcDownSince[id] == nil { self.svcDownSince[id] = Date() }
                                if self.alertServiceDown,
                                   let since = self.svcDownSince[id],
                                   Date().timeIntervalSince(since) > Double(self.svcDownMinutes) * 60,
                                   !self.svcDownAlerted.contains(id) {
                                    self.svcDownAlerted.insert(id)
                                    if !self.svcDownPending.contains(id) {
                                        self.svcDownPending.append(id)
                                    }
                                    if self.svcDownDigestTimer == nil {
                                        self.svcDownDigestTimer = Timer.scheduledTimer(
                                            withTimeInterval: 20, repeats: false) { [weak self] _ in
                                            DispatchQueue.main.async { self?.flushServiceDownDigest() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if ok && id == "pihole" { DispatchQueue.main.async { self.checkPiHoleEnabled() } }
                }.resume()
            } else if service.id == "tailscale" {
                checkTailscale()
            }
        }
    }

    /// `scheme://host[:port]` parsed from a service's configured health URL (path stripped),
    /// for building that service's API requests — so polling follows the user's config
    /// instead of a hardcoded localhost:port. nil if the service isn't configured / URL
    /// unparseable (callers skip polling it).
    /// The key `CertPinStore` files a host under, derived from a configured URL.
    /// Must match `PinningTrustDelegate`'s format: bare host on 443, `host:port`
    /// otherwise.
    static func pinKey(forURL raw: String) -> String? {
        guard let u = URL(string: raw), let host = u.host, !host.isEmpty else { return nil }
        let port = u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
        return port == 443 ? host : "\(host):\(port)"
    }

    /// The name this pinned host goes by elsewhere in the app — a NAS unit's
    /// label, a service's label. nil when nothing in the roster maps to it.
    func labelForPinnedHost(_ key: String) -> String? {
        if let nas = nasUnits.first(where: { Self.pinKey(forURL: $0.checkURL) == key }) { return nas.label }
        if let svc = services.first(where: { ($0.url).flatMap(Self.pinKey(forURL:)) == key }) { return svc.label }
        return nil
    }

    private func serviceBase(_ id: String) -> String? {
        guard let raw = services.first(where: { $0.id == id })?.url,
              let u = URL(string: raw), let host = u.host else { return nil }
        return "\(u.scheme ?? "http")://\(host)\(u.port.map { ":\($0)" } ?? "")"
    }

    /// PiHole v6 API base (the legacy /admin/api.php was removed in v6) — derived from the
    /// configured PiHole service URL. nil if PiHole isn't configured (short-circuits its polls).
    private var piholeAPIBase: String? { serviceBase("pihole").map { "\($0)/api" } }

    /// Poll PiHole v6: ensure a session, then read block status + version info.
    /// Needs the app password from Preferences (Settings → API on the PiHole).
    private func checkPiHoleEnabled() {
        guard isEnabled("pihole"), !piholePassword.isEmpty else { return }
        ensurePiHoleSession { [weak self] sid in
            guard let self, let sid else { return }
            self.piholeGET("dns/blocking", sid: sid) { [weak self] json in
                guard let self, let blocking = json?["blocking"] as? String else { return }
                let disabled = (blocking == "disabled")
                if disabled != (self.serviceWarnings["pihole"] ?? false) {
                    AppLog.shared.write("Warning: PiHole \(disabled ? "disabled" : "re-enabled")")
                }
                self.serviceWarnings["pihole"] = disabled
            }
            self.piholeGET("info/version", sid: sid) { [weak self] json in
                guard let self, let version = json?["version"] as? [String: Any] else { return }
                func outdated(_ comp: String) -> Bool {
                    guard let c = version[comp] as? [String: Any],
                          let local  = (c["local"]  as? [String: Any])?["version"] as? String,
                          let remote = (c["remote"] as? [String: Any])?["version"] as? String,
                          !local.isEmpty, !remote.isEmpty else { return false }
                    return local != remote
                }
                let avail = outdated("core") || outdated("web") || outdated("ftl")
                if avail != self.piholeUpdateAvailable {
                    AppLog.shared.write("PiHole update \(avail ? "available" : "cleared")")
                }
                self.piholeUpdateAvailable = avail
            }
        }
    }

    /// Returns a valid PiHole v6 session id (cached until expiry), authenticating
    /// with the app password via POST /api/auth when needed.
    private func ensurePiHoleSession(_ completion: @escaping (String?) -> Void) {
        if let sid = piholeSID, Date() < piholeSIDExpiry { completion(sid); return }
        // Respect the post-failure backoff so we don't hammer FTL's login limiter.
        guard Date() >= piholeNextAuth else { completion(nil); return }
        guard let base = piholeAPIBase, let url = URL(string: "\(base)/auth") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["password": piholePassword])
        // Use the longer-timeout session: PiHole's FTL deliberately delays each
        // auth (~1s, and backs off further after failed attempts), which exceeds
        // healthSession's 2s reachability timeout.
        dsmSession.dataTask(with: req) { [weak self] data, resp, _ in
            let session = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["session"] as? [String: Any]
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async {
                guard let self else { completion(nil); return }
                if session?["valid"] as? Bool == true, let sid = session?["sid"] as? String {
                    let validity = session?["validity"] as? Double ?? 300
                    self.piholeSID = sid
                    self.piholeSIDExpiry = Date().addingTimeInterval(max(60, validity - 30))
                    self.piholeNextAuth = .distantPast
                    completion(sid)
                } else {
                    self.piholeSID = nil
                    // Back off 3 min before the next attempt — long enough for FTL's
                    // rate limit (HTTP 429) or session cap to clear without hammering.
                    self.piholeNextAuth = Date().addingTimeInterval(180)
                    let msg = (session?["message"] as? String) ?? "http \(code)"
                    AppLog.shared.write("PiHole: auth failed — \(msg) (http \(code)); backing off 3 min")
                    completion(nil)
                }
            }
        }.resume()
    }

    /// GET a PiHole v6 endpoint with the session id; clears the cached sid on 401
    /// so the next poll re-authenticates. Handler runs on the main queue.
    private func piholeGET(_ path: String, sid: String, _ handler: @escaping ([String: Any]?) -> Void) {
        guard let base = piholeAPIBase, let url = URL(string: "\(base)/\(path)") else { handler(nil); return }
        var req = URLRequest(url: url)
        req.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            let unauthorized = (resp as? HTTPURLResponse)?.statusCode == 401
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if unauthorized { self?.piholeSID = nil }
                handler(json)
            }
        }.resume()
    }

    /// Connected to the tailnet = some interface holds a Tailscale IP
    /// (the reserved 100.64.0.0/10 range). The IP exists only while
    /// Tailscale is up and connected, and checking interfaces directly
    /// avoids the CLI's IPC quirks when spawned from another app.
    private func checkTailscale() {
        var ok = false
        var ifaddrList: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddrList) == 0 {
            var ptr = ifaddrList
            while let entry = ptr {
                if let sa = entry.pointee.ifa_addr,
                   sa.pointee.sa_family == sa_family_t(AF_INET) {
                    let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                    }
                    if (ip & 0xFFC0_0000) == 0x6440_0000 {   // 100.64.0.0/10
                        ok = true
                        break
                    }
                }
                ptr = entry.pointee.ifa_next
            }
            freeifaddrs(ifaddrList)
        }
        serviceHealth["tailscale"] = ok
    }

    private func checkProcess(_ pgrepArgs: [String], _ set: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = pgrepArgs
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let alive = (proc.terminationStatus == 0)
            DispatchQueue.main.async { set(alive) }
        }
        try? p.run()
    }

    private func pollUpdateLastRuns() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        func latest(prefix: String) -> Date? {
            files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
                 .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                 .max()
        }
        updateArrLastRun = latest(prefix: "UpdateArr_")
        sabUpdateLastRun = latest(prefix: "UpdateSAB_")
        dsmUpdateLastRun = latest(prefix: "UpdateDSM_")
    }

    private func pollLogTail() {
        let snap = logSnapshot(for: logChoice)
        if snap.lines != logTail { logTail = snap.lines }
        if snap.source != logTailSource { logTailSource = snap.source }
    }

    /// Full content (capped at the last 1000 lines) of the log matching
    /// a choice. Used by the local UI and the remote API.
    /// Service ids among the v4.52 additions whose log file was found on disk this
    /// poll — drives which "new service" tabs appear in the Logs dropdown (all
    /// surfaces). Refreshed on the 10s health tick.
    @Published var availableNewLogs: Set<String> = []

    /// Best-effort log locations for the v4.52 service additions, as (directory,
    /// base-filename) candidates tried in order — the first existing file (or the
    /// newest file whose name starts with the base's stem, for dated/rotated logs)
    /// wins. Installs vary widely, so these are guesses; the presence gate means a
    /// wrong guess simply hides the tab rather than showing a broken one.
    /// UNVERIFIED against live installs (the maintainer runs none of these yet).
    private func newServiceLogCandidates(_ id: String) -> [(dir: String, base: String)] {
        let h = NSHomeDirectory()
        switch id {
        case "jellyfin":    return [("\(h)/.local/share/jellyfin/log",                    "log_.log"),
                                    ("\(h)/Library/Application Support/jellyfin/log",      "log_.log")]
        case "bazarr":      return [("\(h)/.config/bazarr/log",                            "bazarr.log"),
                                    ("\(h)/Library/Application Support/Bazarr/log",        "bazarr.log")]
        case "overseerr":   return [("\(h)/.config/overseerr/logs",                        "overseerr.log"),
                                    ("\(h)/Library/Application Support/Overseerr/logs",    "overseerr.log")]
        case "tautulli":    return [("\(h)/.config/Tautulli/logs",                         "tautulli.log"),
                                    ("\(h)/Library/Application Support/Tautulli/logs",     "tautulli.log")]
        case "qbittorrent": return [("\(h)/Library/Application Support/qBittorrent/logs",  "qbittorrent.log"),
                                    ("\(h)/.config/qBittorrent/logs",                      "qbittorrent.log")]
        default:            return []
        }
    }

    /// Resolve the current log file for a v4.52 service, or nil if none found.
    private func newServiceLogURL(_ id: String) -> URL? {
        let fm = FileManager.default
        for (dir, base) in newServiceLogCandidates(id) {
            let live = URL(fileURLWithPath: "\(dir)/\(base)")
            if fm.fileExists(atPath: live.path) { return live }
            let stem = (base as NSString).deletingPathExtension
            if let entries = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey]),
               let newest = entries.filter({ $0.lastPathComponent.hasPrefix(stem) })
                                   .max(by: {
                                       let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                                       let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                                       return a < b
                                   }) {
                return newest
            }
        }
        return nil
    }

    /// Recompute which new-service log tabs to surface (enabled AND a file exists).
    private func refreshAvailableLogs() {
        let ids = ["jellyfin", "bazarr", "overseerr", "tautulli", "qbittorrent"]
        availableNewLogs = Set(ids.filter { isEnabled($0) && newServiceLogURL($0) != nil })
    }

    func logSnapshot(for choice: LogChoice) -> (source: String, lines: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return ("No logs folder yet", []) }

        func modDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        // Strip ANSI codes and CR, trim trailing blank lines.
        func readLines(_ url: URL) -> [String] {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let clean = raw
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Array(lines.reversed()
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .reversed())
        }

        let logs = files.filter { $0.pathExtension == "log" }

        // Resolve a third-party service's current log. Installs differ — some put
        // logs under ~/.config/<App>/logs, others under ~/Library/Application
        // Support/<App>/logs — so probe both, prefer the live "<base>" file, and
        // fall back to the newest rotated file (<stem>.N) if the live one is absent.
        func serviceLog(_ folder: String, _ base: String) -> (source: String, lines: [String]) {
            let home = fm.homeDirectoryForCurrentUser
            let dirs = [home.appendingPathComponent(".config/\(folder)/logs"),
                        home.appendingPathComponent("Library/Application Support/\(folder)/logs")]
            let stem = (base as NSString).deletingPathExtension
            for dir in dirs {
                let live = dir.appendingPathComponent(base)
                if fm.fileExists(atPath: live.path) {
                    return (live.lastPathComponent, Array(readLines(live).suffix(1000)))
                }
                if let entries = try? fm.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
                   let newest = entries.filter({ $0.lastPathComponent.hasPrefix(stem) })
                                       .max(by: { modDate($0) < modDate($1) }) {
                    return (newest.lastPathComponent, Array(readLines(newest).suffix(1000)))
                }
            }
            return ("\(folder) log not found", [])
        }

        switch choice {
        case .auto:
            guard let url = logs.max(by: { modDate($0) < modDate($1) }) else {
                return ("No log file yet", [])
            }
            return (url.lastPathComponent, Array(readLines(url).suffix(1000)))

        case .charopos:
            let url = logsDir.appendingPathComponent("charopos.log")
            guard fm.fileExists(atPath: url.path) else { return ("charopos.log (not yet written)", []) }
            return ("charopos.log", Array(readLines(url).suffix(1000)))

        case .updater:
            // Merge the latest Arr, DSM, SAB, and PiHole update logs oldest-first.
            let sources: [(prefix: String, label: String)] = [
                ("UpdateArr_", "Arr"), ("UpdateDSM_", "DSM"), ("UpdateSAB_", "SAB"),
                ("UpdatePiHole_", "PiHole"),
            ]
            var sections: [(mod: Date, label: String, name: String, url: URL)] = []
            for (prefix, label) in sources {
                if let url = logs.filter({ $0.lastPathComponent.hasPrefix(prefix) })
                                 .max(by: { modDate($0) < modDate($1) }) {
                    sections.append((modDate(url), label, url.lastPathComponent, url))
                }
            }
            guard !sections.isEmpty else { return ("No updater logs yet", []) }
            sections.sort { $0.mod < $1.mod }
            var allLines: [String] = []
            for s in sections {
                allLines.append("── \(s.label): \(s.name) ──")
                allLines += readLines(s.url)
                allLines.append("")
            }
            let names = sections.map { $0.label }.joined(separator: " · ")
            return ("Updater (\(names))", Array(allLines.suffix(1000)))

        case .mount:
            guard let url = logs.filter({ $0.lastPathComponent.hasPrefix("SynologyMount_") })
                                 .max(by: { modDate($0) < modDate($1) }) else {
                return ("No log file yet", [])
            }
            return (url.lastPathComponent, Array(readLines(url).suffix(1000)))

        case .iperf:
            let url = logsDir.appendingPathComponent("iperf3-server.log")
            guard fm.fileExists(atPath: url.path) else { return ("No log file yet", []) }
            return (url.lastPathComponent, Array(readLines(url).suffix(1000)))

        case .inventory:
            guard let url = logs.filter({ $0.lastPathComponent.hasPrefix("inventory_") })
                                 .max(by: { modDate($0) < modDate($1) }) else {
                return ("No inventory log yet", [])
            }
            return (url.lastPathComponent, Array(readLines(url).suffix(1000)))

        case .sonarr:   return serviceLog("Sonarr",   "sonarr.txt")
        case .radarr:   return serviceLog("Radarr",   "radarr.txt")
        case .lidarr:   return serviceLog("Lidarr",   "lidarr.txt")
        case .prowlarr: return serviceLog("Prowlarr", "prowlarr.txt")
        case .sab:      return serviceLog("SABnzbd",  "sabnzbd.log")
        case .jellyfin, .bazarr, .overseerr, .tautulli, .qbittorrent:
            if let url = newServiceLogURL(choice.rawValue) {
                return (url.lastPathComponent, Array(readLines(url).suffix(1000)))
            }
            return ("\(choice.label) log not found", [])

        }
    }

    /// Stop the watcher whether or not this app started it.
    func stopWatcher() {
        if let owned = processes["watch"] {
            owned.terminate()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", Self.watcherFileName]
            try? p.run()
        }
        watcherAlive = false
    }

    /// Stop the iperf3 server (always external: the script nohup-s it).
    func stopIperf() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "iperf3"]
        try? p.run()
        iperfAlive = false
    }

    /// Queue badge count for a service light. Returns nil when no badge applies.
    func badge(for serviceId: String) -> Int? {
        switch serviceId {
        case "sab":         return sabQueueCount
        case "sonarr":      return sonarrQueueCount
        case "radarr":      return radarrQueueCount
        case "lidarr":      return lidarrQueueCount
        case "overseerr":   return overseerrPendingCount
        case "qbittorrent": return qbitDownloadCount
        default:            return nil
        }
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDir)
    }

    /// UI Preview cycles representative scenarios (every 4s) so every status/light
    /// combination — update-only, update+warning, streaming, queue badges, NAS &
    /// volume states, and each overall-status level (Degraded/Attention/Update/
    /// Streaming/All Clear) — can be eyeballed on all three surfaces at once.
    private static let previewScenarioNames = ["Degraded", "Attention", "Update", "Streaming", "All Clear"]

    func activateUIPreview() {
        previewScenario = 0
        applyPreviewScenario(0)
        AppLog.shared.write("UI Preview ON — cycling \(Self.previewScenarioNames.joined(separator: " → ")) every 4s")
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.uiPreviewMode else { return }
                self.previewScenario = (self.previewScenario + 1) % Self.previewScenarioNames.count
                self.applyPreviewScenario(self.previewScenario)
            }
        }
    }

    func deactivateUIPreview() {
        previewTimer?.invalidate(); previewTimer = nil
        serviceHealth   = [:]
        serviceWarnings = [:]
        sabQueueCount = nil; sonarrQueueCount = nil; radarrQueueCount = nil; lidarrQueueCount = nil
        plexStreamCount    = nil
        sabUpdateAvailable = false
        cloudKeyUpdateAvailable = false
        plexUpdateAvailable = false
        piholeUpdateAvailable = false
        arrUpdatesAvailable = []
        nasHealth     = [:]
        nasAlertState = [:]
        volumeHealth  = [:]
        // Health/queue/NAS/volume state restores on the next 2s/10s pollAll, but the
        // update flags only refresh at launch + hourly — re-run them now so real update
        // indicators (e.g. an available *arr/SAB/Plex update) come back immediately
        // instead of staying dark for up to an hour after leaving preview.
        refreshUpdateChecks()
    }

    private func applyPreviewScenario(_ i: Int) {
        // Baseline: everything healthy/quiet; each scenario tweaks from here.
        // Seed every *configured* service and NAS green — hardcoding the owner's
        // roster ids would leak topology and render a stranger's units grey/red
        // during preview (their ids wouldn't be in the mock dictionaries).
        serviceHealth = Dictionary(services.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a })
        serviceWarnings = [:]
        sabQueueCount = nil; sonarrQueueCount = nil; radarrQueueCount = nil; lidarrQueueCount = nil
        plexStreamCount = nil
        sabUpdateAvailable = false; cloudKeyUpdateAvailable = false
        plexUpdateAvailable = false; piholeUpdateAvailable = false
        arrUpdatesAvailable = []
        nasHealth = Dictionary(nasUnits.map { ($0.id, "green") }, uniquingKeysWith: { a, _ in a })
        nasAlertState = [:]
        // Scenario variations pick NAS units by position (safe for any roster size).
        let nasIDs = nasUnits.map(\.id)
        let nid: (Int) -> String? = { nasIDs.indices.contains($0) ? nasIDs[$0] : nil }
        // Seed every *real* configured volume green so the preview never leaves one
        // nil (which would render idle-grey and mask the scenario). uniquingKeysWith
        // (not uniqueKeysWithValues) so a duplicate volume id in config can't trap.
        volumeHealth = Dictionary(localVolumes.map { ($0.id, "green") }, uniquingKeysWith: { a, _ in a })
        let firstVol = localVolumes.first?.id   // for the "near-full" override below

        switch i {
        case 0:  // Degraded — exercises the whole grid at once
            serviceHealth["prowlarr"] = false                   // red (unreachable)
            serviceWarnings = ["lidarr": true, "radarr": true]  // orange warnings
            arrUpdatesAvailable = ["sonarr", "radarr"]          // sonarr: update only (blue); radarr: update + warning (blue + orange dot)
            sabQueueCount = 3                                   // queue badge
            plexStreamCount = 2                                 // streaming spinner
            cloudKeyUpdateAvailable = true                      // blue update pill
            piholeUpdateAvailable = true                        // blue update pill
            if let n = nid(1) { nasHealth[n] = "orange"; nasAlertState[n] = "upgrade" }
            if let n = nid(2) { nasHealth[n] = "red" }
            // Update pill on a healthy unit too (green dot + blue pill — only possible
            // now that update is decoupled from health).
            if let n = nid(3) { nasAlertState[n] = "upgrade" }
            if let v = firstVol { volumeHealth[v] = "orange" }  // volume near-full
        case 1:  // Attention — warnings only, nothing down
            serviceWarnings = ["pihole": true]                  // PiHole disabled (orange)
            if let n = nid(1) { nasHealth[n] = "orange" }
            if let v = firstVol { volumeHealth[v] = "orange" }
        case 2:  // Update — updates pending across the board, otherwise clean
            arrUpdatesAvailable = ["sonarr", "radarr", "lidarr", "prowlarr"]
            sabUpdateAvailable = true; cloudKeyUpdateAvailable = true
            plexUpdateAvailable = true; piholeUpdateAvailable = true
            if let n = nid(0) { nasAlertState[n] = "upgrade" }
        case 3:  // Streaming — all clear + Plex playing (overall "Streaming")
            plexStreamCount = 3
        default: // All Clear — baseline (overall green)
            break
        }
    }

    // MARK: Time Machine backup-health check
    //
    // We do NOT scrape `log show backupd messageType==error`. On modern macOS,
    // backupd logs a flood of benign internal events at error level (XPC teardown,
    // launchservices, mountpoint validity, snapshot metadata, xattr writes, FileIDMap),
    // especially for network/SMB destinations — and there is no reliable
    // "Backup completed successfully" marker to scrape against. Maintaining a blocklist
    // of those strings was endless whack-a-mole and caused repeated false alerts.
    //
    // Instead we read the only signal that matters — the most recent COMPLETED backup
    // timestamp — from /Library/Preferences/com.apple.TimeMachine.plist
    // (Destinations[].SnapshotDates). That file is world-readable (no Full Disk Access,
    // no root), and we alert only when no backup has completed in `tmStaleThreshold`.

    private nonisolated static let tmPlistURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")
    private static let tmStaleThreshold: TimeInterval = 24 * 3600   // alert if no completed backup in 24h
    private static let tmStaleAlertKey = "tmStaleAlertedAt"         // persisted: no relaunch spam during a real stall

    private func pollTimeMachine() {
        guard alertTimeMachineError, !prowlAPIKey.isEmpty else { return }
        let now = Date()
        if let last = lastTMCheck, now.timeIntervalSince(last) < 3600 { return }
        lastTMCheck = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let latest = Self.latestBackupDate()
            DispatchQueue.main.async { [weak self] in self?.handleTMBackupHealth(latest: latest) }
        }
    }

    /// Most recent completed-backup date across all Time Machine destinations, or nil
    /// if TM has no destinations / has never backed up / the plist can't be read.
    private nonisolated static func latestBackupDate() -> Date? {   // reads a static-let plist path only; safe off the main actor
        guard let data = try? Data(contentsOf: tmPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let dests = plist["Destinations"] as? [[String: Any]] else { return nil }
        var latest: Date? = nil
        for dest in dests {
            guard let dates = dest["SnapshotDates"] as? [Date], let m = dates.max() else { continue }
            if latest == nil || m > latest! { latest = m }
        }
        return latest
    }

    private func handleTMBackupHealth(latest: Date?) {
        guard alertTimeMachineError, !prowlAPIKey.isEmpty else { return }
        // nil = TM not configured / never backed up / unreadable plist → don't cry wolf.
        guard let latest else { return }
        let now = Date()
        guard now.timeIntervalSince(latest) > Self.tmStaleThreshold else {
            UserDefaults.standard.removeObject(forKey: Self.tmStaleAlertKey)   // healthy → reset dedup
            return
        }
        // Stale: alert at most once per 24h while it stays stale (persisted across relaunches).
        if let last = UserDefaults.standard.object(forKey: Self.tmStaleAlertKey) as? Date,
           now.timeIntervalSince(last) < 24 * 3600 { return }
        UserDefaults.standard.set(now, forKey: Self.tmStaleAlertKey)
        sendProwlNotification(event: "Time Machine Stalled",
            description: "No completed Time Machine backup since \(latest.formatted(date: .abbreviated, time: .shortened)). Check the backup destination.")
    }

    // MARK: Remote API support

    private(set) var api: APIServer?

    func startAPI() {
        guard api == nil else { return }
        api = APIServer(runner: self)
        api?.start()
    }

    /// Rebind the API listener after `apiBindMode` changes. Small delay between
    /// cancel and rebind so the old listener releases the port first. The actual
    /// binding (including a Tailscale fallback) is logged by APIServer.start().
    func restartAPI() {
        api?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.apiPortConflict = false
            self.api?.start()
        }
    }

    /// Generate a fresh 256-bit token, persist it (0600), and rebind with a NEW
    /// APIServer instance — the token is immutable per instance (read once in init).
    /// Every connected client gets 401 until it re-pastes the new token. Rotation is
    /// strictly manual (this method + the Settings button); existing installs'
    /// tokens are never rotated automatically.
    func rotateAPIToken() {
        let fresh = APIServer.generateToken()
        let tokenURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("launcher-remote-token.txt")
        do {
            try fresh.write(to: tokenURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.shared.write("Token rotation FAILED to write \(tokenURL.lastPathComponent): \(error.localizedDescription)")
            return   // keep the old token + listener — a half-rotation would lock everyone out
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        api?.stop()
        api = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startAPI()
            AppLog.shared.write("API token rotated — remote clients must re-authenticate with the new token")
        }
    }

    func item(withID id: String) -> ScriptItem? {
        Self.items.first { $0.id == id }
    }

    /// Status text for an item, shared by the local UI and the remote API.
    func displayStatus(for item: ScriptItem) -> (text: String, color: String, action: String) {
        // Reboot blocked by an app that won't quit — surface a Force Reboot control on
        // every surface (server desktop, Remote app, web) via one server-driven "force"
        // action, instead of leaving each UI to infer the hung state on its own.
        if item.id == "reboot" && rebootHung {
            return ("Apps blocking shutdown — Force Reboot?", "red", "force")
        }
        switch item.id {
        case "inventory":
            if state(of: item) == .running { return ("Inventorying…", "blue", "progress") }
            if let last = lastInventoryRun {
                return (last.formatted(date: .abbreviated, time: .shortened), "secondary", "run")
            }
            return ("Never run", "secondary", "run")
        case "kickstart":
            if kickstarting {
                return ("Kickstarting…", "blue", "progress")
            }
            if let last = kickstartLastRun {
                return (last.formatted(date: .abbreviated, time: .shortened), "secondary", "run")
            }
            return ("Not run this session", "secondary", "run")
        case "watch":
            return (watcherAlive ? "Running" : "Not running",
                    watcherAlive ? "green" : "secondary",
                    watcherAlive ? "stop" : "run")
        case "iperf":
            return (iperfAlive ? "Running" : "Not running",
                    iperfAlive ? "green" : "secondary",
                    iperfAlive ? "stop" : "run")
        // v4.65 actions ---------------------------------------------------------
        case "pause-downloads":
            // Toggle: "stop" action while active (tap pauses), "run" once paused
            // (tap resumes). Surfaces relabel these to Pause/Resume for this id.
            if state(of: item) == .running { return ("Working…", "blue", "progress") }
            return downloadsPaused ? ("Paused", "secondary", "run")
                                   : ("Active", "green", "stop")
        // v4.79: never-run fallbacks emptied — the description just restated the
        // button; the row shows only the timestamp once it has actually run.
        case "backup":
            if state(of: item) == .running { return ("Backing up…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "check-updates":
            if state(of: item) == .running { return ("Checking…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "pihole-gravity":
            if state(of: item) == .running { return ("Updating gravity…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "kickstart-jellyfin":
            if state(of: item) == .running { return ("Kickstarting…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "scan-libraries":
            if state(of: item) == .running { return ("Scanning…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "clear-transcode":
            if state(of: item) == .running { return ("Clearing…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        case "bazarr-search":
            if state(of: item) == .running { return ("Searching…", "blue", "progress") }
            return (lastRunText(for: item.id, fallback: ""), "secondary", "run")
        default:
            switch state(of: item) {
            case .idle:
                if item.id == "mount" {
                    let boot = bootDate ?? Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
                    if let last = lastMountRunDate, last > boot {
                        let time = last.formatted(date: .omitted, time: .shortened)
                        return (time, "green", "run")
                    }
                    return ("Not run since boot", "secondary", "run")
                }
                if item.id == "arr" {
                    if !arrUpdatesAvailable.isEmpty {
                        return ("App Update Ready", "blue", "run")
                    }
                    if let last = updateArrLastRun {
                        return (last.formatted(date: .abbreviated, time: .shortened),
                                "secondary", "run")
                    }
                }
                if item.id == "sab-update" {
                    if sabUpdateAvailable {
                        return ("Update Available", "blue", "run")
                    }
                    if let last = sabUpdateLastRun {
                        return (last.formatted(date: .abbreviated, time: .shortened),
                                "secondary", "run")
                    }
                }
                if item.id == "dsm-update" {
                    if dsmUpdateAvailable {
                        return ("Update Available", "blue", "run")
                    }
                    if let last = dsmUpdateLastRun {
                        return (last.formatted(date: .abbreviated, time: .shortened),
                                "secondary", "run")
                    }
                    return ("All DSMs up to date", "secondary", "run")
                }
                if item.id == "reboot" {
                    // macOS-update state is shown under the version (header), not here —
                    // a remote reboot can't apply it, so it must not ride the Reboot action.
                    if let boot = bootDate {
                        return (boot.formatted(date: .abbreviated, time: .shortened),
                                "secondary", "run")
                    }
                    return ("Restarts this Mac", "secondary", "run")
                }
                return ("Not run this session", "secondary", "run")
            case .running:
                if item.id == "reboot" {
                    // rebootHung is handled by the override at the top of this function.
                    return ("Rebooting…", "red", "progress")
                }
                return ("Running…", "blue", "progress")
            case .finished(let code, let at):
                let time = at.formatted(date: .omitted, time: .shortened)
                if code == 0 {
                    return ("Finished at \(time)", "green", "run")
                }
                // dsm-update exits 1 when nothing needed updating — treat as success
                if item.id == "dsm-update" && code == 1 {
                    return ("\(time) — all current", "secondary", "run")
                }
                // Fail-loud: report the script's own error line when we captured one,
                // so a failure explains itself instead of showing a bare exit code.
                if let reason = lastRunError[item.id], !reason.isEmpty {
                    return ("Failed \(time): \(reason)", "red", "run")
                }
                return ("Exited with code \(code) at \(time)", "red", "run")
            }
        }
    }

    /// Full state snapshot served to remote clients.
    func statusPayload() -> [String: Any] {
        // Hidden action rows are omitted from the payload, so the Remote app and web
        // dashboard drop them without any client-side knowledge of the setting.
        let items: [[String: Any]] = Self.items.filter { isActionEnabled($0.id) }.map { item in
            let s = displayStatus(for: item)
            // placement lets desktop clients (the Remote app) show only main-window
            // actions while the web shows them all. Non-optional internal rows report
            // "main" (they're filtered by the surfaces' own order lists regardless).
            let place = Self.optionalActionIDs.contains(item.id) ? placement(of: item.id).rawValue
                                                                 : ActionPlacement.main.rawValue
            // (rebootHung reaches clients as action:"force" below — no separate flag needed.)
            return ["id": item.id, "title": item.title, "info": item.info,
                    "status": s.text, "color": s.color, "action": s.action, "placement": place]
        }
        let svcPayload: [[String: Any]] = enabledServices.map { s in
            var d: [String: Any] = ["id": s.id, "label": s.label,
                                    "ok": serviceHealth[s.id] ?? false,
                                    "warn": serviceWarnings[s.id] ?? false]
            // Remote clients get openURL (Tailscale hostnames etc.);
            // only fall back to url if there's no dedicated openURL.
            if let link = s.openURL ?? s.url { d["url"] = link }
            if let b = badge(for: s.id) { d["badge"] = b }
            if s.id == "cloudkey" && cloudKeyUpdateAvailable { d["update"] = true; d["updateScript"] = "cloudkey-update" }
            if s.id == "plex"     && plexUpdateAvailable     { d["update"] = true; d["updateScript"] = "plex-update" }
            // PiHole update runs `sudo pihole -up` over SSH (no update API).
            if s.id == "pihole"   && piholeUpdateAvailable   { d["update"] = true; d["updateScript"] = "pihole-update" }
            if (s.id == "plex" && plexStreamCount != nil) || (s.id == "jellyfin" && jellyfinStreamCount != nil) { d["streaming"] = true }
            // Overseerr/Tautulli updates open the web UI (no runnable update action → no updateScript).
            if s.id == "overseerr" && overseerrUpdateAvailable { d["update"] = true }
            if s.id == "tautulli"  && tautulliUpdateAvailable  { d["update"] = true }
            if arrUpdatesAvailable.contains(s.id) {
                d["update"] = true; d["updateScript"] = "arr"
            }
            if s.id == "sab" && sabUpdateAvailable {
                d["update"] = true; d["updateScript"] = "sab-update"
            }
            return d
        }
        let nasData: [[String: Any]] = nasUnits.map { nas in
            // Health and update are independent: `state` is the health color,
            // `update` flags a pending DSM update (so it can show over any base).
            ["id": nas.id, "label": nas.label,
             "state": nasHealthState(for: nas.id),
             "update": nasHasUpdate(for: nas.id),
             "noEmbed": true,   // Synology DSM blocks iframe embedding — open in a new tab
             "url": nas.openURL]
        }
        let volData: [[String: Any]] = localVolumes.map { vol in
            ["id": vol.id, "label": vol.label,
             "state": volumeHealth[vol.id] ?? "grey",
             "update": false,    // local volumes have no update concept
             "mountable": true]   // remote/web: click toggles mount/unmount via /mount|/unmount
            // no "url" key — remote/web renders without a link
        }
        return ["items": items,
                "anyScriptRunning": anyScriptRunning,
                "services": svcPayload,
                "nasUnits": nasData + volData,
                "version": appVersion,
                "osUpdate": pendingOSUpdates,
                // New-service log tabs the remote/web dropdowns should surface
                // (only those whose log file was found on the server).
                "availableLogs": Array(availableNewLogs)]
    }
}
