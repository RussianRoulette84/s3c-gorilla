// s3c-ssh-agent — ssh-agent protocol server backed by Secure Enclave
// (Mode 2: SE-born keys) or chip-wrapped kdbx-extracted keys (Mode 1).
//
// Listens on ~/.s3c-gorilla/agent.sock. Every sign request fires Touch ID.
// Keys never persist in agent memory across requests.
//
// Mode 1 supports Ed25519, ECDSA-P256, and RSA (rsa-sha2-256/512) key types.
// RSA signing is shared with the password-mode agent via ssh-rsa.swift (#RSA).

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

// MARK: - Pushed keys (KeePassXC GUI integration, P6 + hardening)
// KeePassXC pushes SSH keys via ADD_IDENTITY when you unlock the app. We hold them in memory
// and sign WITHOUT Touch ID (you authed via the GUI). Hardened: the raw key bytes are kept in a
// zeroable buffer and memset on clear (#1); an idle TTL + screen lock + REMOVE_ALL + SIGTERM all
// drop them (#2); the cache is capped (#11). Ed25519 / ECDSA-P256 / RSA supported (#5).
let SSH_AGENTC_ADD_IDENTITY: UInt8 = 17
let SSH_AGENTC_REMOVE_IDENTITY: UInt8 = 18
let SSH_AGENTC_REMOVE_ALL_IDENTITIES: UInt8 = 19
let SSH_AGENTC_ADD_ID_CONSTRAINED: UInt8 = 25
let SSH_AGENTC_EXTENSION: UInt8 = 27          // we implement no extensions — decline quietly
let pushedMax = 64

struct PushedKey {
    let keyType: String     // ssh-ed25519 | ecdsa-sha2-nistp256 | ssh-rsa
    var priv: [UInt8]       // zeroable: ed25519 seed(32) | ecdsa d(32) | rsa PKCS#1 DER
    var aux: [UInt8]        // ecdsa: Q (0x04||X||Y); else empty
    let comment: String
    var added: Date
    mutating func zero() { for i in priv.indices { priv[i] = 0 }; for i in aux.indices { aux[i] = 0 } }
}
var gPushed: [Data: PushedKey] = [:]   // pubBlob -> key
let pushedQueue = DispatchQueue(label: "s3c-gorilla.pushed")

func pushedGet(_ blob: Data) -> PushedKey? { pushedQueue.sync { gPushed[blob] } }
func pushedList() -> [(Data, String)] { pushedQueue.sync { gPushed.map { ($0.key, $0.value.comment) } } }
func pushedClear() { pushedQueue.sync { for k in gPushed.keys { gPushed[k]?.zero() }; gPushed.removeAll() } }  // memset then drop (#1)
func pushedExpire(_ ttl: TimeInterval) {   // idle TTL (#2)
    let now = Date()
    pushedQueue.sync { for (b, pk) in gPushed where now.timeIntervalSince(pk.added) > ttl { gPushed[b]?.zero(); gPushed[b] = nil } }
}
func pushedAdd(_ blob: Data, _ key: PushedKey) -> Bool {
    pushedQueue.sync {
        if gPushed[blob] == nil && gPushed.count >= pushedMax { return false }   // cap (#11)
        gPushed[blob]?.zero(); gPushed[blob] = key; return true
    }
}
let pushedHardMaxAge: TimeInterval = 300   // #20: drop pushed keys 5 min after add, regardless of TTL
// #20 heartbeat: KeePassXC pushes keys on unlock and is supposed to REMOVE_ALL on lock; if it
// died without doing so, its keys can never be re-authed — drop them. Fail-open if pgrep is absent.
func keePassXCRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "KeePassXC"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return true }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// Rebuild the live key from the stored bytes, sign, zero any rebuilt copy (#1).
func pushedSign(_ pk: PushedKey, _ data: Data, _ flags: UInt32) -> Data? {
    switch pk.keyType {
    case "ssh-ed25519":
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(pk.priv)),
              let sig = try? key.signature(for: data) else { return nil }
        var out = Data(); out.append(wireString("ssh-ed25519")); out.append(wireString(Data(sig))); return out
    case "ecdsa-sha2-nistp256":
        var raw = Data(pk.aux); raw.append(contentsOf: pk.priv)   // Q || D
        defer { raw.resetBytes(in: 0..<raw.count) }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                    kSecAttrKeySizeInBits as String: 256]
        var e: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, &e),
              let der = SecKeyCreateSignature(secKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &e) as Data?,
              let (rr, ss) = parseECDSADer(der) else { return nil }
        var inner = Data(); inner.append(wireMpint(rr)); inner.append(wireMpint(ss))
        var out = Data(); out.append(wireString("ecdsa-sha2-nistp256")); out.append(wireString(inner)); return out
    case "ssh-rsa":
        return signRSA(pkcs1DER: Data(pk.priv), data: data, flags: flags)
    default: return nil
    }
}

func registryHasPubBlob(_ blob: Data) -> Bool {
    for e in loadRegistry() { if pubBlob(for: e) == blob { return true } }
    return false
}

func handleAddIdentity(_ body: Data, constrained: Bool = false) -> Data {
    var r = Reader(data: body)
    guard let typeData = r.readString(), let ktype = String(data: typeData, encoding: .utf8) else {
        dlog("ADD_IDENTITY: could not read key type (\(body.count)b)"); return framed(Data([SSH_AGENT_FAILURE]))
    }
    var blob = Data(); var pk: PushedKey?
    switch ktype {
    case "ssh-ed25519":
        guard let pub = r.readString(), let priv = r.readString(), priv.count >= 32 else {
            dlog("ADD_IDENTITY ed25519: short fields"); return framed(Data([SSH_AGENT_FAILURE]))
        }
        let comment = r.readString().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        blob.append(wireString("ssh-ed25519")); blob.append(wireString(pub))
        pk = PushedKey(keyType: "ssh-ed25519", priv: Array(priv.subdata(in: 0..<32)), aux: [], comment: comment, added: Date())
    case "ecdsa-sha2-nistp256":
        guard let _ = r.readString(), let q = r.readString(), var d = r.readMpint() else {
            dlog("ADD_IDENTITY ecdsa: short fields"); return framed(Data([SSH_AGENT_FAILURE]))
        }
        while d.count > 32 { d.removeFirst() }                       // #18 robust scalar
        while d.count < 32 { d = Data([0]) + d }
        guard q.count == 65 else { dlog("ADD_IDENTITY ecdsa: bad point \(q.count)b"); return framed(Data([SSH_AGENT_FAILURE])) }
        let comment = r.readString().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        blob.append(wireString("ecdsa-sha2-nistp256")); blob.append(wireString("nistp256")); blob.append(wireString(q))
        pk = PushedKey(keyType: "ecdsa-sha2-nistp256", priv: Array(d), aux: Array(q), comment: comment, added: Date())
    case "ssh-rsa":                                                  // #5 RSA pushes
        guard let n = r.readMpint(), let e = r.readMpint(), let dd = r.readMpint(),
              let iqmp = r.readMpint(), let p = r.readMpint(), let qq = r.readMpint() else {
            dlog("ADD_IDENTITY rsa: short fields"); return framed(Data([SSH_AGENT_FAILURE]))
        }
        let comment = r.readString().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var ossh = Data()                                            // rebuild OpenSSH RSA private wire
        ossh.append(wireString("ssh-rsa")); ossh.append(wireMpint(n)); ossh.append(wireMpint(e))
        ossh.append(wireMpint(dd)); ossh.append(wireMpint(iqmp)); ossh.append(wireMpint(p)); ossh.append(wireMpint(qq))
        guard let pkcs1 = convertOpenSSHRSAToPKCS1(ossh) else {
            dlog("ADD_IDENTITY rsa: CRT conversion failed"); return framed(Data([SSH_AGENT_FAILURE]))
        }
        blob.append(wireString("ssh-rsa")); blob.append(wireMpint(e)); blob.append(wireMpint(n))
        pk = PushedKey(keyType: "ssh-rsa", priv: Array(pkcs1), aux: [], comment: comment, added: Date())
    default:
        dlog("ADD_IDENTITY: unsupported type \(ktype)"); return framed(Data([SSH_AGENT_FAILURE]))
    }
    guard let key = pk else { return framed(Data([SSH_AGENT_FAILURE])) }
    guard pushedAdd(blob, key) else { dlog("ADD_IDENTITY: cap \(pushedMax) reached"); return framed(Data([SSH_AGENT_FAILURE])) }
    if registryHasPubBlob(blob) { dlog("pushed key shadows a vault key — will sign WITHOUT Touch ID") }   // #16
    dlog("pushed key added: \(ktype) \(key.comment)\(constrained ? " (constrained — constraints ignored)" : "")")
    return framed(Data([SSH_AGENT_SUCCESS]))
}

func handleRemoveIdentity(_ body: Data) -> Data {
    var r = Reader(data: body)
    guard let blob = r.readString() else { return framed(Data([SSH_AGENT_FAILURE])) }
    pushedQueue.sync { gPushed[blob]?.zero(); gPushed[blob] = nil }
    return framed(Data([SSH_AGENT_SUCCESS]))
}
func handleRemoveAll() -> Data { pushedClear(); dlog("pushed keys cleared (REMOVE_ALL)"); return framed(Data([SSH_AGENT_SUCCESS])) }

// MARK: - Key registry (~/.s3c-gorilla/keys.json)

struct KeyEntry: Codable {
    let name: String         // e.g. "id_rsa" or "work"
    let mode: String         // "chip-wrap" or "se-born"
    let keyType: String      // "ssh-ed25519" | "ecdsa-sha2-nistp256" | "ssh-rsa"
}

func loadRegistry() -> [KeyEntry] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)) else { return [] }
    return (try? JSONDecoder().decode([KeyEntry].self, from: data)) ?? []
}

// MARK: - SSH wire format helpers
// wireString / wireMpint / Reader / zeroOut / framed / parseECDSADer now live once in
// ssh-wire.swift (#13), compiled alongside this file.

// MARK: - Public key blob lookup (~/.s3c-gorilla/pubkeys/<name>.pub or from SE)

func pubBlob(for entry: KeyEntry) -> Data? {
    if entry.mode == "se-born" {
        // Derive from SE key
        return seBornPubBlob(name: entry.name)
    }
    // chip-wrap: read cached pub file (saved during install)
    let path = "\(pubDir)/\(entry.name).pub"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    // OpenSSH format: "<type> <base64blob> <comment>"
    let parts = content.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }
    return Data(base64Encoded: String(parts[1]))
}

func seBornPubBlob(name: String) -> Data? {
    let tag = (sshKeyTagPrefix + name).data(using: .utf8)!
    let q: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrApplicationTag as String: tag,
        kSecReturnRef as String: true
    ]
    var ref: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
          let priv = ref as! SecKey?,
          let pub = SecKeyCopyPublicKey(priv) else { return nil }
    var error: Unmanaged<CFError>?
    guard let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { return nil }
    var wire = Data()
    wire.append(wireString("ecdsa-sha2-nistp256"))
    wire.append(wireString("nistp256"))
    wire.append(wireString(raw))
    return wire
}

// MARK: - REQUEST_IDENTITIES handler

func handleRequestIdentities() -> Data {
    let entries = loadRegistry()
    var body = Data()
    var count: UInt32 = 0
    var seen = Set<Data>()
    for e in entries {
        guard let blob = pubBlob(for: e) else { continue }
        seen.insert(blob)
        body.append(wireString(blob))
        body.append(wireString("s3c-gorilla-\(e.name) (\(e.mode))"))
        count += 1
    }
    for (blob, comment) in pushedList() where !seen.contains(blob) {   // KeePassXC-pushed, deduped (#20)
        body.append(wireString(blob))
        body.append(wireString("\(comment) (pushed by KeePassXC)"))
        count += 1
    }
    var out = Data()
    out.append(SSH_AGENT_IDENTITIES_ANSWER)
    var c = count.bigEndian
    out.append(Data(bytes: &c, count: 4))
    out.append(body)
    return framed(out)
}

// MARK: - SIGN_REQUEST handler

func handleSignRequest(body: Data, peer: pid_t) -> Data {
    var r = Reader(data: body)
    guard let keyBlob = r.readString(),
          let signData = r.readString(),
          let flags = r.readUInt32() else {
        return framed(Data([SSH_AGENT_FAILURE]))
    }
    // KeePassXC-pushed keys sign WITHOUT Touch ID (you authed by unlocking the GUI). Checked
    // before the registry so a pushed key shadows a chip-wrapped one of the same identity (P6).
    if let pk = pushedGet(keyBlob) {
        guard let sig = pushedSign(pk, signData, flags) else { return framed(Data([SSH_AGENT_FAILURE])) }
        var out = Data(); out.append(SSH_AGENT_SIGN_RESPONSE); out.append(wireString(sig)); return framed(out)
    }
    // Find matching key in registry
    let entries = loadRegistry()
    var matched: KeyEntry? = nil
    for e in entries {
        if let blob = pubBlob(for: e), blob == keyBlob {
            matched = e
            break
        }
    }
    guard let entry = matched else {
        return framed(Data([SSH_AGENT_FAILURE]))
    }
    guard let sig = sign(entry: entry, data: signData, flags: flags, peer: peer) else {
        return framed(Data([SSH_AGENT_FAILURE]))
    }
    var out = Data()
    out.append(SSH_AGENT_SIGN_RESPONSE)
    out.append(wireString(sig))
    return framed(out)
}

// MARK: - Password mode (no Secure Enclave): hold the master password + extracted
// keys in memory for the session TTL, prompting (osascript) at most once per TTL.
// Used on machines with no Touch ID; reuses the same type-specific signers below.

var gPwCache: [UInt8]? = nil   // zeroable byte buffer, not a session-long String (H6)
var gCacheStamp = Date.distantPast
var gKeyCache: [String: Data] = [:]

// Zero + drop the cached master-password bytes.
func clearPwCache() {
    if gPwCache != nil { for i in 0..<gPwCache!.count { gPwCache![i] = 0 }; gPwCache = nil }
}

func passwordTTL() -> Double {
    if let v = ProcessInfo.processInfo.environment["GORILLA_UNLOCK_TTL"], let d = Double(v), d > 0 { return d }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GORILLA_UNLOCK_TTL=") {
                let raw = t.dropFirst("GORILLA_UNLOCK_TTL=".count).replacingOccurrences(of: "\"", with: "")
                if let d = Double(raw), d > 0 { return d }
            }
        }
    }
    return 7200
}

// Generic config bool: env var wins, then ~/.config/s3c-gorilla/config, else `def`.
// "0"/"false"/"no"/"off" (any case) → false; any other non-empty value → true.
func boolConfig(_ key: String, default def: Bool) -> Bool {
    func parse(_ s: String) -> Bool? {
        let v = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "").lowercased()
        if v.isEmpty { return nil }
        return !["0", "false", "no", "off"].contains(v)
    }
    if let v = ProcessInfo.processInfo.environment[key], let b = parse(v) { return b }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key)="), let b = parse(String(t.dropFirst(key.count + 1))) { return b }
        }
    }
    return def
}

// Idle TTL (seconds) after which a /tmp blob is treated as stale and re-fanned-out. Keyed on
// GORILLA_BLOB_TTL; defaults to the same 7200 as passwordTTL so the two lifetimes don't surprise.
func blobTTL() -> Double {
    if let v = ProcessInfo.processInfo.environment["GORILLA_BLOB_TTL"], let d = Double(v), d > 0 { return d }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GORILLA_BLOB_TTL=") {
                let raw = t.dropFirst("GORILLA_BLOB_TTL=".count).replacingOccurrences(of: "\"", with: "")
                if let d = Double(raw), d > 0 { return d }
            }
        }
    }
    return 7200
}

func expireCachesIfStale() {
    if Date().timeIntervalSince(gCacheStamp) > passwordTTL() {
        clearPwCache()
        for k in gKeyCache.keys { var v = gKeyCache[k]!; zeroOut(&v) }
        gKeyCache.removeAll()
    }
}

// Connections are served concurrently (DispatchQueue.global per client), so the
// pw/key caches MUST be accessed under a serial queue — concurrent Dictionary
// mutation crashes. (B7)
let pwCacheQueue = DispatchQueue(label: "s3c-gorilla.pwcache")

func passwordModeKeyBytes(entry: KeyEntry) -> Data? {
    return pwCacheQueue.sync {
    expireCachesIfStale()
    if let cached = gKeyCache[entry.name] { gCacheStamp = Date(); return cached }   // refresh TTL on hit (B6)
    if gPwCache == nil {
        guard let pwStr = askMasterPassword() else { return nil }
        gPwCache = Array(pwStr.utf8); gCacheStamp = Date()   // cache as zeroable bytes (H6)
    }
    // Transient String only for the kdbx call; the cache stays a zeroable buffer.
    guard let pwBytes = gPwCache,
          let raw = extractSSHFromKdbx(masterPw: String(decoding: pwBytes, as: UTF8.self),
                                       keyName: entry.name) else {
        clearPwCache()   // wrong/absent pw → clear so the next sign re-prompts
        return nil
    }
    var payload = raw
    if entry.keyType == "ssh-rsa" {
        guard let der = convertOpenSSHRSAToPKCS1(raw) else { return nil }
        payload = der
    }
    gKeyCache[entry.name] = payload; gCacheStamp = Date()
    return payload
    }
}

// MARK: - Unlock scope cache (stop the per-sign Touch-ID spam)
//
// Chip-wrap normally fires Touch ID on EVERY signature (a deploy = dozens of taps). Here we keep
// the unwrapped key warm in mlock-style zeroable memory for a user-chosen scope, so a burst of
// signs costs one tap. Mirrors the gPushed cache's zero-on-clear discipline. Wiped on screen-lock,
// logout, sleep/lid, and reboot (cleanup()). Default scope `session`; `once` = today's behavior.

struct CachedKey {
    var bytes: [UInt8]           // zeroable payload (OpenSSH blob or RSA PKCS#1 DER)
    let scope: String            // "app" | "session"  (never "once")
    let ownerPID: pid_t          // app scope: the owning app; else 0
    let expiry: Date             // TTL cap (min(scope, timer))
    mutating func zero() { for i in bytes.indices { bytes[i] = 0 } }
}
var gSSHCache: [String: CachedKey] = [:]        // keyName -> warm key
let sshCacheQueue = DispatchQueue(label: "s3c-gorilla.sshcache")

// Session-wide choices set by the unlock window (empty/nil → fall back to config).
var gSessionScope = ""
var gAskPwOverride: Bool? = nil
var gTTLMinutes = 0

func sshCacheClear() { sshCacheQueue.sync { for k in gSSHCache.keys { gSSHCache[k]?.zero() }; gSSHCache.removeAll() } }

// Generic config string: env wins, then ~/.config/s3c-gorilla/config, else `def`.
func stringConfig(_ key: String, default def: String) -> String {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key)=") {
                return String(t.dropFirst(key.count + 1)).replacingOccurrences(of: "\"", with: "")
            }
        }
    }
    return def
}
func effectiveScope() -> String {
    if ["once", "app", "session"].contains(gSessionScope) { return gSessionScope }
    let c = stringConfig("GORILLA_SSH_UNLOCK_SCOPE", default: "session")
    return ["once", "app", "session"].contains(c) ? c : "session"
}
func askPwEachTime() -> Bool { gAskPwOverride ?? boolConfig("GORILLA_SSH_ASK_PW_EACH_TIME", default: false) }
func pidAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

// Walk from the connecting `ssh` process (a throwaway PID) up to the app macOS launched — the
// first ancestor whose parent is launchd (pid 1). For Xcode/SourceTree that's the app; for a
// terminal deploy it's the terminal window. That PID tags an `app`-scope cache entry.
func ppidOf(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    if sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 { return info.kp_eproc.e_ppid }
    return nil
}
func resolveOwningApp(_ pid: pid_t) -> pid_t {
    var cur = pid
    for _ in 0..<32 {
        guard let pp = ppidOf(cur), pp > 1 else { break }
        cur = pp
    }
    return cur
}

// Drop dead-owner app entries + anything past its TTL. Caller holds sshCacheQueue.
func sshReapLocked() {
    let now = Date()
    for (k, c) in gSSHCache where c.expiry < now || (c.scope == "app" && !pidAlive(c.ownerPID)) {
        gSSHCache[k]?.zero(); gSSHCache[k] = nil
    }
}

// The warm-key gate for chip-wrap. Returns the key bytes, unwrapping (one Touch ID) only on a
// miss. Held under the serial queue so a burst of concurrent signs waits on one prompt, then all
// reuse the cache — never two prompts for one unlock.
func chipKeyBytes(entry: KeyEntry, scope: String, peer: pid_t) -> Data? {
    return sshCacheQueue.sync {
        sshReapLocked()
        let paranoid = askPwEachTime()
        if scope != "once" && !paranoid, let c = gSSHCache[entry.name] {
            let ownerOK = c.scope != "app" || (pidAlive(c.ownerPID) && resolveOwningApp(peer) == c.ownerPID)
            if c.expiry > Date() && ownerOK { return Data(c.bytes) }
        }
        // Miss. Paranoid mode forces the password window (drop the blob so unwrap re-bootstraps);
        // otherwise a Touch-ID unwrap of the existing blob.
        if paranoid { try? FileManager.default.removeItem(atPath: "\(blobDir)/ssh-\(entry.name).blob") }
        guard var kb = unwrapViaTouchID(name: "ssh-\(entry.name)", peer: peer) else { return nil }
        let bytes = Array(kb); zeroOut(&kb)
        // The unlock window (shown during a cold bootstrap) may have just set the scope/TTL —
        // re-read them so the store honors the user's actual pick, not the pre-unlock default.
        let storeScope = effectiveScope()
        if storeScope != "once" && !askPwEachTime() {
            let owner = storeScope == "app" ? resolveOwningApp(peer) : 0
            let exp = gTTLMinutes > 0 ? Date().addingTimeInterval(Double(gTTLMinutes) * 60) : Date.distantFuture
            gSSHCache[entry.name]?.zero()
            gSSHCache[entry.name] = CachedKey(bytes: bytes, scope: storeScope, ownerPID: owner, expiry: exp)
        }
        return Data(bytes)
    }
}

// MARK: - Sign dispatch (mode + key type)

func sign(entry: KeyEntry, data: Data, flags: UInt32, peer: pid_t) -> Data? {
    if entry.mode == "se-born" {
        return signSEBorn(name: entry.name, data: data)
    }
    if entry.mode == "password" {
        // No Secure Enclave: extract the key from the kdbx with the master password
        // (cached for the session), then sign with the same routines as chip-wrap.
        guard var keyBytes = passwordModeKeyBytes(entry: entry) else { return nil }
        defer { zeroOut(&keyBytes) }   // zeros our copy; the TTL cache is separate
        switch entry.keyType {
        case "ssh-ed25519":          return signEd25519(openSSHBlob: keyBytes, data: data)
        case "ecdsa-sha2-nistp256":  return signECDSAP256(openSSHBlob: keyBytes, data: data)
        case "ssh-rsa":              return signRSA(pkcs1DER: keyBytes, data: data, flags: flags)
        default:                     return nil
        }
    }
    // chip-wrap: warm-key cache (scope-gated) unwraps at most once per scope window, then reuses.
    guard var keyBytes = chipKeyBytes(entry: entry, scope: effectiveScope(), peer: peer) else { return nil }
    defer { zeroOut(&keyBytes) }   // zeros this working copy; the cache holds its own separate copy

    switch entry.keyType {
    case "ssh-ed25519":
        return signEd25519(openSSHBlob: keyBytes, data: data)
    case "ecdsa-sha2-nistp256":
        return signECDSAP256(openSSHBlob: keyBytes, data: data)
    case "ssh-rsa":
        return signRSA(pkcs1DER: rsaDER(keyBytes) ?? keyBytes, data: data, flags: flags)
    default:
        return nil
    }
}

// An `ssh-<name>.blob` can hold EITHER PKCS#1 DER (what bootstrapBlob writes, pre-converted) or
// raw OpenSSH private bytes (what the bash fan-out writes — it wraps the kdbx attachment as-is).
// Ed25519/ECDSA parse OpenSSH natively so they never noticed; RSA needs the DER, and reading a
// fan-out blob as DER silently produced NO signature → "Permission denied (publickey)" until the
// next cold bootstrap. Detect the format and convert when needed (cheap now that qinv is fast).
func rsaDER(_ blob: Data) -> Data? {
    let magic = Array("openssh-key-v1\0".utf8)
    let isRawOpenSSH = blob.count > magic.count && Array(blob.prefix(magic.count)) == magic
    let isPEM = String(data: blob.prefix(40), encoding: .utf8)?
        .hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") ?? false
    guard isRawOpenSSH || isPEM else { return nil }   // already DER — use as-is
    return convertOpenSSHRSAToPKCS1(blob)
}

// MARK: - Mode 2: SE-born signing (ECDSA P-256)

func signSEBorn(name: String, data: Data) -> Data? {
    let tag = (sshKeyTagPrefix + name).data(using: .utf8)!
    let q: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrApplicationTag as String: tag,
        kSecReturnRef as String: true
    ]
    var ref: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
          let priv = ref as! SecKey? else { return nil }
    var error: Unmanaged<CFError>?
    // .ecdsaSignatureMessageX962SHA256 hashes the data internally and produces DER.
    guard let der = SecKeyCreateSignature(priv, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
        return nil
    }
    // Convert DER (SEQUENCE { INTEGER r, INTEGER s }) to SSH format (mpint r | mpint s | then wrapped in sig blob)
    guard let (r, s) = parseECDSADer(der) else { return nil }
    var inner = Data()
    inner.append(wireMpint(r))
    inner.append(wireMpint(s))
    var sig = Data()
    sig.append(wireString("ecdsa-sha2-nistp256"))
    sig.append(wireString(inner))
    return sig
}

// Minimal ECDSA DER parser — SEQUENCE { INTEGER r, INTEGER s }
// parseECDSADer → ssh-wire.swift (#13)

// MARK: - Mode 1: Ed25519 signing

func signEd25519(openSSHBlob: Data, data: Data) -> Data? {
    // Parse OpenSSH private key, extract 32-byte seed, sign with CryptoKit.
    guard let comps = parseOpenSSHPrivate(openSSHBlob, expectedType: "ssh-ed25519") else { return nil }
    guard let priv = comps["priv"], priv.count >= 32 else { return nil }
    let seed = priv.subdata(in: 0..<32)  // OpenSSH stores seed||pubkey (64b); take first 32 as seed.
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
    guard let sig = try? key.signature(for: data) else { return nil }
    var out = Data()
    out.append(wireString("ssh-ed25519"))
    out.append(wireString(sig))
    return out
}

// MARK: - Mode 1: RSA signing
//
// OpenSSH stores RSA private keys as (n, e, d, iqmp, p, q). PKCS#1 DER
// (what SecKey wants) needs (n, e, d, p, q, dp, dq, qinv). We compute the
// missing CRT params on the fly:
//   dp   = d mod (p-1)
//   dq   = d mod (q-1)
//   qinv = q^(p-2) mod p   (Fermat's little theorem — p is prime)
//
// Then we hand the full PKCS#1 DER to SecKeyCreateWithData and let
// Security.framework produce the actual signature.

// BigN / DER / RSA OpenSSH→PKCS#1 bridge + signRSA moved to shared ssh-rsa.swift (#RSA).

// MARK: - Mode 1: ECDSA P-256 signing

func signECDSAP256(openSSHBlob: Data, data: Data) -> Data? {
    guard let comps = parseOpenSSHPrivate(openSSHBlob, expectedType: "ecdsa-sha2-nistp256") else { return nil }
    guard let pub = comps["pub"], let priv = comps["priv"] else { return nil }
    // SecKey P-256 private key raw format: 0x04 || X || Y || D (ANSI X9.63 with priv scalar appended)
    var raw = Data()
    raw.append(pub)      // 65 bytes: 0x04||X||Y
    raw.append(priv)     // 32 bytes: D
    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits as String: 256
    ]
    var error: Unmanaged<CFError>?
    guard let secKey = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, &error) else { return nil }
    guard let der = SecKeyCreateSignature(secKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
        return nil
    }
    guard let (r, s) = parseECDSADer(der) else { return nil }
    var inner = Data()
    inner.append(wireMpint(r))
    inner.append(wireMpint(s))
    var out = Data()
    out.append(wireString("ecdsa-sha2-nistp256"))
    out.append(wireString(inner))
    return out
}

// MARK: - OpenSSH private key parser (minimal — Ed25519 + ECDSA P-256)

func parseOpenSSHPrivate(_ blob: Data, expectedType: String) -> [String: Data]? {
    // Accept both PEM-wrapped and raw. Most unwraps from touchid-gorilla are PEM text.
    var body = blob
    if let s = String(data: blob, encoding: .utf8), s.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
        let stripped = s
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let decoded = Data(base64Encoded: stripped) else { return nil }
        body = decoded
    }
    // Magic: "openssh-key-v1\0"
    let magic = Array("openssh-key-v1\0".utf8)
    guard body.count > magic.count,
          Array(body.prefix(magic.count)) == magic else { return nil }
    var r = Reader(data: body)
    r.pos = magic.count
    guard let ciphername = r.readString(),
          String(data: ciphername, encoding: .utf8) == "none",
          let _ = r.readString(),  // kdfname ("none")
          let _ = r.readString(),  // kdfoptions (empty)
          let nkeys = r.readUInt32(), nkeys == 1,
          let _ = r.readString(),  // public key (skipped)
          let privSection = r.readString() else { return nil }
    var pr = Reader(data: privSection)
    guard let check1 = pr.readUInt32(),
          let check2 = pr.readUInt32(),
          check1 == check2,
          let keyType = pr.readString(),
          let ktStr = String(data: keyType, encoding: .utf8),
          ktStr == expectedType else { return nil }

    var out: [String: Data] = ["type": keyType]
    switch expectedType {
    case "ssh-ed25519":
        guard let pub = pr.readString(), let priv = pr.readString() else { return nil }
        out["pub"] = pub
        out["priv"] = priv
    case "ecdsa-sha2-nistp256":
        guard let _ = pr.readString(),  // curve name "nistp256"
              let pub = pr.readString(),  // ANSI X9.63 (65 bytes: 0x04||X||Y)
              let d = pr.readMpint() else { return nil }
        out["pub"] = pub
        // Pad scalar to 32 bytes
        var scalar = Data(d)
        while scalar.count < 32 { scalar.insert(0, at: 0) }
        if scalar.count > 32 { scalar = scalar.subdata(in: (scalar.count-32)..<scalar.count) }
        out["priv"] = scalar
    case "ssh-rsa":
        // OpenSSH stores RSA private key as: n, e, d, iqmp, p, q.
        guard let n = pr.readMpint(),
              let e = pr.readMpint(),
              let d = pr.readMpint(),
              let iqmp = pr.readMpint(),
              let p = pr.readMpint(),
              let q = pr.readMpint() else { return nil }
        out["n"] = n
        out["e"] = e
        out["d"] = d
        out["iqmp"] = iqmp
        out["p"] = p
        out["q"] = q
    default:
        return nil
    }
    return out
}

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
