import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement
import CryptoKit

// MARK: - Model

struct ScriptItem: Identifiable {
    let id: String
    let title: String
    let fileName: String
    let longRunning: Bool   // stays running until stopped (e.g. the volume watcher)
    let info: String
}

struct NASUnit: Identifiable {
    var id: String
    var label: String
    var checkURL: String   // HTTPS :5001, used for health checks and SYNO_URLS env
    var openURL: String    // DSM web UI or QuickConnect URL
    var mountPoint: String // /Volumes/...
    var mountSource: String = ""   // optional mount URL (afp://… or smb://…) for the NAS Refresh script
    var suppressSpaceAlert: Bool = false   // exempt from the disk-space Prowl alert
}

struct LocalVolume: Identifiable {
    var id: String
    var label: String
    var mountPoint: String
    var suppressSpaceAlert: Bool = false   // drives expected to stay full: no orange light / alert over threshold
}

enum RunState: Equatable {
    case idle
    case running
    case finished(code: Int32, at: Date)
}

// MARK: - Log selection

enum LogChoice: String, CaseIterable, Identifiable {
    case auto, charopos, updater, mount, iperf, inventory
    case sonarr, radarr, lidarr, prowlarr, sab
    case jellyfin, bazarr, overseerr, tautulli, qbittorrent
    var id: String { rawValue }
    /// v4.52 service additions — their log locations vary by install, so these tabs
    /// only appear in the dropdown when Runner actually finds a log file (see
    /// `availableNewLogs`). Keeps the menu honest instead of showing dead tabs.
    var isNewServiceLog: Bool {
        switch self {
        case .jellyfin, .bazarr, .overseerr, .tautulli, .qbittorrent: return true
        default: return false
        }
    }
    var label: String {
        switch self {
        case .auto:      return "Latest"
        case .charopos:  return "Charopos"
        case .updater:   return "Updater"
        case .mount:     return "Volume Refresh"
        case .iperf:     return "iperf3 Server"
        case .inventory: return "NAS Inventory"
        case .sonarr:    return "Sonarr"
        case .radarr:    return "Radarr"
        case .lidarr:    return "Lidarr"
        case .prowlarr:  return "Prowlarr"
        case .sab:       return "SABnzbd"
        case .jellyfin:  return "Jellyfin"
        case .bazarr:    return "Bazarr"
        case .overseerr: return "Overseerr"
        case .tautulli:  return "Tautulli"
        case .qbittorrent: return "qBittorrent"
        }
    }
    var tabLabel: String {
        switch self {
        case .auto:      return "Latest"
        case .charopos:  return "Charopos"
        case .updater:   return "Updater"
        case .mount:     return "Mounts"
        case .iperf:     return "iperf3"
        case .inventory: return "Inventory"
        case .sonarr:    return "Sonarr"
        case .radarr:    return "Radarr"
        case .lidarr:    return "Lidarr"
        case .prowlarr:  return "Prowlarr"
        case .sab:       return "SABnzbd"
        case .jellyfin:  return "Jellyfin"
        case .bazarr:    return "Bazarr"
        case .overseerr: return "Overseerr"
        case .tautulli:  return "Tautulli"
        case .qbittorrent: return "qBit"
        }
    }
}

// MARK: - App event log

final class AppLog {
    static let shared = AppLog()
    private let url: URL = {
        let dir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("charopos.log")
    }()
    private let maxBytes = 2 * 1024 * 1024
    private let q = DispatchQueue(label: "charopos.applog", qos: .utility)
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    func write(_ msg: String) {
        q.async { [self] in
            let line = "[\(fmt.string(from: Date()))] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0 > maxBytes {
                let archive = url.deletingPathExtension().appendingPathExtension("log.1")
                try? FileManager.default.removeItem(at: archive)
                try? FileManager.default.moveItem(at: url, to: archive)
            }
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - TLS certificate pinning (trust on first use)

/// Remembers the TLS identity of the local hosts Charopos talks to over HTTPS
/// (Synology DSM, Pi-hole, UniFi) so a certificate that changes underneath us is
/// treated as a fault instead of accepted silently.
///
/// Why this exists: these boxes serve self-signed certificates, so the system
/// trust store can't vouch for them, and the delegate this replaced accepted
/// *any* certificate. The DSM login carries the NAS admin account and password,
/// so "accept anything" meant anyone able to answer for the NAS on the LAN could
/// collect them. This is the TLS counterpart of the `accept-new` host-key policy
/// the SSH paths already use.
///
/// Two kinds of host are remembered:
///  - `system` — the chain validated against the system trust store (a real
///    certificate, e.g. DSM's Let's Encrypt). It keeps being validated that way,
///    so ordinary renewals don't trip the pin.
///  - `tofu` — self-signed or private CA. The public key seen on first contact
///    is authoritative; a different key is a mismatch.
///
/// Thread-safe: URLSession delegate callbacks arrive on a background queue.
final class CertPinStore {
    static let shared = CertPinStore()

    enum Verdict {
        case learned    // first contact — remembered, allowed
        case matched    // same identity as last time
        case upgraded   // a self-signed host now presents a system-trusted chain
        case mismatch   // identity changed — caller must refuse
    }

    private let defaultsKey = "certPins"
    private let lock = NSLock()
    /// Alert sink installed by Runner (log line + Prowl). Fired at most once per
    /// host/key pair per launch so a persistent mismatch can't spam.
    private var alertHandler: ((_ event: String, _ detail: String) -> Void)?
    private var alerted: Set<String> = []

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Abbreviated key fingerprint for logs and Settings.
    static func short(_ fingerprint: String) -> String {
        fingerprint.isEmpty ? "unknown" : String(fingerprint.prefix(12)) + "…"
    }

    /// Installed by Runner once the Prowl key is loaded.
    func onMismatch(_ handler: @escaping (String, String) -> Void) {
        lock.lock(); alertHandler = handler; lock.unlock()
    }

    // MARK: Persistence — UserDefaults: [host: ["mode": …, "fp": …, "seen": …]]

    private func loadPins() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
    }
    private func savePins(_ pins: [String: [String: String]]) {
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }

    /// The hosts we currently remember, for the Settings list.
    var summary: [(host: String, mode: String, firstSeen: String, fingerprint: String)] {
        lock.lock(); defer { lock.unlock() }
        return loadPins().map { (host: $0.key,
                                 mode: $0.value["mode"] ?? "tofu",
                                 firstSeen: $0.value["seen"] ?? "",
                                 fingerprint: $0.value["fp"] ?? "") }
            .sorted { $0.host < $1.host }
    }

    /// Forget one host's certificate — the surgical version of `forgetAll`, for
    /// when a single box was rebuilt or re-issued and the other pins are still good.
    func forget(_ host: String) {
        lock.lock()
        var pins = loadPins()
        pins.removeValue(forKey: host)
        savePins(pins)
        alerted = alerted.filter { !$0.hasPrefix("\(host)|") }
        lock.unlock()
        AppLog.shared.write("Certificates: forgot the pinned certificate for \(host) — the next connection will trust what it presents")
    }

    /// Forget every remembered certificate; the next contact with each host
    /// trusts whatever it presents. For use after a deliberate certificate
    /// change, which is otherwise indistinguishable from an attack.
    func forgetAll() {
        lock.lock()
        savePins([:])
        alerted.removeAll()
        lock.unlock()
        AppLog.shared.write("Certificates: forgot all pinned certificates — the next connection to each host will trust what it presents")
    }

    /// Decide what to do about the certificate `fingerprint` just presented by
    /// `host`, recording the outcome. `systemTrusted` is the result of ordinary
    /// system trust evaluation.
    func verdict(host: String, systemTrusted: Bool, fingerprint: String) -> Verdict {
        lock.lock()
        var pins = loadPins()
        let today = Self.stamp.string(from: Date())
        let previousMode = pins[host]?["mode"]
        let previousFP   = pins[host]?["fp"] ?? ""
        let result: Verdict
        var mismatchReason: String? = nil

        switch previousMode {
        case nil:
            pins[host] = ["mode": systemTrusted ? "system" : "tofu", "fp": fingerprint, "seen": today]
            result = .learned
        case "system":
            if systemTrusted {
                // A renewal is expected on this path — track the current key.
                pins[host]?["fp"] = fingerprint
                result = .matched
            } else {
                result = .mismatch
                mismatchReason = "this host's certificate used to be trusted by the system and no longer is"
            }
        default:  // "tofu"
            if fingerprint == previousFP {
                result = .matched
            } else if systemTrusted {
                // The owner installed a real certificate — the normal trust
                // model can take over from here.
                pins[host] = ["mode": "system", "fp": fingerprint, "seen": today]
                result = .upgraded
            } else {
                result = .mismatch
                mismatchReason = "public key changed (was \(Self.short(previousFP)), now \(Self.short(fingerprint)))"
            }
        }
        if mismatchReason == nil { savePins(pins) }
        // Dedupe per host+key so a standing mismatch alerts once, not every poll.
        let shouldAlert = mismatchReason != nil && alerted.insert("\(host)|\(fingerprint)").inserted
        let handler = alertHandler
        lock.unlock()

        switch result {
        case .learned:
            AppLog.shared.write("Certificates: learned \(systemTrusted ? "system-trusted" : "self-signed") certificate for \(host) (key \(Self.short(fingerprint)))")
        case .upgraded:
            AppLog.shared.write("Certificates: \(host) now presents a system-trusted certificate — pin upgraded")
        case .matched:
            break
        case .mismatch:
            AppLog.shared.write("Certificates: REFUSED \(host) — \(mismatchReason ?? "identity changed"). If you replaced this host's certificate yourself, clear the pin in Settings → Services → Certificates.")
            if shouldAlert {
                handler?("Certificate Changed",
                         "\(host) presented a different TLS certificate, so Charopos blocked the connection rather than send credentials to a host it can't verify. If you replaced the certificate yourself, clear the pin in Settings → Services → Certificates.")
            }
        }
        return result
    }
}

/// URLSession delegate for Charopos's HTTPS traffic to local infrastructure.
/// Certificates are checked against `CertPinStore`; a host whose identity
/// changed is refused outright rather than handed DSM/Pi-hole credentials.
final class PinningTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = space.port == 443 ? space.host : "\(space.host):\(space.port)"
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        guard let fingerprint = Self.publicKeyFingerprint(trust) else {
            // With no readable public key we can't tell this host from an
            // impostor, so treat it the way a changed certificate is treated.
            AppLog.shared.write("Certificates: REFUSED \(host) — could not read the server's public key")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch CertPinStore.shared.verdict(host: host, systemTrusted: systemTrusted, fingerprint: fingerprint) {
        case .learned, .matched, .upgraded:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .mismatch:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// SHA-256 of the leaf's public key, base64. Pinning the *key* rather than
    /// the whole certificate means a re-issue that keeps the key — the common
    /// renewal path — doesn't read as a change.
    private static func publicKeyFingerprint(_ trust: SecTrust) -> String? {
        guard let key = SecTrustCopyKey(trust),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
