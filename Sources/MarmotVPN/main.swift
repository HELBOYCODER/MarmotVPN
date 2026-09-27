// MarmotVPN — a native macOS menu-bar OpenVPN client for free VPN services.
// Inspired by the Linux "Free OpenVPN Connect" script (GPLv2, S. Bandur) and
// the Vulpine-style menu bar UX. Original Swift implementation, MIT licensed.
//
// Features:
//  - Bundled OpenVPN engine (Homebrew bottles, relocated at first launch, no brew needed)
//  - One-click connect/disconnect from the status bar (root via one admin prompt)
//  - Free profile sources: VPNBook / VPNkeys zip downloads + password scraping (Vision OCR)
//  - Import any .ovpn profile
//  - Live status, log file, launch-at-login

import AppKit
import Vision
import ServiceManagement

// MARK: - Paths

struct AppPaths {
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarmotVPN")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var profiles: URL { support.appendingPathComponent("profiles") }
    static var logs: URL { support.appendingPathComponent("logs") }
    static var runtime: URL { support.appendingPathComponent("runtime") }
    static var pidFile: URL { support.appendingPathComponent("vpn.pid") }
    static var vpnLog: URL { logs.appendingPathComponent("openvpn.log") }
    static func ensureDirs() {
        for u in [profiles, logs] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Model

enum Provider: String {
    case vpnbook, vpnkeys, custom
    var defaultUser: String {
        switch self {
        case .vpnbook: return "vpnbook"
        case .vpnkeys: return "vpnkeys"
        case .custom: return ""
        }
    }
}

struct Profile {
    var url: URL
    var provider: Provider
    var display: String {
        let base = url.deletingPathExtension().lastPathComponent
        let map = [
            "pl226": "Poland", "de4": "Germany", "us1": "USA", "ca222": "Canada",
            "fr1": "France", "uk1": "UK", "nl1": "Netherlands", "sg1": "Singapore",
        ]
        for (k, v) in map where base.lowercased().contains(k) { return "\(v) · \(base)" }
        return base
    }
}

enum TunnelState: Equatable {
    case disconnected
    case startingRuntime
    case runtimeFailed(String)
    case launching
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .startingRuntime: return "Installing VPN engine…"
        case .runtimeFailed(let m): return "Engine failed: \(m)"
        case .launching: return "Authorizing…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

// MARK: - Helpers

func shEscapeSingle(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 120) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let h = DispatchQueue.global()
        var done = false
        h.async { p.waitUntilExit(); done = true }
        while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

func adminShell(_ cmd: String, _ reply: @escaping (Bool, String) -> Void) {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let apple = "do shell script \"\(esc)\" with administrator privileges"
    DispatchQueue.global(qos: .userInitiated).async {
        let (rc, out) = Shell.run("/usr/bin/osascript", ["-e", apple], timeout: 3600)
        DispatchQueue.main.async { reply(rc == 0, out) }
    }
}

func pidAlive(_ pid: Int) -> Bool {
    let (rc, out) = Shell.run("/bin/ps", ["-p", "\(pid)"], timeout: 5)
    return rc == 0 && out.contains("openvpn")
}

// MARK: - Credential scraping

final class CredentialFetcher {
    static func fetch(for provider: Provider, _ reply: @escaping (String?) -> Void) {
        guard provider != .custom else { reply(nil); return }
        let urlStr = provider == .vpnbook
            ? "https://www.vpnbook.com/freevpn"
            : "https://www.vpnkeys.com/get-free-vpn-instantly/"
        guard let url = URL(string: urlStr) else { reply(nil); return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8) else { reply(nil); return }
            // 1) text password on page
            if let p = textPassword(html) { reply(p); return }
            // 2) password rendered in an image → Vision OCR
            if let imgURL = passwordImageURL(html, base: urlStr),
               let pwd = ocrPassword(from: imgURL) { reply(pwd); return }
            reply(nil)
        }.resume()
    }

    private static func textPassword(_ html: String) -> String? {
        let patterns = [
            "Password:?\\s*</em>\\s*<span[^>]*>\\s*([A-Za-z0-9@#$%^&*!._-]{5,24})",
            "password[^>]*>[\\s]*([A-Za-z0-9@#$%^&*!._-]{5,24})\\s*<",
        ]
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func passwordImageURL(_ html: String, base: String) -> URL? {
        let re = try? NSRegularExpression(pattern: "<img[^>]*>", options: [.caseInsensitive])
        guard let re else { return nil }
        var last: String?
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = String(html[Range(m.range, in: html)!])
            if tag.lowercased().contains("password") || tag.lowercased().contains("pwd") {
                if let sre = try? NSRegularExpression(pattern: "src=\"([^\"]+)\"", options: [.caseInsensitive]),
                   let sm = sre.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                   let r = Range(sm.range(at: 1), in: tag) {
                    last = String(tag[r])
                }
            }
        }
        guard let last else { return nil }
        if last.hasPrefix("http") { return URL(string: last) }
        let host = base.components(separatedBy: "/free")[0]
        return URL(string: host + (last.hasPrefix("/") ? last : "/" + last))
    }

    private static func ocrPassword(from url: URL) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data, let img = NSImage(data: data),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let vr = VNRecognizeTextRequest { obs, _ in
                let lines = (obs.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let joined = lines.joined(separator: " ")
                let cleaned = joined
                    .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    .filter { $0.rangeOfCharacter(from: .letters) != nil || $0.rangeOfCharacter(from: .decimalDigits) != nil }
                    .max(by: { $0.count < $1.count })
                if let c = cleaned, c.count >= 5 { result = c }
            }
            vr.recognitionLevel = .accurate
            vr.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([vr])
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
    }
}

// MARK: - VPN controller

final class VPNController {
    private(set) var state: TunnelState = .disconnected
    var currentProfile: Profile?
    var onStateChange: (() -> Void)?

    private func setState(_ s: TunnelState) {
        state = s
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    var runtimeReady: Bool {
        FileManager.default.isExecutableFile(atPath: AppPaths.runtime.appendingPathComponent("sbin/openvpn").path)
    }

    func installRuntimeIfNeeded(_ done: @escaping (Bool) -> Void) {
        guard !runtimeReady else { done(true); return }
        setState(.startingRuntime)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let res = Bundle.main.resourceURL!
            let (rc, out) = Shell.run("/bin/bash", [
                res.appendingPathComponent("scripts/setup_runtime.sh").path,
                res.appendingPathComponent("bottles").path,
                AppPaths.runtime.path,
            ], timeout: 300)
            DispatchQueue.main.async {
                if rc == 0 && out.contains("RUNTIME_OK") {
                    self.setState(.disconnected)
                    done(true)
                } else {
                    let msg = out.split(separator: "\n").last.map(String.init) ?? "setup failed (rc=\(rc))"
                    self.setState(.runtimeFailed(msg))
                    done(false)
                }
            }
        }
    }

    func connect(profile: Profile, username: String, password: String) {
        guard runtimeReady else {
            installRuntimeIfNeeded { [weak self] ok in
                if ok { self?.connect(profile: profile, username: username, password: password) }
            }
            return
        }
        setState(.launching)
        let auth = AppPaths.profiles.appendingPathComponent(profile.url.deletingPathExtension().lastPathComponent + ".auth")
        try? "\(username)\n\(password)\n".write(to: auth, atomically: true, encoding: .utf8)
        chmod600(auth.path)
        let rt = AppPaths.runtime.path
        let script = """
        #!/bin/bash
        export SSL_CERT_FILE='\(rt)/etc/openssl/cert.pem'
        '\(rt)/sbin/openvpn' --config '\(profile.url.path)' \\
          --auth-user-pass '\(auth.path)' \\
          --cd '\(AppPaths.profiles.path)' \\
          --daemon marmotvpn \\
          --writepid '\(AppPaths.pidFile.path)' \\
          --log-append '\(AppPaths.vpnLog.path)'
        """
        let sh = AppPaths.support.appendingPathComponent("connect.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        chmod755(sh.path)
        try? "marmot\n".write(to: AppPaths.support.appendingPathComponent("last"), atomically: true, encoding: .utf8)
        currentProfile = profile
        adminShell("nohup /bin/bash \(shEscapeSingle(sh.path)) >/dev/null 2>&1") { [weak self] ok, err in
            guard let self else { return }
            if ok {
                self.setState(.connecting)
            } else {
                self.setState(.failed(err.isEmpty ? "authorization cancelled" : err))
            }
        }
    }

    func disconnect() {
        let pid = readPid()
        let killCmd = pid.map { "kill \($0)" } ?? "pkill -f 'openvpn --config'"
        adminShell("\(killCmd) || true") { [weak self] _, _ in
            self?.setState(.disconnected)
            self?.currentProfile = nil
        }
    }

    func poll() {
        switch state {
        case .disconnected, .startingRuntime, .runtimeFailed, .failed:
            return
        case .launching, .connecting, .connected:
            break
        }
        guard let pid = readPid() else {
            if case .connecting = state {
                let lastErr = tailErrors()
                setState(.failed(lastErr ?? "process exited — check log"))
            }
            return
        }
        if !pidAlive(pid) {
            let lastErr = tailErrors()
            setState(.failed(lastErr ?? "openvpn stopped"))
            return
        }
        let log = (try? String(contentsOf: AppPaths.vpnLog, encoding: .utf8)) ?? ""
        if log.contains("Initialization Sequence Completed") {
            if case .connected = state { return }
            setState(.connected)
        } else if log.contains("TLS Error") || log.contains("Authentication failed") || log.contains("AUTH_FAILED") {
            setState(.failed("handshake/auth failed — see log"))
        }
    }

    private func tailErrors() -> String? {
        guard let h = try? FileHandle(forReadingFrom: AppPaths.vpnLog) else { return nil }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 4096 ? size - 4096 : 0)
        let txt = String(data: h.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in txt.split(separator: "\n").reversed() {
            let l = line.lowercased()
            if l.contains("error") || l.contains("exiting") || l.contains("auth_failed") {
                return String(line.suffix(120))
            }
        }
        return nil
    }

    private func readPid() -> Int? {
        guard let s = try? String(contentsOf: AppPaths.pidFile, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func chmod600(_ p: String) { Shell.run("/bin/chmod", ["600", p], timeout: 5) }
    private func chmod755(_ p: String) { Shell.run("/bin/chmod", ["755", p], timeout: 5) }
}

// MARK: - Profile sources

final class ProfileStore {
    static let vpnbookZips = [
        "https://www.vpnbook.com/free-openvpn-account/VPNBook.com-OpenVPN-PL226.zip",
        "https://www.vpnbook.com/free-openvpn-account/VPNBook.com-OpenVPN-DE4.zip",
        "https://www.vpnbook.com/free-openvpn-account/VPNBook.com-OpenVPN-US1.zip",
        "https://www.vpnbook.com/free-openvpn-account/VPNBook.com-OpenVPN-CA222.zip",
        "https://www.vpnbook.com/free-openvpn-account/VPNBook.com-OpenVPN-FR1.zip",
    ]
    static let vpnkeysZips = [
        "https://www.vpnkeys.com/us1.zip", "https://www.vpnkeys.com/uk1.zip",
        "https://www.vpnkeys.com/nl1.zip", "https://www.vpnkeys.com/sg1.zip",
    ]

    static func scan() -> [Profile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: AppPaths.profiles, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "ovpn" }.map { u in
            let b = u.deletingPathExtension().lastPathComponent.lowercased()
            let prov: Provider = b.contains("vpnbook") ? .vpnbook : (b.contains("vpnkey") ? .vpnkeys : .custom)
            return Profile(url: u, provider: prov)
        }.sorted { $0.display < $1.display }
    }

    static func download(zips: [String], provider: Provider, progress: @escaping (String) -> Void,
                         done: @escaping (Int, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0
            var lastErr: String?
            for z in zips {
                progress("Downloading \(z.components(separatedBy: "/").last ?? z)…")
                let sem = DispatchSemaphore(value: 0)
                var tmp: URL?
                URLSession.shared.downloadTask(with: URL(string: z)!) { f, resp, err in
                    defer { sem.signal() }
                    if let f, (resp as? HTTPURLResponse)?.statusCode == 200 || (resp as? HTTPURLResponse) == nil {
                        let dest = AppPaths.support.appendingPathComponent(UUID().uuidString + ".zip")
                        try? FileManager.default.moveItem(at: f, to: dest)
                        tmp = dest
                    } else {
                        lastErr = err?.localizedDescription ?? "blocked or offline"
                    }
                }.resume()
                _ = sem.wait(timeout: .now() + 45)
                guard let zip = tmp else { continue }
                let (rc, _) = Shell.run("/usr/bin/unzip", ["-o", "-j", zip.path, "*.ovpn", "-d", AppPaths.profiles.path], timeout: 30)
                try? FileManager.default.removeItem(at: zip)
                if rc == 0 { ok += 1 } else { lastErr = "unzip failed" }
            }
            DispatchQueue.main.async { done(ok, ok == 0 ? lastErr : nil) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let controller = VPNController()
    var pollTimer: Timer?
    var pendingProfile: Profile?

    func applicationDidFinishLaunching(_ note: Notification) {
        AppPaths.ensureDirs()
        NSApp.setActivationPolicy(.accessory)
        rebuildMenu()
        controller.onStateChange = { [weak self] in self?.rebuildMenu() }
        controller.installRuntimeIfNeeded { _ in }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.controller.poll() }
    }

    // MARK: Menu

    func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "MarmotVPN")?
                .withSymbolConfiguration(cfg) else { return nil }
        if let color {
            let out = NSImage(size: img.size)
            out.lockFocus()
            color.set()
            let r = NSRect(origin: .zero, size: img.size)
            img.draw(in: r)
            r.fill(using: .sourceAtop)
            out.unlockFocus()
            return out
        }
        img.isTemplate = true
        return img
    }

    func stateColor() -> NSColor {
        switch controller.state {
        case .connected: return NSColor(srgbRed: 0.133, green: 0.772, blue: 0.369, alpha: 1) // #22C55E
        case .failed, .runtimeFailed: return NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1) // #DC2626
        case .connecting, .launching, .startingRuntime: return NSColor.systemYellow
        default: return .secondaryLabelColor
        }
    }

    func rebuildMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        let iconName: String
        switch controller.state {
        case .connected: iconName = "lock.shield.fill"
        case .connecting, .launching, .startingRuntime: iconName = "arrow.triangle.2.circlepath"
        case .failed, .runtimeFailed: iconName = "exclamationmark.shield.fill"
        default: iconName = "shield"
        }
        statusItem.button?.image = symbol(iconName, color: stateColor())

        let head = NSMenuItem(title: "MarmotVPN — \(controller.state.label)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        if let p = controller.currentProfile {
            let sub = NSMenuItem(title: "Profile: \(p.display)", action: nil, keyEquivalent: "")
            sub.isEnabled = false
            m.addItem(sub)
        }
        m.addItem(.separator())

        let profilesMenu = NSMenu(title: "Profiles")
        profilesMenu.delegate = self
        let pmItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        pmItem.submenu = profilesMenu
        populate(profilesMenu)
        m.addItem(pmItem)

        let connectTitle = (controller.state == .connected) ? "Disconnect" : "Connect (last / first profile)"
        let conn = NSMenuItem(title: connectTitle,
                              action: controller.state == .connected ? #selector(doDisconnect) : #selector(doConnect),
                              keyEquivalent: controller.state == .connected ? "d" : "c")
        conn.keyEquivalentModifierMask = [.command]
        conn.target = self
        conn.isEnabled = controller.state != .connected
            ? (controller.runtimeReady && !ProfileStore.scan().isEmpty && controller.state != .connecting && controller.state != .launching)
            : true
        m.addItem(conn)
        m.addItem(.separator())

        let dl1 = NSMenuItem(title: "Download VPNBook profiles", action: #selector(dlVPNBook), keyEquivalent: "")
        dl1.target = self; m.addItem(dl1)
        let dl2 = NSMenuItem(title: "Download VPNkeys profiles", action: #selector(dlVPNKeys), keyEquivalent: "")
        dl2.target = self; m.addItem(dl2)
        let imp = NSMenuItem(title: "Import .ovpn file…", action: #selector(importOvpn), keyEquivalent: "i")
        imp.keyEquivalentModifierMask = [.command]; imp.target = self; m.addItem(imp)
        m.addItem(.separator())

        let log = NSMenuItem(title: "Open connection log", action: #selector(openLog), keyEquivalent: "")
        log.target = self; m.addItem(log)
        let rt = NSMenuItem(title: "Repair VPN engine", action: #selector(repairRuntime), keyEquivalent: "")
        rt.target = self
        rt.isEnabled = controller.state != .startingRuntime
        m.addItem(rt)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        if #available(macOS 13, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        m.addItem(login)
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit MarmotVPN", action: #selector(NSApp.terminate), keyEquivalent: "q")
        q.keyEquivalentModifierMask = [.command]; m.addItem(q)

        statusItem.menu = m
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = ProfileStore.scan()
        if profiles.isEmpty {
            let e = NSMenuItem(title: "No profiles — download or import", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        } else {
            for p in profiles {
                let it = NSMenuItem(title: p.display, action: #selector(selectProfile(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = p.url.path
                it.state = (controller.currentProfile?.url.path == p.url.path) ? .on : .off
                it.isEnabled = controller.state != .connecting && controller.state != .launching
                menu.addItem(it)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // safe in-place refresh while the menu is open (do NOT reassign statusItem.menu here)
        if menu.title == "Profiles" { populate(menu) }
    }

    // MARK: Actions

    @objc func selectProfile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        guard let p = ProfileStore.scan().first(where: { $0.url == url }) else { return }
        pendingProfile = p
        CredentialFetcher.fetch(for: p.provider) { [weak self] pwd in
            guard let self else { return }
            let user = p.provider.defaultUser
            if let pwd {
                self.controller.connect(profile: p, username: user, password: pwd)
                self.notify("Got credentials automatically", "user: \(user)")
            } else {
                self.promptCredentials(profile: p, defaultUser: user, defaultPass: "")
            }
        }
    }

    @objc func doConnect(_ s: Any?) {
        if let p = pendingProfile ?? controller.currentProfile {
            selectProfileMake(p)
            return
        }
        guard let first = ProfileStore.scan().first else { return }
        selectProfileMake(first)
    }

    func selectProfileMake(_ p: Profile) {
        pendingProfile = p
        CredentialFetcher.fetch(for: p.provider) { [weak self] pwd in
            guard let self else { return }
            let user = p.provider.defaultUser
            if let pwd { self.controller.connect(profile: p, username: user, password: pwd) }
            else { self.promptCredentials(profile: p, defaultUser: user, defaultPass: "") }
        }
    }

    @objc func doDisconnect(_ s: Any?) { controller.disconnect() }

    @objc func dlVPNBook(_ s: Any?) {
        ProfileStore.download(zips: ProfileStore.vpnbookZips, provider: .vpnbook, progress: { [weak self] t in
            self?.notifyProgress(t)
        }) { [weak self] n, err in
            if let e = err { self?.notifyError("Download failed", e) }
            else { self?.notify("Profiles downloaded", "\(n) profile(s) added") }
            self?.rebuildMenu()
        }
    }

    @objc func dlVPNKeys(_ s: Any?) {
        ProfileStore.download(zips: ProfileStore.vpnkeysZips, provider: .vpnkeys, progress: { [weak self] t in
            self?.notifyProgress(t)
        }) { [weak self] n, err in
            if let e = err { self?.notifyError("Download failed", e) }
            else { self?.notify("Profiles downloaded", "\(n) profile(s) added") }
            self?.rebuildMenu()
        }
    }

    @objc func importOvpn(_ s: Any?) {
        let of = NSOpenPanel()
        of.allowedFileTypes = ["ovpn"]
        of.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        of.begin { [weak self] resp in
            guard resp == .OK, let src = of.url else { return }
            let dest = AppPaths.profiles.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.copyItem(at: src, to: dest)
            self?.rebuildMenu()
            let p = Profile(url: dest, provider: .custom)
            self?.promptCredentials(profile: p, defaultUser: "", defaultPass: "")
        }
    }

    func promptCredentials(profile p: Profile, defaultUser: String, defaultPass: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "OpenVPN credentials"
        a.informativeText = "\(p.display)\n\(p.provider == .custom ? "Enter the username/password for this profile" : "Automatic retrieval failed — enter credentials shown on the provider page")"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 64))
        stack.orientation = .vertical; stack.spacing = 6
        let u = NSTextField(frame: NSRect(x: 0, y: 34, width: 260, height: 24))
        u.placeholderString = "username"; u.stringValue = defaultUser
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pw.placeholderString = "password"; pw.stringValue = defaultPass
        stack.addArrangedSubview(u); stack.addArrangedSubview(pw)
        a.accessoryView = stack
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            controller.connect(profile: p, username: u.stringValue, password: pw.stringValue)
        }
    }

    @objc func openLog(_ s: Any?) {
        NSWorkspace.shared.open(AppPaths.vpnLog)
    }

    @objc func repairRuntime(_ s: Any?) {
        try? FileManager.default.removeItem(at: AppPaths.runtime)
        controller.installRuntimeIfNeeded { ok in
            if !ok { self.notifyError("Engine repair failed", "see log at \(AppPaths.support.path)") }
        }
    }

    @objc func toggleLogin(_ s: Any?) {
        if #available(macOS 13, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { notifyError("Login item", error.localizedDescription) }
        }
    }

    // MARK: Notifications

    func notify(_ title: String, _ body: String) {
        let n = NSUserNotification()
        n.title = title; n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }
    func notifyProgress(_ t: String) { notify("MarmotVPN", t) }
    func notifyError(_ t: String, _ b: String) { notify("⚠︎ " + t, b) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
