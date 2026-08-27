import SwiftUI
import AppKit
import Combine
import Network
import ServiceManagement
import Security

// MARK: - Remote API server

/// Minimal token-authenticated HTTP server for remote control.
/// Authenticated routes (header  X-Token: <token>):
///   GET  /status              -> JSON snapshot of all item states + log tail
///   GET  /log/<choice>        -> full log snapshot for one source
///   GET  /update/remote-app   -> zip of the companion Remote app (self-update)
///   POST /run/<id>, /run/boot, /stop/<id>, /mount/<id>, /unmount/<id>
///   POST /run/{kickstart, reboot-force, cloudkey-update, plex-update,
///              pihole-update}, /run/dsm-update-single/<id>
/// Public (no token; the dashboard shell must load before a token is stored):
///   GET  /, /index.html, /icon.png, /artwork.png, /menubar-icon-*.png
/// The token is CSPRNG-generated on first launch (constant-time compared) and
/// stored next to the app in launcher-remote-token.txt (0o600); it can be rotated
/// manually via Runner.rotateAPIToken() (Settings → Remote Access). The listener's
/// bind scope follows runner.apiBindMode: "loopback" (default), "tailscale" (the
/// Mac's CGNAT 100.64.0.0/10 address only), or "all" interfaces.
@MainActor
final class APIServer {
    static let port: UInt16 = 8787

    private unowned let runner: Runner
    private var listener: NWListener?
    let token: String

    init(runner: Runner) {
        self.runner = runner
        let tokenURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("launcher-remote-token.txt")
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            token = existing
        } else {
            let fresh = Self.generateToken()
            try? fresh.write(to: tokenURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            token = fresh
        }
    }

    /// A 256-bit token from the OS CSPRNG, base64url-encoded (no padding) so it's
    /// header/URL/localStorage-safe. Replaces the old `UUID().uuidString` (a v4 UUID
    /// has a fixed/known structure and isn't a documented crypto source). Existing
    /// installs keep their token file untouched — only fresh installs get this.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }   // CSPRNG-backed fallback
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Length-independent, byte-wise constant-time comparison — avoids leaking how
    /// much of the token matched via early-exit timing on the auth check.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        for i in 0..<Swift.max(ab.count, bb.count) {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The Mac's Tailscale IPv4, if the tailnet is up: the first interface address
    /// inside the CGNAT block Tailscale allocates from (100.64.0.0/10). Nothing else
    /// on a home network legitimately uses that range, so range-match beats matching
    /// utun interface names (which VPNs also use).
    static func tailscaleIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            let o1 = (ip >> 24) & 0xff, o2 = (ip >> 16) & 0xff
            if o1 == 100, (64...127).contains(o2) {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = sin.sin_addr
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buf)
                }
            }
        }
        return nil
    }

    func start() {
        guard listener == nil else { return }
        let port = NWEndpoint.Port(rawValue: Self.port)!
        // Bind scope follows runner.apiBindMode — the state-changing control surface
        // stays off the network unless the user opted in, and "tailscale" keeps the
        // plaintext-HTTP API off the raw LAN entirely (WireGuard encrypts transit).
        func scoped(to host: NWEndpoint.Host) -> NWListener? {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
            return try? NWListener(using: params)
        }
        let made: NWListener?
        let boundDesc: String
        runner.apiBoundFallback = false
        switch runner.apiBindMode {
        case "all":
            made = try? NWListener(using: .tcp, on: port)                    // all interfaces
            boundDesc = "all interfaces (LAN/tailnet reachable — trusted networks only)"
        case "tailscale":
            if let ts = Self.tailscaleIPv4() {
                made = scoped(to: NWEndpoint.Host(ts))
                boundDesc = "Tailscale only (\(ts))"
            } else {
                // Tailnet down (or Tailscale not installed): fall back to loopback so
                // the dashboard still works locally; pollAll rebinds when it appears.
                made = scoped(to: "127.0.0.1")
                runner.apiBoundFallback = true
                boundDesc = "loopback (Tailscale interface not found — will rebind when it appears)"
            }
        default:
            made = scoped(to: "127.0.0.1")                                   // loopback only
            boundDesc = "loopback only"
        }
        guard let l = made else {
            AppLog.shared.write("API server failed to bind (\(boundDesc))")
            return
        }
        AppLog.shared.write("API server listening: \(boundDesc)")
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state {
                DispatchQueue.main.async { self?.runner.apiPortConflict = true }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            DispatchQueue.main.async { self?.receive(conn) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            DispatchQueue.main.async {
                guard let self = self, let data = data, !data.isEmpty, error == nil else {
                    conn.cancel()
                    return
                }
                let response = self.handle(String(decoding: data, as: UTF8.self))
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    /// Parse the request line and headers; route and respond. Runs on main queue.
    private func handle(_ raw: String) -> Data {
        let lines = raw.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return response(400, ["error": "bad request"]) }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        // Public routes (no token): the web dashboard and its icon.
        // All state-reading and state-changing routes stay token-gated.
        if method == "GET", path == "/" || path == "/index.html" {
            if let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"),
               let html = try? Data(contentsOf: url) {
                return response(200, body: html, type: "text/html; charset=utf-8")
            }
            return response(404, ["error": "dashboard not installed"])
        }
        if method == "GET", path == "/icon.png" {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
               let png = try? Data(contentsOf: url) {
                return response(200, body: png, type: "image/png")
            }
            return response(404, ["error": "no icon"])
        }
        if method == "GET", path.hasPrefix("/menubar-icon-"), path.hasSuffix(".png") {
            let name = String(path.dropFirst("/menubar-icon-".count).dropLast(".png".count))
            if ["green", "red", "orange", "blue", "grey"].contains(name),
               let url = Bundle.main.url(forResource: "menubar-icon-\(name)", withExtension: "png"),
               let png = try? Data(contentsOf: url) {
                return response(200, body: png, type: "image/png")
            }
            return response(404, ["error": "no menubar icon"])
        }
        if method == "GET", path == "/artwork.png" {
            let name = Bundle.main.url(forResource: "AppIconArtwork", withExtension: "png")
                    ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            if let url = name, let png = try? Data(contentsOf: url) {
                return response(200, body: png, type: "image/png")
            }
            return response(404, ["error": "no artwork icon"])
        }

        let sentToken = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("x-token:") }?
            .split(separator: ":", maxSplits: 1).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard Self.constantTimeEquals(sentToken, token) else {
            return response(401, ["error": "bad or missing token"])
        }

        switch (method, path) {
        case ("GET", "/status"):
            return response(200, runner.statusPayload())
        case ("GET", "/update/remote-app"):
            let siblingApp = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Charopos Remote.app")
            guard FileManager.default.fileExists(atPath: siblingApp.path) else {
                return response(404, ["error": "remote app not found on server"])
            }
            let tmpZip = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("charopos-remote-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: tmpZip) }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", siblingApp.path, tmpZip.path]
            guard (try? ditto.run()) != nil else {
                return response(500, ["error": "zip failed"])
            }
            // Blocks the (synchronous) handler for the ~sub-second zip; acceptable for
            // this rare route. The exit status MUST be checked — a failed ditto used
            // to fall through and serve a truncated archive as a 200.
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                return response(500, ["error": "zip failed (ditto exit \(ditto.terminationStatus))"])
            }
            guard let zipData = try? Data(contentsOf: tmpZip) else {
                return response(500, ["error": "read failed"])
            }
            return response(200, body: zipData, type: "application/zip")
        case ("GET", let p) where p.hasPrefix("/log/"):
            guard let choice = LogChoice(rawValue: String(p.dropFirst("/log/".count))) else {
                return response(404, ["error": "unknown log"])
            }
            let snap = runner.logSnapshot(for: choice)
            return response(200, ["source": snap.source, "lines": snap.lines])
        case ("POST", "/run/boot"):
            AppLog.shared.write("Remote: boot sequence")
            runner.runBootSequence()
            return response(200, ["ok": true])
        case ("POST", "/run/reboot-force"):
            AppLog.shared.write("Remote: force reboot")
            runner.rebootServer(force: true)
            return response(200, ["ok": true])
        case ("POST", "/run/kickstart"):
            AppLog.shared.write("Remote: kickstart Plex")
            runner.kickstartPlex()
            return response(200, ["ok": true])
        case ("POST", "/run/cloudkey-update"):
            AppLog.shared.write("Remote: CloudKey firmware update")
            runner.updateCloudKey()
            return response(200, ["ok": true])
        case ("POST", "/run/plex-update"):
            AppLog.shared.write("Remote: Plex update apply")
            runner.updatePlex()
            return response(200, ["ok": true])
        case ("POST", "/run/pihole-update"):
            AppLog.shared.write("Remote: PiHole update (pihole -up over SSH)")
            runner.updatePiHole()
            return response(200, ["ok": true])
        case ("POST", let p) where p.hasPrefix("/run/dsm-update-single/"):
            let nasId = String(p.dropFirst("/run/dsm-update-single/".count))
            AppLog.shared.write("Remote run: DSM update for \(nasId)")
            runner.updateSingleNAS(nasId)
            return response(200, ["ok": true])
        case ("POST", let p) where p.hasPrefix("/mount/"):
            let id = String(p.dropFirst("/mount/".count))
            guard let vol = runner.localVolumes.first(where: { $0.id == id }) else {
                return response(404, ["error": "unknown volume"])
            }
            AppLog.shared.write("Remote: mount \(vol.label)")
            runner.remountVolume(vol.id, label: vol.label, mountPoint: vol.mountPoint)
            return response(200, ["ok": true])
        case ("POST", let p) where p.hasPrefix("/unmount/"):
            let id = String(p.dropFirst("/unmount/".count))
            guard let vol = runner.localVolumes.first(where: { $0.id == id }) else {
                return response(404, ["error": "unknown volume"])
            }
            AppLog.shared.write("Remote: unmount \(vol.label)")
            runner.unmountVolume(vol.id, label: vol.label, mountPoint: vol.mountPoint)
            return response(200, ["ok": true])
        case ("POST", let p) where p.hasPrefix("/run/"):
            guard let item = runner.item(withID: String(p.dropFirst("/run/".count))) else {
                return response(404, ["error": "unknown script"])
            }
            AppLog.shared.write("Remote run: \(item.title)")
            runner.run(item)
            return response(200, ["ok": true])
        case ("POST", let p) where p.hasPrefix("/stop/"):
            let which = String(p.dropFirst("/stop/".count))
            switch which {
            case "watch":
                AppLog.shared.write("Remote stop: Ghost Monitor")
                runner.stopWatcher()
            case "iperf":
                AppLog.shared.write("Remote stop: iperf3 Server")
                runner.stopIperf()
            default: return response(404, ["error": "unknown script"])
            }
            return response(200, ["ok": true])
        default:
            return response(404, ["error": "not found"])
        }
    }

    private func response(_ code: Int, _ json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        return response(code, body: body, type: "application/json")
    }

    private func response(_ code: Int, body: Data, type: String) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][code] ?? "OK"
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Never cache: /status is polled every 2s and the dashboard auto-updates from
        // it. Without this, an intermediary (e.g. the Tailscale Serve HTTPS proxy) or a
        // hostname-keyed browser cache can serve a stale snapshot, so the UI appears
        // frozen (e.g. NAS Refresh never showing "Finished") only over the .ts.net name.
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
