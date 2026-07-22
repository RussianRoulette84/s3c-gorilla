// session-vault — everything the agent does WITH the held password: run keepassxc-cli,
// extract env secrets / ssh keys / entry lists, and compute TOTP codes locally so the seed
// never leaves this process. Part of s3c-session-agent.

import Foundation
import CryptoKit
import Darwin

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
