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
//   s3c-session-agent start <tty> <ppid>   # read pw from stdin, daemonize, hold
//   s3c-session-agent get   <tty>          # print pw if unlocked & unexpired
//   s3c-session-agent stop  <tty>          # wipe + exit the agent for this tty

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

// MARK: - Obfuscated, mlock'd secret store

// Holds the master password as a CryptoKit AES-GCM sealed box. BE HONEST ABOUT WHAT THIS
// BUYS: the key and the sealed bytes both live in this same process's (mlock'd) memory, so
// an attacker who can read our address space (debugger, same-uid + task_for_pid) gets both
// and trivially recovers the password — this is NOT encryption-at-rest-in-RAM. What it
// actually defends: the password never sits as plaintext in a core dump, a `strings` of the
// heap, or swap (RLIMIT_CORE=0 + mlock), and the AEAD tag catches accidental corruption.
// Defense-in-depth and tidiness, not a cryptographic boundary against a privileged peer. (H5)
final class SecretBox {
    private var keyPtr: UnsafeMutableRawPointer
    private var sealedPtr: UnsafeMutableRawPointer
    private let keyLen = 32
    private let sealedLen: Int

    init?(_ pw: [UInt8]) {
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(Data(pw), using: key),
              let combined = sealed.combined else { return nil }
        sealedLen = combined.count
        keyPtr = UnsafeMutableRawPointer.allocate(byteCount: keyLen, alignment: 1)
        sealedPtr = UnsafeMutableRawPointer.allocate(byteCount: max(sealedLen, 1), alignment: 1)
        if mlock(keyPtr, keyLen) != 0 { dlog("mlock(key) failed: \(String(cString: strerror(errno)))") }
        if mlock(sealedPtr, max(sealedLen, 1)) != 0 { dlog("mlock(sealed) failed: \(String(cString: strerror(errno)))") }
        key.withUnsafeBytes { raw in keyPtr.copyMemory(from: raw.baseAddress!, byteCount: keyLen) }
        combined.withUnsafeBytes { raw in sealedPtr.copyMemory(from: raw.baseAddress!, byteCount: sealedLen) }
    }

    // Reveal into a fresh buffer; caller must zero it after use. nil on tamper/failure.
    func reveal() -> [UInt8]? {
        let key = SymmetricKey(data: Data(bytes: keyPtr, count: keyLen))
        let combined = Data(bytes: sealedPtr, count: sealedLen)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return [UInt8](plain)
    }

    func wipe() {
        memset(keyPtr, 0, keyLen)
        memset(sealedPtr, 0, max(sealedLen, 1))
        munlock(keyPtr, keyLen); munlock(sealedPtr, max(sealedLen, 1))
        keyPtr.deallocate(); sealedPtr.deallocate()
    }
}

// MARK: - Hardening

func hardenProcess() {
    var rl = rlimit(rlim_cur: 0, rlim_max: 0)   // no core dumps — never leak memory on crash
    setrlimit(RLIMIT_CORE, &rl)
}

// MARK: - Low-level unix socket

func makeSockaddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { bp in
            for (i, b) in bytes.enumerated() where i < 104 { bp[i] = b }
        }
    }
    return addr
}

func selfPath() -> String {
    // Robust: ask dyld for our own absolute path (B9).
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    if size > 0 {
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 { return String(cString: buf) }
    }
    let a0 = CommandLine.arguments[0]
    return a0.hasPrefix("/") ? a0 : "/usr/local/bin/s3c-session-agent"
}

// MARK: - Client (get / stop)

// Send a newline-terminated request ("G", "Q", "E <entry>", "O <entry>") and read
// the full response. nil if no live agent answers.
func clientSend(tty: String, _ request: String) -> [UInt8]? {
    let path = socketPath(forTTY: tty)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = makeSockaddr(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { return nil }
    let line = Array((request + "\n").utf8)
    guard write(fd, line, line.count) == line.count else { return nil }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

// MARK: - In-agent kdbx extraction (B1/B2 — the master pw never returns to bash)

var gEnvCache: [String: Data] = [:]
var gSshKeyCache: [String: Data] = [:]   // extracted SSH private bytes — don't rotate in a session (HR #11)
var gOtpCfg: [String: OtpCfg] = [:]      // validated TOTP seeds → compute codes locally (HR #12)

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

func dbPath() -> String {
    var db = "\(homeDir)/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GORILLA_DB=") {
                db = String(t.dropFirst("GORILLA_DB=".count))
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "$HOME", with: homeDir)
            }
        }
    }
    return db
}

// Run keepassxc-cli with the revealed master pw on stdin; pw is zeroed before return.
func runKeepassxc(_ kpxcArgs: [String]) -> Data? {
    guard var pw = boxReveal() else { return nil }   // snapshot pw under the lock, then release
    defer { for i in 0..<pw.count { pw[i] = 0 } }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: keepassxcPath())
    proc.arguments = kpxcArgs
    let inP = Pipe(), outP = Pipe()
    proc.standardInput = inP; proc.standardOutput = outP
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { dlog("keepassxc spawn failed"); return nil }
    inP.fileHandleForWriting.write(Data(pw + [0x0a]))
    try? inP.fileHandleForWriting.close()
    let out = outP.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        dlog("keepassxc exit \(proc.terminationStatus): \(kpxcArgs.prefix(2).joined(separator: " "))")
        return nil
    }
    return out
}

// extract-env: .env content is stable → cache per entry (B2).
func extractEnv(_ entry: String) -> Data? {
    touchActivity()
    if let cached = cacheGet(entry) { return cached }
    guard let d = runKeepassxc(["attachment-export", dbPath(), entry, ".env", "--stdout", "-q"]),
          !d.isEmpty else { return nil }
    cacheSet(entry, d)
    return d
}

// --- Local TOTP (RFC 6238) so otp codes don't cost a keepassxc spawn each call (HR #12) ---
struct OtpCfg { let secret: String; let period: Int; let digits: Int; let algo: String }

func base32Decode(_ s: String) -> [UInt8]? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var lut = [Character: Int](); for (i, c) in alphabet.enumerated() { lut[c] = i }
    var bits = 0, value = 0, out = [UInt8]()
    for ch in s.uppercased() {
        if ch == "=" || ch == " " || ch == "-" { continue }
        guard let v = lut[ch] else { return nil }
        value = (value << 5) | v; bits += 5
        if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
    }
    return out.isEmpty ? nil : out
}

func parseOtpauth(_ raw: String) -> OtpCfg? {
    // Accept a full otpauth:// URI or a bare base32 seed (legacy keepassxc attribute).
    var secret = "", period = 30, digits = 6, algo = "SHA1"
    if let q = raw.contains("?") ? raw.split(separator: "?").last : nil {
        for kv in q.split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1); guard p.count == 2 else { continue }
            let v = String(p[1])
            switch p[0].lowercased() {
            case "secret": secret = v
            case "period": period = Int(v) ?? 30
            case "digits": digits = Int(v) ?? 6
            case "algorithm": algo = v
            default: break
            }
        }
    } else {
        secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return secret.isEmpty ? nil : OtpCfg(secret: secret, period: period, digits: digits, algo: algo)
}

func totpNow(_ cfg: OtpCfg) -> String? { totpAt(cfg, Date().timeIntervalSince1970) }

// Time injectable so the math is deterministically testable (RFC 6238 vector — see __totptest).
func totpAt(_ cfg: OtpCfg, _ unixTime: TimeInterval) -> String? {
    guard let key = base32Decode(cfg.secret) else { return nil }
    let period = cfg.period > 0 ? cfg.period : 30
    var counter = UInt64(unixTime) / UInt64(period)
    var msg = [UInt8](repeating: 0, count: 8)
    var i = 7; while i >= 0 { msg[i] = UInt8(counter & 0xff); counter >>= 8; i -= 1 }
    let sk = SymmetricKey(data: Data(key))
    let mac: [UInt8]
    switch cfg.algo.uppercased() {
    case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: Data(msg), using: sk))
    case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: Data(msg), using: sk))
    default:       mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(msg), using: sk))
    }
    let off = Int(mac[mac.count - 1] & 0x0f)
    let bin = (UInt32(mac[off] & 0x7f) << 24) | (UInt32(mac[off + 1]) << 16) | (UInt32(mac[off + 2]) << 8) | UInt32(mac[off + 3])
    var mod = 1; for _ in 0..<cfg.digits { mod *= 10 }
    var str = String(Int(bin) % mod)
    while str.count < cfg.digits { str = "0" + str }   // manual pad — avoids %d 32/64-bit CVarArg
    return str
}

// extract-otp: prefer a locally-computed code from a previously VALIDATED seed; otherwise ask
// keepassxc (authoritative) and only cache the seed if our local code matches it — so a wrong
// parser/impl degrades to the correct slow path and can never emit a wrong code.
func extractOtp(_ entry: String) -> Data? {
    touchActivity()
    if let cfg = otpCfgGet(entry), let code = totpNow(cfg) { return Data(code.utf8) }
    guard let kc = runKeepassxc(["show", "-t", dbPath(), entry, "-q"]) else { return nil }
    let kcCode = String(data: kc, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !kcCode.isEmpty,
       let raw = runKeepassxc(["show", "-a", "otp", "--show-protected", dbPath(), entry, "-q"]),
       let uri = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let cfg = parseOtpauth(uri) {
        // Validate against keepassxc for the CURRENT or PREVIOUS 30s window — if the period
        // rolled between keepassxc's compute and ours, a single-window compare would never match
        // and we'd stay on the slow path forever (HR #13).
        let now = Date().timeIntervalSince1970
        let period = TimeInterval(cfg.period > 0 ? cfg.period : 30)
        if totpAt(cfg, now) == kcCode || totpAt(cfg, now - period) == kcCode {
            otpCfgSet(entry, cfg)
        }
    }
    return kc
}

// list <group> — enumerate entries under GROUP/ (e.g. "2FA") for otp discovery.
func extractList(_ group: String) -> Data? {
    touchActivity()
    return runKeepassxc(["ls", dbPath(), "\(group)/", "-q"])
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

func serve(tty: String, ppid: pid_t) -> Never {
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
    let ttl = ttlSeconds()
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
    child.arguments = ["__serve", tty, ppidStr]
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
    setsid()   // new session, no controlling tty — a tab close won't SIGHUP us
    var pwBytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
    while pwBytes.last == 0x0a { pwBytes.removeLast() }
    guard !pwBytes.isEmpty else { exit(1) }
    let devnull = open("/dev/null", O_RDWR)   // detach std fds now the pw is read
    if devnull >= 0 { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); if devnull > 2 { close(devnull) } }
    gBox = SecretBox(pwBytes)
    for i in 0..<pwBytes.count { pwBytes[i] = 0 }
    guard gBox != nil else { dlog("SecretBox seal failed"); _exit(1) }
    serve(tty: tty, ppid: ppid)

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
