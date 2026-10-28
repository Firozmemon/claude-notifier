import Cocoa
import ServiceManagement

// Reads ~/.claude/claude-notifier/state/*.json (written by hook.py) and shows every
// Claude Code session in a menu-bar item plus an always-on-top floating panel.
// Click a row -> focuses that project's Android Studio window. Right-click -> dismiss.

let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-notifier/state")
let defaults = UserDefaults.standard

struct Session {
    let id: String
    let project: String
    let projectPath: String
    let status: String // working | done | input | idle
    let message: String
    let ts: Double
    let bundleId: String
    let pid: Int32
    var file: String
    var shells: [String] = [] // commands of Claude's still-running shells (background or foreground)

    var key: String { "\(id)@\(ts)" }
    var needsAttention: Bool { status == "done" || status == "input" }

    var color: NSColor {
        switch status {
        case "input": return .systemOrange
        case "done": return .systemGreen
        case "working": return .systemBlue
        default: return .systemGray
        }
    }

    var label: String {
        let base: String
        switch status {
        case "input": base = "Needs input"
        case "done": base = "Done"
        case "working": base = "Working"
        default: base = "Idle"
        }
        return shells.isEmpty ? base : "\(base) · ⚙\(shells.count) shell\(shells.count == 1 ? "" : "s") running"
    }

    var tooltip: String {
        var t = "\(projectPath)\n\(message)"
        if !shells.isEmpty { t += "\n\nRunning:\n" + shells.map { "⚙ \($0)" }.joined(separator: "\n") }
        return t + "\n\nClick: open window · Right-click: dismiss"
    }
}

/// Claude's Bash tool runs each command as a direct child: `zsh -c source ~/.claude/shell-snapshots/… eval '<cmd>' …`.
/// Returns claude pid -> the user-visible commands still running under it.
func claudeShells() -> [Int32: [String]] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axww", "-o", "ppid=,command="]
    let pipe = Pipe()
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    var out: [Int32: [String]] = [:]
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where line.contains("/.claude/shell-snapshots/") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), let ppid = Int32(t[..<sp]) else { continue }
        out[ppid, default: []].append(shellCommand(String(t[sp...])))
    }
    return out
}

func shellCommand(_ full: String) -> String {
    guard let start = full.range(of: "eval '") else { return "shell" }
    var body = full[start.upperBound...]
    if let end = body.range(of: "' < /dev/null", options: .backwards) ?? body.range(of: "' && pwd -P", options: .backwards) {
        body = body[..<end.lowerBound]
    }
    let cmd = body.replacingOccurrences(of: "'\"'\"'", with: "'")
        .replacingOccurrences(of: "'\\''", with: "'")
        .replacingOccurrences(of: "\\012", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    return cmd.count > 120 ? String(cmd.prefix(120)) + "…" : cmd
}

func ago(_ ts: Double) -> String {
    let s = Int(Date().timeIntervalSince1970 - ts)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

func loadSessions() -> [Session] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return [] }
    let now = Date().timeIntervalSince1970
    var out: [Session] = []
    for f in files where f.hasSuffix(".json") {
        let p = (stateDir as NSString).appendingPathComponent(f)
        guard let d = fm.contents(atPath: p),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        let s = Session(
            id: o["session_id"] as? String ?? f,
            project: o["project"] as? String ?? "?",
            projectPath: o["project_path"] as? String ?? "",
            status: o["status"] as? String ?? "idle",
            message: o["message"] as? String ?? "",
            ts: o["ts"] as? Double ?? 0,
            bundleId: o["bundle_id"] as? String ?? "",
            pid: Int32(o["pid"] as? Int ?? 0),
            file: p)
        // Claude process gone (window closed / killed) or very stale -> drop it.
        let dead = s.pid > 0 && kill(s.pid, 0) != 0 && errno == ESRCH
        if dead || now - s.ts > 86400 {
            try? fm.removeItem(atPath: p)
            continue
        }
        out.append(s)
    }
    if !out.isEmpty {
        let shells = claudeShells()
        for i in out.indices { out[i].shells = shells[out[i].pid] ?? [] }
    }
    let rank = ["input": 0, "done": 1, "working": 2, "idle": 3]
    return out.sorted {
        let a = rank[$0.status] ?? 9, b = rank[$1.status] ?? 9
        return a != b ? a < b : $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
    }
}

let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-notifier/notifier.log")

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

func parentPid(_ pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

/// The GUI app actually hosting this Claude process (claude -> zsh -> studio), so that with
/// several copies of Android Studio installed we focus the running one, never launch another.
func hostApp(_ s: Session) -> NSRunningApplication? {
    var p = s.pid
    for _ in 0..<15 where p > 1 {
        if let app = NSRunningApplication(processIdentifier: p), app.bundleURL != nil,
           app.activationPolicy == .regular { return app }
        p = parentPid(p)
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleId).first
}

/// Open Studio projects from the IDE's own recentProjects.xml: project path -> window-title name.
func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}

/// Windows on other Spaces / in full screen aren't in kAXWindows, but Studio's Window menu lists every
/// project frame ("~/path", or just the name when unique); pressing it switches straight to that window.
func pressWindowMenu(_ ax: AXUIElement, tilde: String, name: String?) -> Bool {
    guard let bar = axAttr(ax, kAXMenuBarAttribute) else { log("menu: no menubar"); return false }
    let tops = (axAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    for top in tops where (axAttr(top, kAXTitleAttribute) as? String) == "Window" {
        for m in (axAttr(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            let items = (axAttr(m, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let titled = items.map { ($0, axAttr($0, kAXTitleAttribute) as? String ?? "") }
            let hit = titled.first { $0.1 == tilde } ?? titled.first { name != nil && $0.1 == name }
            log("menu: want \(tilde) / \(name ?? "-") -> \(hit?.1 ?? "none")")
            if let item = hit?.0 { return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success }
        }
    }
    return false
}

func openStudioProjects() -> [String: String] {
    let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Google")
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(atPath: base)) ?? [])
        .map { "\(base)/\($0)/options/recentProjects.xml" }.filter { fm.fileExists(atPath: $0) }
    var out: [String: String] = [:]
    for f in files {
        guard let xml = try? String(contentsOfFile: f, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"<entry key="([^"]+)">\s*<value>\s*<RecentProjectMetaInfo([^>]*)>"#) else { continue }
        for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            let attrs = String(xml[Range(m.range(at: 2), in: xml)!])
            guard attrs.contains(#"opened="true""#) else { continue }
            let path = String(xml[Range(m.range(at: 1), in: xml)!])
                .replacingOccurrences(of: "$USER_HOME$", with: NSHomeDirectory())
            var name = (path as NSString).lastPathComponent
            if let r = attrs.range(of: #"frameTitle="([^"]*)""#, options: .regularExpression) {
                name = titleName(String(attrs[r].dropFirst(12).dropLast()))
            }
            out[path] = name
        }
    }
    return out
}

/// "my-app [~/code/my-app] – Main.kt" -> "my-app"
func titleName(_ title: String) -> String {
    var t = title
    for sep in [" [", " – ", " - "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
    return t.trimmingCharacters(in: .whitespaces)
}

/// Raises the exact project window via Accessibility. False if not permitted or not found.
func raiseWindow(_ app: NSRunningApplication, _ s: Session) -> Bool {
    guard AXIsProcessTrusted() else { log("raise: Accessibility not allowed"); return false }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let wins = value as? [AXUIElement] else { log("raise: windows err \(err.rawValue)"); return false }
    let titled: [(AXUIElement, String)] = wins.compactMap { w in
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
        return (t as? String).map { (w, $0) }
    }
    let open = openStudioProjects()
    let tilde = s.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    let name = open[s.projectPath] ?? (s.projectPath as NSString).lastPathComponent
    // Titles carry "[~/path]" when two open projects share a name, so the path is the strongest match;
    // otherwise the name must be exact and unique among open projects.
    let nameUnique = open.values.filter { $0 == name }.count <= 1
    let hit = titled.first { $0.1.contains("[\(tilde)]") }
        ?? (nameUnique ? titled.first { titleName($0.1) == name } : nil)
    log("raise: want path=\(tilde) name=\(name) unique=\(nameUnique) titles=\(titled.map { $0.1 }) hit=\(hit?.1 ?? "none")")
    guard let w = hit?.0 else { return pressWindowMenu(ax, tilde: tilde, name: nameUnique ? name : nil) }
    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return true
}

/// macOS 14+ only lets the active app hand focus over, so take it (the click is user input) and yield it.
func activateHost(_ app: NSRunningApplication) {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14.0, *) {
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

func focus(_ s: Session) {
    // Only ever activates the already-running copy; never asks LaunchServices to open anything.
    guard let app = hostApp(s) else { log("focus \(s.project): no host app"); return }
    log("focus \(s.project) pid=\(s.pid) host=\(app.bundleURL?.lastPathComponent ?? "?") pid=\(app.processIdentifier)")
    let raised = raiseWindow(app, s)
    activateHost(app)
    if raised { _ = raiseWindow(app, s) } // re-raise: activation can bring Studio's last-used window on top
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        log("focus result: frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    }
}

// MARK: - Self-setup (so the .app is all another dev needs)

let hookDest = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-notifier/hook.py")

@discardableResult
func runHook(_ arg: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["python3", hookDest, arg]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    guard (try? task.run()) != nil else { return "python3 not found" }
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Copies the bundled hook.py into ~/.claude/claude-notifier (keeps it current across app updates).
func syncHookScript() {
    guard let src = Bundle.main.path(forResource: "hook", ofType: "py") else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (hookDest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if fm.contents(atPath: src) != fm.contents(atPath: hookDest) {
        try? fm.removeItem(atPath: hookDest)
        try? fm.copyItem(atPath: src, toPath: hookDest)
    }
}

/// Read settings.json directly: shelling out to python3 is unreliable at login (stray stderr, slow xcrun shim).
func hooksInstalled() -> Bool {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    guard let d = FileManager.default.contents(atPath: path),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let hooks = o["hooks"] as? [String: Any] else { return false }
    return ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"].allSatisfy { ev in
        guard let entries = hooks[ev], let json = try? JSONSerialization.data(withJSONObject: entries),
              let text = String(data: json, encoding: .utf8) else { return false }
        return text.contains("claude-notifier") && text.contains("hook.py")
    }
}

func showAlert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    buttons.forEach { a.addButton(withTitle: $0) }
    return a.runModal()
}

var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

func setLoginItem(_ on: Bool) {
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
        _ = showAlert("Couldn't change login item", error.localizedDescription, buttons: ["OK"])
    }
}

func banner(_ title: String, _ body: String) {
    let esc = { (x: String) in x.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? task.run()
}

// MARK: - Row view

final class RowView: NSView {
    let session: Session?
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let highlight: Bool

    init(session: Session?, text: String, attention: Bool, width: CGFloat) {
        self.session = session
        self.highlight = attention
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 6
        if attention { layer?.backgroundColor = session?.color.withAlphaComponent(0.22).cgColor }

        let dot = NSView(frame: NSRect(x: 8, y: 9, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (session?.color ?? .systemGray).cgColor
        addSubview(dot)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: attention ? .semibold : .regular)
        label.textColor = attention || session == nil ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 22, y: 4, width: width - 28, height: 17)
        addSubview(label)
        toolTip = session?.tooltip
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !highlight { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if !highlight { layer?.backgroundColor = nil }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func rightMouseUp(with event: NSEvent) { onRightClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var stack: NSStackView!
    var sessions: [Session] = []
    var lastStatus: [String: String] = [:] // session id -> status
    var lastShells: [String: [String]] = [:] // session id -> running shell commands
    var shellAlertAt: [String: Date] = [:] // session id -> last "shell finished" alert
    var acked = Set<String>() // Session.key values the user has already looked at
    var firstLoad = true
    var lastSignature = ""

    var showPanel: Bool {
        get { defaults.object(forKey: "showPanel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showPanel") }
    }
    var compact: Bool {
        get { defaults.bool(forKey: "compact") }
        set { defaults.set(newValue, forKey: "compact") }
    }
    var sound: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound") }
    }
    var banners: Bool {
        get { defaults.object(forKey: "banners") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "banners") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        buildPanel()
        syncHookScript()
        log("started pid=\(getpid()) accessibility=\(AXIsProcessTrusted() ? "allowed" : "not allowed") path=\(Bundle.main.bundlePath)")
        // Ask once, ever; afterwards the menu's "Install Claude Code hooks…" item is the way back in.
        if !hooksInstalled() && !defaults.bool(forKey: "declinedSetup") && !defaults.bool(forKey: "setupOffered") {
            defaults.set(true, forKey: "setupOffered")
            offerSetup()
        }
        // Start at login via the app's own login item (the old LaunchAgent caused a second copy).
        if hooksInstalled() && !loginItemEnabled && !defaults.bool(forKey: "loginOffByUser") { setLoginItem(true) }
        tick()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: polling

    func offerSetup() {
        let r = showAlert("Set up Claude Notifier?",
            "This adds status hooks to ~/.claude/settings.json (a backup is saved as settings.json.bak-notifier) and starts the notifier at login.\n\nRestart any running Claude sessions afterwards.",
            buttons: ["Set Up", "Not Now"])
        guard r == .alertFirstButtonReturn else { defaults.set(true, forKey: "declinedSetup"); return }
        let out = runHook("--install")
        if out != "ok" {
            _ = showAlert("Hook setup failed", "Needs python3 (install Xcode Command Line Tools).\n\n\(out)", buttons: ["OK"])
            return
        }
        if !loginItemEnabled { setLoginItem(true) }
    }

    @objc func installHooks() { defaults.set(false, forKey: "declinedSetup"); offerSetup() }

    @objc func uninstallHooks() {
        let r = showAlert("Remove Claude Code hooks?",
            "Removes only the notifier's entries from ~/.claude/settings.json.", buttons: ["Remove", "Cancel"])
        if r == .alertFirstButtonReturn {
            runHook("--uninstall")
            defaults.set(true, forKey: "declinedSetup")
        }
    }

    @objc func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        let on = !loginItemEnabled
        defaults.set(!on, forKey: "loginOffByUser")
        setLoginItem(on)
    }

    func attention(_ s: Session) -> Bool { s.needsAttention && !acked.contains(s.key) }

    func tick() {
        sessions = loadSessions()
        var fresh: [Session] = []
        var finished: [(Session, [String])] = []
        for s in sessions {
            if lastStatus[s.id] != s.status, s.needsAttention, !firstLoad {
                // Claude wakes up to report a finished background shell; that Done would repeat the alert.
                let recent = shellAlertAt[s.id].map { Date().timeIntervalSince($0) < 30 } ?? false
                if !(s.status == "done" && recent) { fresh.append(s) }
            }
            // A shell ending while Claude isn't mid-turn means a background shell finished.
            let gone = (lastShells[s.id] ?? []).filter { !s.shells.contains($0) }
            if !gone.isEmpty, s.status != "working", !firstLoad {
                finished.append((s, gone))
                shellAlertAt[s.id] = Date()
                acked.remove(s.key)
            }
            lastStatus[s.id] = s.status
            lastShells[s.id] = s.shells
        }
        firstLoad = false
        let live = Set(sessions.map { $0.key })
        acked = acked.intersection(live)

        if !fresh.isEmpty { alert(fresh) }
        if !finished.isEmpty { alertShells(finished) }
        // Rebuild UI only when something visible changed (ages tick every minute).
        let sig = sessions.map { "\($0.key)|\($0.status)|\($0.shells)|\(attention($0))|\(ago($0.ts).hasSuffix("s") ? "s" : ago($0.ts))" }
            .joined(separator: ",") + "\(compact)\(showPanel)"
        if sig != lastSignature {
            lastSignature = sig
            refreshStatusItem()
            refreshPanel()
        }
    }

    func alert(_ fresh: [Session]) {
        if sound { NSSound(named: fresh.contains { $0.status == "input" } ? "Funk" : "Glass")?.play() }
        if banners {
            for s in fresh { banner("Claude · \(s.project)", s.status == "input" ? s.message : "Task finished") }
        }
        blink()
    }

    func alertShells(_ finished: [(Session, [String])]) {
        if sound { NSSound(named: "Hero")?.play() }
        if banners {
            for (s, cmds) in finished {
                banner("Claude · \(s.project)", "Background shell finished: \(cmds.joined(separator: ", "))")
            }
        }
        blink()
    }

    func blink() {
        guard showPanel else { return }
        panel.orderFrontRegardless()
        // Blink the panel so it catches the eye from any window.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0.3
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = 1
            }, completionHandler: {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    self.panel.animator().alphaValue = 0.3
                }, completionHandler: { self.panel.animator().alphaValue = 1 })
            })
        })
    }

    // MARK: status item

    /// "✳︎ 3 · ●1": total sessions (never changes on click) · unseen ones (orange if any needs input).
    func refreshStatusItem() {
        let unseen = sessions.filter { attention($0) }
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString(string: "✳︎", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        if !sessions.isEmpty { title.append(NSAttributedString(string: " \(sessions.count)", attributes: [.font: mono])) }
        if !unseen.isEmpty {
            let color: NSColor = unseen.contains { $0.status == "input" } ? .systemOrange : .systemGreen
            title.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: mono]))
            title.append(NSAttributedString(string: "●\(unseen.count)", attributes: [.foregroundColor: color, .font: mono]))
        }
        let shells = sessions.reduce(0) { $0 + $1.shells.count }
        if shells > 0 {
            title.append(NSAttributedString(string: " ⚙\(shells)", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: mono]))
        }
        statusItem.button?.attributedTitle = title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: ""))
        }
        for s in sessions {
            let item = NSMenuItem(title: "", action: #selector(menuFocus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            let t = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: s.color])
            t.append(NSAttributedString(string: "\(s.project) — \(s.label) · \(ago(s.ts))",
                                        attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            item.attributedTitle = t
            item.toolTip = s.tooltip
            menu.addItem(item)
            for cmd in s.shells {
                let sub = NSMenuItem(title: "      ⚙ \(cmd)", action: nil, keyEquivalent: "")
                sub.isEnabled = false
                menu.addItem(sub)
            }
        }
        menu.addItem(.separator())
        addToggle(menu, "Show floating panel", showPanel, #selector(togglePanel))
        addToggle(menu, "Compact panel (only what needs you)", compact, #selector(toggleCompact))
        addToggle(menu, "Sound", sound, #selector(toggleSound))
        addToggle(menu, "Banner notifications", banners, #selector(toggleBanners))
        addToggle(menu, "Start at login", loginItemEnabled, #selector(toggleLogin))
        if !AXIsProcessTrusted() {
            let a = NSMenuItem(title: "⚠︎ Allow jumping to the exact window (Accessibility)…", action: #selector(requestAccessibility), keyEquivalent: "")
            a.target = self
            menu.addItem(a)
        }
        menu.addItem(.separator())
        if hooksInstalled() {
            let u = NSMenuItem(title: "Remove Claude Code hooks…", action: #selector(uninstallHooks), keyEquivalent: "")
            u.target = self
            menu.addItem(u)
        } else {
            let i = NSMenuItem(title: "⚠︎ Install Claude Code hooks…", action: #selector(installHooks), keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        let clear = NSMenuItem(title: "Clear finished", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let quit = NSMenuItem(title: "Quit Claude Notifier", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ sel: Selector) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        menu.addItem(i)
    }

    @objc func menuFocus(_ sender: NSMenuItem) {
        if let s = sessions.first(where: { $0.id == sender.representedObject as? String }) { open(s) }
    }
    @objc func togglePanel() { showPanel.toggle(); lastSignature = ""; tick() }
    @objc func toggleCompact() { compact.toggle(); lastSignature = ""; tick() }
    @objc func toggleSound() { sound.toggle() }
    @objc func toggleBanners() { banners.toggle() }
    @objc func clearFinished() {
        for s in sessions where s.status == "done" || s.status == "idle" { acked.insert(s.key) }
        lastSignature = ""
        tick()
    }

    func open(_ s: Session) {
        if !AXIsProcessTrusted() && !defaults.bool(forKey: "askedAX2") {
            defaults.set(true, forKey: "askedAX2")
            let r = showAlert("Jump to the exact window?",
                "With several Studio windows open, Claude Notifier needs Accessibility permission to bring the right one forward. Without it, it only brings Android Studio to the front.\n\nTurn on \"Claude Notifier\" in the list that opens, then click the row again.",
                buttons: ["Open Settings", "Not Now"])
            if r == .alertFirstButtonReturn { requestAccessibility(); return }
        }
        acked.insert(s.key)
        focus(s)
        lastSignature = ""
        tick()
    }

    func dismiss(_ s: Session) {
        acked.insert(s.key)
        lastSignature = ""
        tick()
    }

    // MARK: panel

    let panelWidth: CGFloat = 280

    func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
        ])

        if !panel.setFrameUsingName("ClaudeNotifierPanel"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - panelWidth - 16, y: v.maxY - 16))
        }
        panel.setFrameAutosaveName("ClaudeNotifierPanel")
    }

    func refreshPanel() {
        guard showPanel else { panel.orderOut(nil); return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let w = panelWidth - 12
        var rows: [RowView] = []

        let shown = compact ? sessions.filter { attention($0) } : sessions
        for s in shown {
            let text = "\(s.project) — \(s.label) · \(ago(s.ts))"
            let r = RowView(session: s, text: text, attention: attention(s), width: w)
            r.onClick = { [weak self] in self?.open(s) }
            r.onRightClick = { [weak self] in self?.dismiss(s) }
            rows.append(r)
        }
        if rows.isEmpty {
            let working = sessions.filter { $0.status == "working" }.count
            let text = sessions.isEmpty ? "Claude — no sessions"
                : working > 0 ? "Claude — \(working) working" : "Claude — all caught up"
            rows.append(RowView(session: nil, text: text, attention: false, width: w))
        }
        for r in rows {
            r.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalToConstant: w).isActive = true
            r.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        // Grow/shrink downward from the current top-left corner.
        let h = CGFloat(rows.count) * 28 + 10
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: panelWidth, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

if CommandLine.arguments.contains("--dump") { // debugging: print what the panel would show
    print("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")")
    for s in loadSessions() { print("\(s.project) [pid \(s.pid)] — \(s.label) → \(hostApp(s)?.bundleURL?.lastPathComponent ?? "no host app") · window \(openStudioProjects()[s.projectPath] ?? "?")"); s.shells.forEach { print("   ⚙ \($0)") } }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--focus"), i + 1 < CommandLine.arguments.count { // debugging
    _ = NSApplication.shared
    if let s = loadSessions().first(where: { $0.project == CommandLine.arguments[i + 1] }) { focus(s) }
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--menu"), i + 1 < CommandLine.arguments.count { // debugging
    func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
    let ax = AXUIElementCreateApplication(pid_t(CommandLine.arguments[i + 1])!)
    var out = ""
    if let bar = attr(ax, kAXMenuBarAttribute) {
        for top in (attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attr(top, kAXTitleAttribute) as? String) == "Window" {
            for m in (attr(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (attr(m, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { out += " - \(attr(item, kAXTitleAttribute) as? String ?? "")\n" }
            }
        }
    } else { out = "no menubar" }
    log("menu:\n" + out)
    exit(0)
}

// Single instance: a second copy (login item + manual launch, etc.) quits immediately.
if NSRunningApplication.runningApplications(withBundleIdentifier: "com.firozmemon.claude-notifier")
    .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
