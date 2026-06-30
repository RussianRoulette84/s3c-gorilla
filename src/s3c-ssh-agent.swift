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

func handleSignRequest(body: Data) -> Data {
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
    guard let sig = sign(entry: entry, data: signData, flags: flags) else {
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

// MARK: - Sign dispatch (mode + key type)

func sign(entry: KeyEntry, data: Data, flags: UInt32) -> Data? {
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
    // chip-wrap: unwrap bytes via touchid-gorilla (triggers Touch ID), parse, sign, zero.
    guard var keyBytes = unwrapViaTouchID(name: "ssh-\(entry.name)") else { return nil }
    defer { zeroOut(&keyBytes) }

    switch entry.keyType {
    case "ssh-ed25519":
        return signEd25519(openSSHBlob: keyBytes, data: data)
    case "ecdsa-sha2-nistp256":
        return signECDSAP256(openSSHBlob: keyBytes, data: data)
    case "ssh-rsa":
        return signRSA(pkcs1DER: keyBytes, data: data, flags: flags)
    default:
        return nil
    }
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
    let boot = bootEpoch()
    return boot > 0 && mt < boot
}

func unwrapViaTouchID(name: String) -> Data? {
    // Bootstrap if the blob is missing OR predates the last boot (stale → re-wrap fresh).
    let blobPath = "\(blobDir)/\(name).blob"
    if !FileManager.default.fileExists(atPath: blobPath) || blobIsStale(blobPath) {
        if blobIsStale(blobPath) { try? FileManager.default.removeItem(atPath: blobPath) }
        guard bootstrapBlob(name: name) else { return nil }
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
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return proc.terminationStatus == 0 ? data : nil
}

// MARK: - Bootstrap: prompt master pw (osascript), extract from kdbx, wrap

func bootstrapBlob(name: String) -> Bool {
    // name is "ssh-<keyname>"; extract the bare keyname to find the kdbx entry.
    guard name.hasPrefix("ssh-") else { return false }
    let keyName = String(name.dropFirst(4))
    guard let pw = askMasterPassword() else { return false }

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
    return proc.terminationStatus == 0
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

func handleMessage(_ msg: Data) -> Data {
    guard let type = msg.first else { return framed(Data([SSH_AGENT_FAILURE])) }
    let body = msg.count > 1 ? msg.subdata(in: 1..<msg.count) : Data()
    switch type {
    case SSH_AGENTC_REQUEST_IDENTITIES:
        return handleRequestIdentities()
    case SSH_AGENTC_SIGN_REQUEST:
        return handleSignRequest(body: body)
    case SSH_AGENTC_ADD_IDENTITY:
        return handleAddIdentity(body)
    case SSH_AGENTC_ADD_ID_CONSTRAINED:
        return handleAddIdentity(body, constrained: true)
    case SSH_AGENTC_REMOVE_IDENTITY:
        return handleRemoveIdentity(body)
    case SSH_AGENTC_REMOVE_ALL_IDENTITIES:
        return handleRemoveAll()
    default:
        dlog("unhandled ssh-agent message type \(type) (\(msg.count)b)")   // #4 diagnostics
        return framed(Data([SSH_AGENT_FAILURE]))
    }
}

// MARK: - Socket server

func serve() {
    // Ensure config dir
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    try? FileManager.default.createDirectory(atPath: pubDir, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
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
        while true { sleep(60); pushedExpire(ttl) }
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

func handleConnection(_ cfd: Int32) {
    // Reject any peer that isn't the same uid (#3) — socket 0600 already limits this, but make
    // it explicit so a different-uid process can't push keys or sign.
    var euid = uid_t(); var egid = gid_t()
    if getpeereid(cfd, &euid, &egid) != 0 || euid != geteuid() { dlog("ssh peer reject (uid mismatch)"); return }
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
        let reply = handleMessage(Data(body))
        reply.withUnsafeBytes { _ = write(cfd, $0.baseAddress, reply.count) }
    }
}

// MARK: - Cleanup / signals

func cleanup() {
    pushedClear()   // zero KeePassXC-pushed keys on exit (P6)
    // Wipe /tmp/s3c-gorilla/ on session end
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: touchidPath)
    proc.arguments = ["wrap-clear"]
    try? proc.run()
    proc.waitUntilExit()
    try? FileManager.default.removeItem(atPath: socketPath)
}

// zeroOut → ssh-wire.swift (#13)

// MARK: - Main
// @main (not top-level code) so this file can compile together with ssh-wire.swift —
// multi-file builds forbid top-level statements (#13).
@main
struct SSHAgentMain {
static func main() {
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

    // serve() is a tight accept-loop — must run off the main queue so dispatchMain()
    // can process the DispatchSource signal handlers registered above.
    DispatchQueue.global(qos: .userInitiated).async { serve() }
    dispatchMain()
}
}
