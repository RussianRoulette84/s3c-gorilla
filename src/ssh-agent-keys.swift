// ssh-agent-keys — the on-disk key registry, public-key blobs, the two protocol handlers
// (REQUEST_IDENTITIES / SIGN_REQUEST) and the password-mode caches. Part of s3c-ssh-agent.

import Foundation
import Security
import Darwin

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
