// s3c-session-agent — memory-only, per-tty master-password holder for PASSWORD MODE.
//
// Opt-in "keep unlocked for this terminal tab": holds the KeePass master password
// OBFUSCATED in mlock'd memory so env-gorilla / otp-gorilla (and, in Phase 2,
// ssh) stop re-prompting within the same terminal session. Nothing on disk.
//
// Security: this is a deliberate grace period. During the TTL, a process running
// as the same uid in this terminal can reach the secret (LOCAL_PEERCRED gates the
// socket to same-uid only). Held obfuscated + mlock'd + RLIMIT_CORE=0; wiped on
// TTL, SIGTERM (logout), screen lock, parent-shell death, and reboot (memory-only).
//
// Subcommands (invoked by the shell tools as a client; no `nc` dependency):
//   s3c-session-agent start <tty> <ppid> [ttlSec]   # read pw from stdin, daemonize, hold
//   s3c-session-agent get   <tty>          # print pw if unlocked & unexpired
//   s3c-session-agent stop  <tty>          # wipe + exit the agent for this tty
//
// This file is the daemon: config, the shared state queue, the accept loops and @main.
// session-crypto.swift holds the SecretBox + socket plumbing; session-vault.swift does the
// kdbx extraction and TOTP.

import Foundation
import CryptoKit
import Darwin

let homeDir = NSHomeDirectory()
let sessionDir = "\(homeDir)/.s3c-gorilla/session"
let logPath = "\(homeDir)/Library/Logs/s3c-gorilla/s3c-session-agent.log"

// Best-effort debug log (B12). Single-writer via logQueue (dlog is called from several
// threads — control loop, ssh loop, poll thread), one open handle (no open/close per call),
// rotated to .log.1 past 256 KiB so it can't grow unbounded (HR #10).
let logQueue = DispatchQueue(label: "s3c.session.log")
var logHandle: FileHandle?
var logWrites = 0
func dlog(_ msg: String) {
    logQueue.sync {
        let dir = "\(homeDir)/Library/Logs/s3c-gorilla"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Stat for size only ~once per 100 writes (HR #15) — rotation is coarse, not per-line.
        logWrites += 1
        if logWrites % 100 == 1, let sz = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, sz > 256 * 1024 {
            try? logHandle?.close(); logHandle = nil
            let fm = FileManager.default                       // keep 3 rotations (.1 .2 .3)
            try? fm.removeItem(atPath: logPath + ".3")
            try? fm.moveItem(atPath: logPath + ".2", toPath: logPath + ".3")
            try? fm.moveItem(atPath: logPath + ".1", toPath: logPath + ".2")
            try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
        }
        if logHandle == nil {
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            logHandle = FileHandle(forWritingAtPath: logPath)
            logHandle?.seekToEndOfFile()
        }
        if let data = "[\(Date())] \(msg)\n".data(using: .utf8) { logHandle?.write(data) }
    }
}

// MARK: - Config

func ttlSeconds() -> Double {
    if let v = ProcessInfo.processInfo.environment["GORILLA_UNLOCK_TTL"], let d = Double(v), d > 0 { return d }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GORILLA_UNLOCK_TTL=") {
                let v = t.dropFirst("GORILLA_UNLOCK_TTL=".count).replacingOccurrences(of: "\"", with: "")
                if let d = Double(v), d > 0 { return d }
            }
        }
    }
    return 7200
}

// CONTRACT (HR #5): this hash MUST equal bash `printf '%s' "$tty" | shasum -a 256` so
// ssh-gorilla.sh finds our socket. Pinned vector: "/dev/ttys003" →
// e5d96d283faaf77c73806e19389eeee274841377d60815eb511bb35b79f03bc5
// (asserted in test_session_unlock.bats + test_agent_e2e.bats). Change neither side alone.
func socketPath(forTTY tty: String) -> String {
    let hash = SHA256.hash(data: Data(tty.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(sessionDir)/\(hash).sock"
}

// MARK: - Server (start)

var gBox: SecretBox?
var gSocketPath = ""        // written once in serve() before any thread starts (no guard needed)
var gSshSocketPath = ""     // ditto
var gLastActivity = Date()
var gParentPID: pid_t = 0
var gTTL: TimeInterval = 7200   // set once in serve() before threads; read by the P (ping) handler

// gBox / gEnvCache / gLastActivity / gParentPID are read+written from THREE concurrent
// contexts — the control accept loop, the ssh accept loop, and the TTL poll thread — so
// every access goes through this serial queue (HR #4). The cardinal rule: never hold the
// queue across a keepassxc subprocess — snapshot the password under the lock, release, then
// spawn (see runKeepassxc). So this is a brief SNAPSHOT lock (dictionary/Date touches only),
// NOT a throughput gate — the slow work (keepassxc / signing) runs outside it, in parallel (HR #14).
let stateQueue = DispatchQueue(label: "s3c.session.state")
func touchActivity()                { stateQueue.sync { gLastActivity = Date() } }
func lastActivity() -> Date         { stateQueue.sync { gLastActivity } }
func parentPID() -> pid_t           { stateQueue.sync { gParentPID } }
func boxReveal() -> [UInt8]?        { stateQueue.sync { gBox?.reveal() } }
func cacheGet(_ k: String) -> Data? { stateQueue.sync { gEnvCache[k] } }
func cacheSet(_ k: String, _ v: Data) {
    stateQueue.sync { if gEnvCache.count >= 128 { gEnvCache.removeAll() }; gEnvCache[k] = v }
}
func sshKeyCacheGet(_ k: String) -> Data?    { stateQueue.sync { gSshKeyCache[k] } }
func sshKeyCacheSet(_ k: String, _ v: Data)  { stateQueue.sync { gSshKeyCache[k] = v } }
func otpCfgGet(_ k: String) -> OtpCfg?       { stateQueue.sync { gOtpCfg[k] } }
func otpCfgSet(_ k: String, _ v: OtpCfg)     { stateQueue.sync { gOtpCfg[k] = v } }

func serverCleanupAndExit() -> Never {
    dlog("session wiped + exiting (\(gSocketPath))")
    stateQueue.sync { gBox?.wipe() }   // serialize vs any in-flight boxReveal (HR #4)
    try? FileManager.default.removeItem(atPath: gSocketPath)
    try? FileManager.default.removeItem(atPath: gSshSocketPath)
    _exit(0)
}

// ttlOverride > 0 = the lifetime the user picked in the unlock window (scope → seconds);
// 0 = fall back to GORILLA_UNLOCK_TTL from the config.
func serve(tty: String, ppid: pid_t, ttlOverride: Double = 0) -> Never {
    hardenProcess()
    gParentPID = ppid
    gSocketPath = socketPath(forTTY: tty)
    try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    // Lost the start race: a live agent already answers on this tty → bow out. (B10)
    if clientSend(tty: tty, "G") != nil { _exit(0) }
    try? FileManager.default.removeItem(atPath: gSocketPath)   // stale socket only (no live agent)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { _exit(1) }
    var addr = makeSockaddr(gSocketPath)
    let alen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, alen) }
    }
    guard bound == 0 else {
        if errno == EADDRINUSE { dlog("bind EADDRINUSE — another agent won, exiting cleanly"); _exit(0) }
        dlog("bind failed (\(gSocketPath)): \(String(cString: strerror(errno)))"); _exit(1)
    }
    chmod(gSocketPath, 0o600)
    guard listen(fd, 8) == 0 else { dlog("listen failed: \(String(cString: strerror(errno)))"); _exit(1) }

    // SIGTERM / SIGINT → wipe + exit.
    for sig in [SIGTERM, SIGINT] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { serverCleanupAndExit() }
        src.resume()
        signal(sig, SIG_IGN)
    }

    // TTL + parent-shell-death poll.
    let ttl = ttlOverride > 0 ? ttlOverride : ttlSeconds()
    gTTL = ttl
    DispatchQueue.global().async {
        while true {
            sleep(5)
            if Date().timeIntervalSince(lastActivity()) > ttl { serverCleanupAndExit() }
            let pp = parentPID()
            if pp > 1 && kill(pp, 0) != 0 { serverCleanupAndExit() }   // tab closed
        }
    }

    // Screen lock → wipe + exit.
    _ = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { _ in serverCleanupAndExit() }

    // Serve SSH on a second per-tty socket (B3). ssh-agent-core extracts the key
    // from the kdbx via the held master password and signs (Ed25519 / ECDSA-P256).
    gSshSocketPath = String(gSocketPath.dropLast(5)) + ".ssh.sock"   // <hash>.sock → <hash>.ssh.sock
    sshKeyBytes = { name in
        if let c = sshKeyCacheGet(name) { return c }   // skip the per-sign Argon2 kdbx open (HR #11)
        guard let d = runKeepassxc(["attachment-export", dbPath(), "SSH/\(name)", name, "--stdout", "-q"]),
              !d.isEmpty else { return nil }
        sshKeyCacheSet(name, d)
        return d
    }
    onActivity = { touchActivity() }   // ssh use keeps the session alive (HR #7)
    // Bind the SSH socket SYNCHRONOUSLY (runSSHAgentLoop binds+listens, then backgrounds only
    // its accept loop) — before the control accept loop below answers `get`. So session_unlock
    // can't return until the ssh socket is live, killing the startup race.
    runSSHAgentLoop(sockPath: gSshSocketPath)

    // Accept loop (background) so the main thread runs the notification run loop.
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            handleClient(cfd)
            close(cfd)
        }
    }
    RunLoop.main.run()
    _exit(0)
}

func peerIsSameUID(_ cfd: Int32) -> Bool {
    var euid = uid_t(); var egid = gid_t()
    guard getpeereid(cfd, &euid, &egid) == 0 else { return false }
    return euid == geteuid()
}

// HR #3: the control socket is a vault-extract oracle, so beyond same-uid we require the peer
// to be our OWN binary — env/otp/ssh all reach us by exec'ing s3c-session-agent, so a bare
// same-uid process can't drain secrets through it. Defense-in-depth, not absolute (an attacker
// can still exec us). Fail-OPEN if the peer path can't be read, so a libproc quirk never locks
// out the real tools. (The ssh socket keeps uid-only — its clients are ssh/git/etc.)
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
func peerIsSelf(_ cfd: Int32) -> Bool {
    guard let pid = peerPID(cfd), let path = pathForPID(pid) else { return true }   // fail-open
    return realpathOf(path) == realpathOf(selfPath())
}

func handleClient(_ cfd: Int32) {
    guard peerIsSameUID(cfd) else { dlog("peer-cred reject (uid mismatch)"); return }
    guard peerIsSelf(cfd) else { dlog("peer reject (not our binary)"); return }
    var buf = [UInt8](repeating: 0, count: 8192)
    let n = read(cfd, &buf, buf.count)
    guard n > 0 else { return }
    var line = Array(buf[0..<n])
    while line.last == 0x0a || line.last == 0x0d { line.removeLast() }
    guard let c = line.first else { return }
    let arg = line.count > 2 ? String(decoding: line[2...], as: UTF8.self) : ""   // skip "<c> "
    switch c {
    case UInt8(ascii: "G"):                        // get password (legacy/transitional)
        touchActivity()
        guard var pw = boxReveal() else { return }
        pw.withUnsafeBytes { _ = write(cfd, $0.baseAddress, pw.count) }
        for i in 0..<pw.count { pw[i] = 0 }
    case UInt8(ascii: "Q"):                        // wipe + quit
        serverCleanupAndExit()
    case UInt8(ascii: "E"):                        // extract-env <group/project>
        if let d = extractEnv(arg) { _ = d.withUnsafeBytes { write(cfd, $0.baseAddress, d.count) } }
    case UInt8(ascii: "O"):                        // extract-otp <group/service>
        if let d = extractOtp(arg) { _ = d.withUnsafeBytes { write(cfd, $0.baseAddress, d.count) } }
    case UInt8(ascii: "L"):                        // list <group>
        if let d = extractList(arg) { _ = d.withUnsafeBytes { write(cfd, $0.baseAddress, d.count) } }
    case UInt8(ascii: "P"):                        // ping → "OK <seconds-left>" (no pw, no activity bump)
        let remaining = max(0, Int(gTTL - Date().timeIntervalSince(lastActivity())))
        let bytes = Array("OK \(remaining)".utf8)
        bytes.withUnsafeBytes { _ = write(cfd, $0.baseAddress, bytes.count) }
    default:
        return
    }
}

// MARK: - Entry
// @main (not top-level code) so this file can be compiled together with
// ssh-agent-core.swift — multi-file builds forbid top-level statements.

@main
struct SessionAgentMain {
static func main() {
let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: s3c-session-agent start|get|stop|extract-env|extract-otp|list <tty> [arg]\n", stderr); exit(2)
}
let cmd = args[1]

switch cmd {
case "get":
    guard args.count >= 3 else { exit(2) }
    if let out = clientSend(tty: args[2], "G"), !out.isEmpty {
        out.withUnsafeBytes { _ = write(1, $0.baseAddress, out.count) }
        exit(0)
    }
    exit(1)

case "list":
    guard args.count >= 4 else { exit(2) }
    if let out = clientSend(tty: args[2], "L \(args[3])"), !out.isEmpty {
        out.withUnsafeBytes { _ = write(1, $0.baseAddress, out.count) }
        exit(0)
    }
    exit(1)

case "ping":   // seconds remaining for this tty's session ("OK <n>"), or exit 1 if none
    guard args.count >= 3 else { exit(2) }
    if let out = clientSend(tty: args[2], "P"), !out.isEmpty {
        out.withUnsafeBytes { _ = write(1, $0.baseAddress, out.count) }
        exit(0)
    }
    exit(1)

case "extract-env", "extract-otp":
    guard args.count >= 4 else { exit(2) }
    let verb = cmd == "extract-env" ? "E" : "O"
    if let out = clientSend(tty: args[2], "\(verb) \(args[3])"), !out.isEmpty {
        out.withUnsafeBytes { _ = write(1, $0.baseAddress, out.count) }
        exit(0)
    }
    exit(1)

case "stop":
    guard args.count >= 3 else { exit(2) }
    _ = clientSend(tty: args[2], "Q")
    exit(0)

case "start":
    guard args.count >= 3 else { exit(2) }
    let tty = args[2]
    let ppidStr = args.count >= 4 ? args[3] : "0"
    let ttlStr = args.count >= 5 ? args[4] : "0"   // seconds; 0 = use the configured TTL
    // Idempotent: if an agent is already serving this tty, keep it.
    if let out = clientSend(tty: tty, "G"), !out.isEmpty { exit(0) }
    // Read the master password from stdin (the tool pipes it in, no trailing newline).
    var pwBytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
    while pwBytes.last == 0x0a { pwBytes.removeLast() }
    guard !pwBytes.isEmpty else { exit(1) }
    // Daemonize by RE-EXEC (not fork): a forked process can't safely use GCD /
    // Foundation on Darwin. Spawn a fresh `__serve` process and hand it the
    // password over stdin; it gets orphaned and keeps running after we exit.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfPath())
    child.arguments = ["__serve", tty, ppidStr, ttlStr]
    let inPipe = Pipe()
    child.standardInput = inPipe
    // Detach stdout/stderr so the daemon never holds a caller's $(...) pipe open.
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { exit(1) }
    inPipe.fileHandleForWriting.write(Data(pwBytes))
    inPipe.fileHandleForWriting.closeFile()
    for i in 0..<pwBytes.count { pwBytes[i] = 0 }   // zero our copy; the child holds it now
    exit(0)

case "__serve":
    guard args.count >= 3 else { exit(2) }
    let tty = args[2]
    let ppid = args.count >= 4 ? (pid_t(args[3]) ?? 0) : 0
    let ttlOverride = args.count >= 5 ? (Double(args[4]) ?? 0) : 0
    setsid()   // new session, no controlling tty — a tab close won't SIGHUP us
    var pwBytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
    while pwBytes.last == 0x0a { pwBytes.removeLast() }
    guard !pwBytes.isEmpty else { exit(1) }
    let devnull = open("/dev/null", O_RDWR)   // detach std fds now the pw is read
    if devnull >= 0 { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); if devnull > 2 { close(devnull) } }
    gBox = SecretBox(pwBytes)
    for i in 0..<pwBytes.count { pwBytes[i] = 0 }
    guard gBox != nil else { dlog("SecretBox seal failed"); _exit(1) }
    serve(tty: tty, ppid: ppid, ttlOverride: ttlOverride)

case "__totptest":
    // RFC 6238 vector: base32 of ASCII "12345678901234567890", T=59 (counter 1), SHA1,
    // 8 digits → 94287082. Deterministically validates base32Decode + totpAt (HR #5/#12).
    let cfg = OtpCfg(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", period: 30, digits: 8, algo: "SHA1")
    if let c = totpAt(cfg, 59) { print(c); exit(c == "94287082" ? 0 : 1) }
    exit(1)

default:
    fputs("unknown command: \(cmd)\n", stderr); exit(2)
}
}
}
