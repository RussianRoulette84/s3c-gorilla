// ssh-agent-unlock — everything that turns a locked vault into usable key bytes: the Touch ID
// unwrap subprocess, the cold bootstrap, the native unlock window and the kdbx extract.
// Part of s3c-ssh-agent.

import Foundation
import Darwin

// MARK: - Touch-ID unwrap via touchid-gorilla subprocess

// Epoch of the last boot (kern.boottime) so a blob from before a reboot is treated as absent
// — SSH secrets in /tmp must not survive a reboot either (CP3, mirrors env/otp _blob_fresh).
func bootEpoch() -> TimeInterval {
    var tv = timeval(); var size = MemoryLayout<timeval>.stride
    var mib = [CTL_KERN, KERN_BOOTTIME]
    if sysctl(&mib, 2, &tv, &size, nil, 0) == 0 { return TimeInterval(tv.tv_sec) }
    return 0
}
func blobIsStale(_ path: String) -> Bool {
    guard let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return false }
    let mt = m.timeIntervalSince1970
    if mt > Date().timeIntervalSince1970 + 300 { return true }   // future mtime = bad clock → don't trust it (#17)
    if Date().timeIntervalSince1970 - mt > blobTTL() { return true }   // idle-expired → re-fan-out (#TTL)
    let boot = bootEpoch()
    return boot > 0 && mt < boot
}

func unwrapViaTouchID(name: String, peer: pid_t = -1) -> Data? {
    let blobPath = "\(blobDir)/\(name).blob"
    // Up to 2 attempts: a screen-lock / RunAtLoad wipe (#26) can delete the blob between the
    // existence check and the unwrap subprocess; on that race re-bootstrap once and retry (#29).
    for attempt in 0..<2 {
        // Bootstrap if the blob is missing OR predates the last boot (stale → re-wrap fresh).
        if !FileManager.default.fileExists(atPath: blobPath) || blobIsStale(blobPath) {
            if blobIsStale(blobPath) { try? FileManager.default.removeItem(atPath: blobPath) }
            guard bootstrapBlob(name: name, peer: peer) else { return nil }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: touchidPath)
        proc.arguments = ["unwrap", name]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try proc.run()
        } catch {
            return nil
        }
        // An abandoned Touch ID prompt (user walked away, or ssh was Ctrl-C'd) would otherwise
        // leave this subprocess waiting forever WHILE HOLDING the unlock queue — wedging every
        // later signature with no prompt and no log line. Kill it instead.
        let tidWatchdog = DispatchWorkItem {
            if proc.isRunning { dlog("touchid unwrap timed out after \(touchIDTimeout)s — terminating"); proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + touchIDTimeout, execute: tidWatchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        tidWatchdog.cancel()
        if proc.terminationStatus == 0 { return data }
        // Failed — only retry if the blob vanished mid-flight (a concurrent wipe); any other
        // failure (Touch ID denied, parse error) leaves the blob in place → don't loop.
        if attempt == 0 && !FileManager.default.fileExists(atPath: blobPath) { continue }
        return nil
    }
    return nil
}

// MARK: - Bootstrap: prompt master pw (osascript), extract from kdbx, wrap

func bootstrapBlob(name: String, peer: pid_t = -1) -> Bool {
    // name is "ssh-<keyname>"; extract the bare keyname to find the kdbx entry.
    guard name.hasPrefix("ssh-") else { return false }
    let keyName = String(name.dropFirst(4))
    // Cold unlock: the native window collects the master password AND the session choices
    // (scope / ask-each-time / TTL). Falls back to the plain osascript prompt if the window
    // binary is missing.
    guard let choice = runUnlockWindow(peer: peer) else { return false }
    applyChoice(choice)
    let pw = choice.pw

    // Extract from kdbx
    guard let keyBytes = extractSSHFromKdbx(masterPw: pw, keyName: keyName) else { return false }

    // For RSA keys: pay the slow CRT computation (one modular exponentiation)
    // now so every subsequent sign is fast. SecKey needs PKCS#1 DER, OpenSSH
    // doesn't ship with the CRT params, so we derive them here and wrap the
    // pre-built DER instead of the raw OpenSSH bytes.
    var payload = keyBytes
    let entry = loadRegistry().first { $0.name == keyName }
    if entry?.keyType == "ssh-rsa" {
        guard let der = convertOpenSSHRSAToPKCS1(keyBytes) else { return false }
        payload = der
    }

    // Wrap via touchid-gorilla
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: touchidPath)
    proc.arguments = ["wrap", name]
    let inPipe = Pipe()
    proc.standardInput = inPipe
    do { try proc.run() } catch { return false }
    inPipe.fileHandleForWriting.write(payload)
    try? inPipe.fileHandleForWriting.close()
    proc.waitUntilExit()
    let ok = proc.terminationStatus == 0
    // Same unlock warms EVERY secret (env/otp/ssh) so terminal tools skip the password too.
    // DELAYED, not just backgrounded: the fan-out fires a burst of Secure Enclave wraps, and
    // running it now would contend with the Touch ID unwrap this very signature is about to do
    // (the user sees `ssh` hang with no prompt). Let the signature win, then warm the rest.
    if ok {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + fanOutDelay) { warmAllSecrets(pw) }
    }
    return ok
}

func askMasterPassword() -> String? {
    // LaunchAgent context: no TTY. Use osascript.
    let script = """
    tell application "System Events" to activate
    text returned of (display dialog "KeePass master password" default answer "" with hidden answer with icon caution buttons {"Cancel","Unlock"} default button "Unlock")
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let pw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (pw?.isEmpty ?? true) ? nil : pw
}

// MARK: - Native unlock window (spawned subprocess, isolated from our run loop)

struct UnlockChoice { var pw: String; var scope: String; var askPw: Bool; var ttlMin: Int }
let unlockWindowPath = "/usr/local/bin/s3c-unlock-window"
// Give a human time to type, but never wedge ssh forever on a window nobody can see.
let unlockWindowTimeout: Double = 180
// Wait this long after a cold unlock before warming the rest of the vault, so the fan-out's
// Secure Enclave traffic can't collide with the Touch ID unwrap of the key we need right now.
let fanOutDelay: Double = 10
// Abandoned Touch ID prompt must never wedge the agent — cap the unwrap subprocess.
let touchIDTimeout: Double = 120

// Run the themed window. It prints: line0 = master password, then scope=/askpw=/ttl= lines.
// If the binary is absent or fails to launch, fall back to the osascript prompt (password only).
// Resolve the app that triggered SSH (the owning-app ancestor) → display name + .app bundle path,
// so the unlock window can show "for: <App>" with its icon. Empty strings when unknown.
func ownerAppInfo(_ peer: pid_t) -> (name: String, path: String) {
    guard peer > 0 else { return ("", "") }
    let owner = resolveOwningApp(peer)
    guard let exe = pathForPID(owner) else { return ("", "") }
    var url = URL(fileURLWithPath: exe)
    for _ in 0..<6 {
        if url.pathExtension == "app" {
            var name = url.deletingPathExtension().lastPathComponent
            let plist = url.appendingPathComponent("Contents/Info.plist")
            if let d = try? Data(contentsOf: plist),
               let obj = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                name = (obj["CFBundleDisplayName"] as? String) ?? (obj["CFBundleName"] as? String) ?? name
            }
            return (name, url.path)
        }
        url.deleteLastPathComponent()
    }
    return ((exe as NSString).lastPathComponent, "")   // bundle-less (bare terminal binary)
}

func runUnlockWindow(peer: pid_t = -1) -> UnlockChoice? {
    guard FileManager.default.isExecutableFile(atPath: unlockWindowPath) else {
        return askMasterPassword().map { UnlockChoice(pw: $0, scope: "", askPw: false, ttlMin: 0) }
    }
    let (appName, appPath) = ownerAppInfo(peer)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: unlockWindowPath)
    proc.arguments = [appName, appPath]   // window shows "for: <app>" + its icon
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try proc.run() } catch {
        return askMasterPassword().map { UnlockChoice(pw: $0, scope: "", askPw: false, ttlMin: 0) }
    }
    // Watchdog: if the window never comes back (hidden on another Space, wedged, no display),
    // kill it so `ssh` fails fast instead of hanging forever holding the unlock queue.
    let watchdog = DispatchWorkItem {
        if proc.isRunning { dlog("unlock window timed out after \(unlockWindowTimeout)s — terminating"); proc.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + unlockWindowTimeout, execute: watchdog)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()
    guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\n")
    guard !lines.isEmpty else { return nil }
    let pw = lines.removeFirst()
    if pw.isEmpty { return nil }
    var scope = "", askPw = false, ttl = 0
    for l in lines {
        let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "scope": scope = kv[1]
        case "askpw": askPw = (kv[1] == "1" || kv[1].lowercased() == "true")
        case "ttl":   ttl = Int(kv[1]) ?? 0
        default:      break
        }
    }
    return UnlockChoice(pw: pw, scope: scope, askPw: askPw, ttlMin: ttl)
}

// Hand the master password to `s3c-gorilla _fanout`, which chip-wraps every ENV/OTP/SSH secret in
// one kdbx open (reuses the proven bash fan_out_all). Best-effort: a missing CLI is a no-op.
func warmAllSecrets(_ pw: String) {
    let s3c = "/usr/local/bin/s3c-gorilla"
    guard FileManager.default.isExecutableFile(atPath: s3c) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: s3c)
    p.arguments = ["_fanout"]
    let inp = Pipe()
    p.standardInput = inp
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return }
    inp.fileHandleForWriting.write((pw + "\n").data(using: .utf8)!)
    try? inp.fileHandleForWriting.close()
    p.waitUntilExit()
    dlog("fan-out after window unlock: exit \(p.terminationStatus)")
}

func applyChoice(_ c: UnlockChoice) {
    if ["once", "app", "session"].contains(c.scope) { gSessionScope = c.scope }
    gAskPwOverride = c.askPw
    gTTLMinutes = c.ttlMin
}

func extractSSHFromKdbx(masterPw: String, keyName: String) -> Data? {
    // Reads $HOME/.config/s3c-gorilla/config for GORILLA_DB. Falls back to default.
    let configPath = "\(homeDir)/.config/s3c-gorilla/config"
    var dbPath = "\(homeDir)/Library/Mobile Documents/com~apple~CloudDocs/gorilla_tunnel.dat.kdbx"
    if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8) {
        for line in cfg.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GORILLA_DB=") {
                var v = String(t.dropFirst("GORILLA_DB=".count))
                v = v.replacingOccurrences(of: "\"", with: "")
                v = v.replacingOccurrences(of: "$HOME", with: homeDir)
                dbPath = v
            }
        }
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: keepassxcPath())
    proc.arguments = ["attachment-export", dbPath, "SSH/\(keyName)", keyName, "--stdout", "-q"]
    let inPipe = Pipe()
    let outPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try proc.run() } catch { return nil }
    inPipe.fileHandleForWriting.write((masterPw + "\n").data(using: .utf8)!)
    try? inPipe.fileHandleForWriting.close()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 || data.isEmpty {
        dlog("extractSSHFromKdbx failed for SSH/\(keyName): keepassxc-cli exit \(proc.terminationStatus)")
        return nil
    }
    return data
}
