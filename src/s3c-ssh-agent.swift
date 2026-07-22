// s3c-ssh-agent — ssh-agent protocol server backed by Secure Enclave
// (Mode 2: SE-born keys) or chip-wrapped kdbx-extracted keys (Mode 1).
//
// Listens on ~/.s3c-gorilla/agent.sock. Every sign request fires Touch ID.
// Keys never persist in agent memory across requests.
//
// Mode 1 supports Ed25519, ECDSA-P256, and RSA (rsa-sha2-256/512) key types.
// RSA signing is shared with the password-mode agent via ssh-rsa.swift (#RSA).
//
// This file is the server itself: paths, protocol constants, message dispatch, the socket
// loop, cleanup and @main. The rest is split by job — ssh-agent-pushed (KeePassXC GUI keys),
// ssh-agent-keys (registry + handlers + password-mode caches), ssh-agent-scope (warm-key
// cache), ssh-agent-sign (all signing), ssh-agent-unlock (Touch ID / window / kdbx).

import Foundation
import Security
import CryptoKit
import Darwin
import AppKit   // NSWorkspace sleep notification (vault-close on lid-close / sleep)

// MARK: - Paths

let homeDir = NSHomeDirectory()
let agentDir = "\(homeDir)/.s3c-gorilla"
let socketPath = "\(agentDir)/agent.sock"
let registryPath = "\(agentDir)/keys.json"
let pubDir = "\(agentDir)/pubkeys"
let blobDir = "/tmp/s3c-gorilla"
let touchidPath = "/usr/local/bin/touchid-gorilla"

// Resolve keepassxc-cli across Homebrew layouts (Apple Silicon /opt/homebrew vs
// Intel /usr/local) and finally $PATH. (B8)
func keepassxcPath() -> String {
    for c in ["/opt/homebrew/bin/keepassxc-cli", "/usr/local/bin/keepassxc-cli"]
    where FileManager.default.isExecutableFile(atPath: c) { return c }
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/keepassxc-cli"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
    }
    return "/usr/local/bin/keepassxc-cli"
}

let sshLogPath = "\(homeDir)/Library/Logs/s3c-gorilla/s3c-ssh-agent.log"

// Best-effort debug log (B12). Never throws.
func dlog(_ msg: String) {
    let dir = "\(homeDir)/Library/Logs/s3c-gorilla"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    guard let data = "[\(Date())] \(msg)\n".data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: sshLogPath) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: sshLogPath))
    }
}

// MARK: - ssh-agent protocol constants

let SSH_AGENTC_REQUEST_IDENTITIES: UInt8 = 11
let SSH_AGENTC_SIGN_REQUEST: UInt8 = 13
let SSH_AGENT_FAILURE: UInt8 = 5
let SSH_AGENT_SUCCESS: UInt8 = 6
let SSH_AGENT_IDENTITIES_ANSWER: UInt8 = 12
let SSH_AGENT_SIGN_RESPONSE: UInt8 = 14

// RSA hash flags + BigN/DER/signRSA/convertOpenSSHRSAToPKCS1 now live in the shared
// ssh-rsa.swift (compiled into both agents), so password mode can sign RSA too (#RSA).

// SE key tag prefix shared with touchid-gorilla.swift
let sshKeyTagPrefix = "s3c-gorilla.ssh."


// MARK: - Wire framing + dispatch

// framed → ssh-wire.swift (#13)

func handleMessage(_ msg: Data, peer: pid_t = -1) -> Data {
    guard let type = msg.first else { return framed(Data([SSH_AGENT_FAILURE])) }
    let body = msg.count > 1 ? msg.subdata(in: 1..<msg.count) : Data()
    switch type {
    case SSH_AGENTC_REQUEST_IDENTITIES:
        return handleRequestIdentities()
    case SSH_AGENTC_SIGN_REQUEST:
        return handleSignRequest(body: body, peer: peer)
    case SSH_AGENTC_ADD_IDENTITY:
        return handleAddIdentity(body)
    case SSH_AGENTC_ADD_ID_CONSTRAINED:
        return handleAddIdentity(body, constrained: true)
    case SSH_AGENTC_REMOVE_IDENTITY:
        return handleRemoveIdentity(body)
    case SSH_AGENTC_REMOVE_ALL_IDENTITIES:
        return handleRemoveAll()
    case SSH_AGENTC_EXTENSION:
        // Clients probe for extensions (e.g. session-bind); declining is correct and routine —
        // answer FAILURE without logging, so the log isn't flooded on every connection.
        return framed(Data([SSH_AGENT_FAILURE]))
    default:
        dlog("unhandled ssh-agent message type \(type) (\(msg.count)b)")   // #4 diagnostics
        return framed(Data([SSH_AGENT_FAILURE]))
    }
}

// MARK: - Socket server

// On startup, physically remove /tmp blobs left over from BEFORE the last boot (#26). macOS does
// NOT clear /tmp on reboot, and the per-blob mtime<boottime gate in unwrapViaTouchID only guards
// reads — this drops the stale files outright before we serve anyone. Same-boot blobs (e.g. after
// a KeepAlive crash-respawn) are kept, so a single crash doesn't nuke a live session.
func wipeStaleBlobsOnStartup() {
    let boot = bootEpoch()
    guard boot > 0,
          let names = try? FileManager.default.contentsOfDirectory(atPath: blobDir) else { return }
    let hasStale = names.contains { name in
        let p = "\(blobDir)/\(name)"
        guard let m = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
        else { return false }
        return m.timeIntervalSince1970 < boot
    }
    guard hasStale else { return }
    let wipe = Process()
    wipe.executableURL = URL(fileURLWithPath: touchidPath)
    wipe.arguments = ["wrap-clear"]
    try? wipe.run(); wipe.waitUntilExit()
}

func serve() {
    // Ensure config dir
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    try? FileManager.default.createDirectory(atPath: pubDir, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    wipeStaleBlobsOnStartup()   // #26: drop pre-reboot blobs before serving
    // Remove stale socket
    try? FileManager.default.removeItem(atPath: socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("socket() failed: \(String(cString: strerror(errno)))\n", stderr); exit(1)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8) + [0]
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { bp in
            for (i, b) in pathBytes.enumerated() where i < 104 { bp[i] = b }
        }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
    }
    guard bindResult == 0 else {
        dlog("bind() failed on \(socketPath): \(String(cString: strerror(errno)))")
        fputs("bind() failed: \(String(cString: strerror(errno)))\n", stderr); exit(1)
    }
    chmod(socketPath, 0o600)
    guard listen(fd, 8) == 0 else {
        fputs("listen() failed: \(String(cString: strerror(errno)))\n", stderr); exit(1)
    }
    fputs("s3c-ssh-agent listening on \(socketPath)\n", stderr)

    // Idle backstop for KeePassXC-pushed keys (#2): drop them after the unlock TTL even if
    // REMOVE_ALL never arrives (e.g. KeePassXC crashed). KeePassXC re-pushes on each unlock, so
    // this caps how long a pushed key stays signable. (Screen lock is covered by KeePassXC's own
    // REMOVE_ALL on database lock + this TTL.)
    DispatchQueue.global().async {
        let ttl = passwordTTL()
        while true {
            sleep(60)
            pushedExpire(ttl)                  // idle TTL
            pushedExpire(pushedHardMaxAge)     // #20: hard 5-min cap regardless of TTL
            sshCacheQueue.sync { sshReapLocked() }   // drop dead-owner + TTL-expired scope keys
            if !pushedList().isEmpty && !keePassXCRunning() {
                dlog("KeePassXC not running — clearing pushed keys")   // #20 heartbeat
                pushedClear()
            }
        }
    }

    while true {
        let cfd = accept(fd, nil, nil)
        if cfd < 0 { continue }
        // Handle connection in a background thread so one client can't block others.
        DispatchQueue.global().async {
            handleConnection(cfd)
            close(cfd)
        }
    }
}

// MARK: - ADD_IDENTITY peer admission (#40)
// ADD_IDENTITY pushes a key the agent then signs with WITHOUT Touch ID — the one opcode that
// injects new signable material. Restrict it to KeePassXC by resolving the connecting process to a
// bundle identifier (peer machinery mirrored from s3c-session-agent.swift).
func peerPID(_ cfd: Int32) -> pid_t? {
    var pid = pid_t(); var len = socklen_t(MemoryLayout<pid_t>.size)
    let solLocal: Int32 = 0, localPeerPID: Int32 = 0x002
    return getsockopt(cfd, solLocal, localPeerPID, &pid, &len) == 0 ? pid : nil
}
func pathForPID(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}
func realpathOf(_ p: String) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return realpath(p, &buf) != nil ? String(cString: buf) : p
}
let pushAllowedBundleIDs: Set<String> = ["org.keepassxc.keepassxc"]
func bundleIDForPID(_ pid: pid_t) -> String? {
    guard let path = pathForPID(pid) else { return nil }
    var url = URL(fileURLWithPath: path)
    for _ in 0..<5 {                                   // walk up from the executable to the .app bundle
        if url.pathExtension == "app" {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            if let d = try? Data(contentsOf: plist),
               let obj = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
               let bid = obj["CFBundleIdentifier"] as? String { return bid }
        }
        url.deleteLastPathComponent()
    }
    return nil
}
// Fail-CLOSED: a libproc quirk that hides the peer denies the push (worst case the GUI key just
// isn't loaded; the vault Touch-ID path still works) — the opposite of the session-agent's fail-
// open control socket, because ADD is a key-injection oracle.
func peerMayPushKeys(_ cfd: Int32) -> (ok: Bool, pid: pid_t, path: String) {
    guard let pid = peerPID(cfd) else { return (false, -1, "?") }
    let path = pathForPID(pid).map(realpathOf) ?? "?"
    if let bid = bundleIDForPID(pid), pushAllowedBundleIDs.contains(bid) { return (true, pid, path) }
    if path.contains("KeePassXC.app/") { return (true, pid, path) }   // path fallback if Info.plist unreadable
    return (false, pid, path)
}

func handleConnection(_ cfd: Int32) {
    // Reject any peer that isn't the same uid (#3) — socket 0600 already limits this, but make
    // it explicit so a different-uid process can't push keys or sign.
    var euid = uid_t(); var egid = gid_t()
    if getpeereid(cfd, &euid, &egid) != 0 || euid != geteuid() { dlog("ssh peer reject (uid mismatch)"); return }
    let connPeer = peerPID(cfd) ?? -1   // for `app`-scope owning-app resolution on sign
    while true {
        // Read 4-byte length
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let n = read(cfd, &lenBuf, 4)
        if n <= 0 { return }
        if n < 4 { return }
        let msgLen = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) |
                     (UInt32(lenBuf[2]) << 8)  | UInt32(lenBuf[3])
        if msgLen == 0 || msgLen > 1_048_576 { return }   // 1 MB sanity cap
        var body = [UInt8](repeating: 0, count: Int(msgLen))
        var got = 0
        while got < Int(msgLen) {
            let r = read(cfd, &body[got], Int(msgLen) - got)
            if r <= 0 { return }
            got += r
        }
        // #40: ADD_IDENTITY / ADD_ID_CONSTRAINED inject a Touch-ID-free signing key — only KeePassXC may.
        let mtype = body.first ?? 0
        if mtype == SSH_AGENTC_ADD_IDENTITY || mtype == SSH_AGENTC_ADD_ID_CONSTRAINED {
            let v = peerMayPushKeys(cfd)
            if !v.ok {
                dlog("ADD_IDENTITY reject: pid=\(v.pid) path=\(v.path) — not an allowed pusher")
                let deny = framed(Data([SSH_AGENT_FAILURE]))
                deny.withUnsafeBytes { _ = write(cfd, $0.baseAddress, deny.count) }
                continue
            }
        }
        let reply = handleMessage(Data(body), peer: connPeer)
        reply.withUnsafeBytes { _ = write(cfd, $0.baseAddress, reply.count) }
    }
}

// MARK: - Cleanup / signals

func cleanup() {
    pushedClear()   // zero KeePassXC-pushed keys on exit (P6)
    sshCacheClear() // zero the scope-cached SSH keys (vault close)
    // Wipe /tmp/s3c-gorilla/ on session end
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: touchidPath)
    proc.arguments = ["wrap-clear"]
    try? proc.run()
    proc.waitUntilExit()
    try? FileManager.default.removeItem(atPath: socketPath)
}

// zeroOut → ssh-wire.swift (#13)

// MARK: - Binary integrity (#43)
let agentCdhashPinPath = "/usr/local/share/s3c-gorilla/agent.cdhash"

// Our own code-directory hash (hex). The installer pins THIS exact value via `--cdhash`, so the
// pin format can never disagree with the self-check below. Returns nil if the platform won't
// surface cdhashes — in which case the installer writes no pin and the agent runs unverified.
func selfCdhashHex() -> String? {
    var codeRef: SecCode?
    guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
    var staticRef: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let sc = staticRef else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, [], &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let hashes = dict[kSecCodeInfoCdHashes as String] as? [Data],
          let primary = hashes.first else { return nil }
    return primary.map { String(format: "%02x", $0) }.joined()
}

// L2/L3: refuse to run if tampered. Enforce-if-present — a MISSING pin logs and continues
// (UNVERIFIED) so existing installs never crash-loop under KeepAlive; once the installer writes a
// pin (from this same binary), L2 validity + L3 cdhash match are enforced. Exit codes 91-93 are
// diagnosable in /tmp/s3c-ssh-agent.err.log.
func verifySelfOrExit() {
    guard let pin = (try? String(contentsOfFile: agentCdhashPinPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !pin.isEmpty else {
        fputs("cdhash pin absent — running UNVERIFIED (#43 not enforced)\n", stderr); return
    }
    var codeRef: SecCode?
    if SecCodeCopySelf([], &codeRef) != errSecSuccess || codeRef == nil
        || SecCodeCheckValidity(codeRef!, [], nil) != errSecSuccess {
        fputs("SecCodeCheckValidity failed — refusing to start (#43 L2)\n", stderr); exit(91)
    }
    guard let mine = selfCdhashHex() else {
        fputs("cdhash unreadable but pin present — refusing to start (#43 L3)\n", stderr); exit(92)
    }
    if mine != pin {
        fputs("cdhash mismatch self=\(mine) pin=\(pin) — refusing to start (#43 L3)\n", stderr); exit(93)
    }
}

// MARK: - Main
// @main (not top-level code) so this file can compile together with ssh-wire.swift —
// multi-file builds forbid top-level statements (#13).
@main
struct SSHAgentMain {
static func main() {
    // Installer support: print our cdhash and exit (used to write the integrity pin). Must run
    // before verifySelfOrExit so the pin can be computed on a still-unpinned fresh install.
    if CommandLine.arguments.contains("--cdhash") { print(selfCdhashHex() ?? ""); exit(0) }
    verifySelfOrExit()   // #43: refuse to serve a tampered binary (no-op until a pin is written)
    // SIGTERM / SIGINT → wipe + exit.
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler { cleanup(); exit(0) }
    termSource.resume()
    signal(SIGTERM, SIG_IGN)
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler { cleanup(); exit(0) }
    intSource.resume()
    signal(SIGINT, SIG_IGN)

    // No core dumps — never leak secrets on crash. (B4)
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    setrlimit(RLIMIT_CORE, &coreLimit)

    // Wipe every cached secret the instant the screen locks (#26, default ON; mirrors the
    // session-agent). cleanup() zeros pushed keys + wrap-clears /tmp; KeepAlive relaunches us.
    // dispatchMain() below hosts the run loop the observer needs.
    if boolConfig("GORILLA_WIPE_ON_SCREEN_LOCK", default: true) {
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in cleanup(); exit(0) }
    }

    // Sleep / lid-close = vault close too (Yaro's rule). KeepAlive relaunches us on wake, so the
    // next SSH sign re-bootstraps. Mirrors the screen-lock handler.
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { _ in cleanup(); exit(0) }

    // serve() is a tight accept-loop — must run off the main queue so dispatchMain()
    // can process the DispatchSource signal handlers registered above.
    DispatchQueue.global(qos: .userInitiated).async { serve() }
    dispatchMain()
}
}
