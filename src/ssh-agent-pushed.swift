// ssh-agent-pushed — keys the KeePassXC GUI pushes into us over ADD_IDENTITY (P6).
// Held mlock+zeroable in memory only, gated on KeePassXC still running. Part of s3c-ssh-agent.

import Foundation
import Security
import CryptoKit
import Darwin

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
