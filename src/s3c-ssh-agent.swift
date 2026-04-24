// s3c-ssh-agent — ssh-agent protocol server backed by Secure Enclave
// (Mode 2: SE-born keys) or chip-wrapped kdbx-extracted keys (Mode 1).
//
// Listens on ~/.s3c-gorilla/agent.sock. Every sign request fires Touch ID.
// Keys never persist in agent memory across requests.
//
// Mode 1 supports Ed25519 and ECDSA-P256 key types. RSA (legacy) falls
// through the fallback path (SSH_AGENT_FAILURE → ssh tries next method).
// Recommended RSA users migrate to Ed25519 or use Mode 2 (SE-born).

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

// MARK: - ssh-agent protocol constants

let SSH_AGENTC_REQUEST_IDENTITIES: UInt8 = 11
let SSH_AGENTC_SIGN_REQUEST: UInt8 = 13
let SSH_AGENT_FAILURE: UInt8 = 5
let SSH_AGENT_SUCCESS: UInt8 = 6
let SSH_AGENT_IDENTITIES_ANSWER: UInt8 = 12
let SSH_AGENT_SIGN_RESPONSE: UInt8 = 14

let SSH_AGENT_RSA_SHA2_256: UInt32 = 2
let SSH_AGENT_RSA_SHA2_512: UInt32 = 4

// SE key tag prefix shared with touchid-gorilla.swift
let sshKeyTagPrefix = "s3c-gorilla.ssh."

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

func wireString(_ d: Data) -> Data {
    var out = Data()
    var len = UInt32(d.count).bigEndian
    out.append(Data(bytes: &len, count: 4))
    out.append(d)
    return out
}

func wireString(_ s: String) -> Data { wireString(Data(s.utf8)) }

// mpint = SSH "bignum" — length-prefixed big-endian two's-complement.
// Prepend 0x00 if high bit set (to keep the number positive).
func wireMpint(_ raw: Data) -> Data {
    var bytes = Array(raw)
    // Strip leading zeros
    while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
    // Add leading zero if high bit set
    if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
    return wireString(Data(bytes))
}

struct Reader {
    let data: Data
    var pos: Int = 0

    mutating func readByte() -> UInt8? {
        guard pos < data.count else { return nil }
        let b = data[pos]
        pos += 1
        return b
    }

    mutating func readUInt32() -> UInt32? {
        guard pos + 4 <= data.count else { return nil }
        let v = data[pos..<pos+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        pos += 4
        return UInt32(bigEndian: v)
    }

    mutating func readString() -> Data? {
        guard let len = readUInt32(), pos + Int(len) <= data.count else { return nil }
        let s = data.subdata(in: pos..<pos+Int(len))
        pos += Int(len)
        return s
    }

    mutating func readMpint() -> Data? {
        guard var bytes = readString() else { return nil }
        // Strip leading 0x00 that was added for sign
        if bytes.count > 0 && bytes[0] == 0 { bytes.removeFirst() }
        return bytes
    }
}

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
    for e in entries {
        guard let blob = pubBlob(for: e) else { continue }
        body.append(wireString(blob))
        body.append(wireString("s3c-gorilla-\(e.name) (\(e.mode))"))
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

// MARK: - Sign dispatch (mode + key type)

func sign(entry: KeyEntry, data: Data, flags: UInt32) -> Data? {
    if entry.mode == "se-born" {
        return signSEBorn(name: entry.name, data: data)
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
func parseECDSADer(_ der: Data) -> (Data, Data)? {
    var pos = 0
    guard der.count > 2, der[pos] == 0x30 else { return nil }
    pos += 1
    // Length may be 1 byte or 0x81||byte
    var seqLen: Int = 0
    if der[pos] & 0x80 == 0 {
        seqLen = Int(der[pos]); pos += 1
    } else {
        let n = Int(der[pos] & 0x7F); pos += 1
        for _ in 0..<n { seqLen = (seqLen << 8) | Int(der[pos]); pos += 1 }
    }
    _ = seqLen
    func readInt() -> Data? {
        guard pos < der.count, der[pos] == 0x02 else { return nil }
        pos += 1
        var len = Int(der[pos]); pos += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F; len = 0
            for _ in 0..<n { len = (len << 8) | Int(der[pos]); pos += 1 }
        }
        let v = der.subdata(in: pos..<pos+len)
        pos += len
        return v
    }
    guard let r = readInt(), let s = readInt() else { return nil }
    return (r, s)
}

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

// --- Tiny BigInt (byte-array, big-endian, unsigned) ---------------------

struct BigN: Comparable {
    var bytes: [UInt8]   // big-endian, always at least one byte, no leading zeros except for zero itself

    init(_ raw: [UInt8]) {
        var b = raw
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        if b.isEmpty { b = [0] }
        self.bytes = b
    }
    init(_ data: Data) { self.init(Array(data)) }
    init(_ v: UInt8) { self.init([v]) }

    static let zero = BigN([0])
    static let one = BigN([1])
    var isZero: Bool { bytes == [0] }
    var bitCount: Int {
        guard !isZero else { return 0 }
        var b = 8 * bytes.count
        var top = bytes[0]
        while top & 0x80 == 0 { b -= 1; top <<= 1 }
        return b
    }
    func bit(_ i: Int) -> UInt8 {
        let byteIdx = bytes.count - 1 - (i / 8)
        if byteIdx < 0 { return 0 }
        return (bytes[byteIdx] >> UInt8(i % 8)) & 1
    }

    static func == (a: BigN, b: BigN) -> Bool { a.bytes == b.bytes }
    static func < (a: BigN, b: BigN) -> Bool {
        if a.bytes.count != b.bytes.count { return a.bytes.count < b.bytes.count }
        for i in 0..<a.bytes.count {
            if a.bytes[i] != b.bytes[i] { return a.bytes[i] < b.bytes[i] }
        }
        return false
    }

    static func + (a: BigN, b: BigN) -> BigN {
        let la = a.bytes.count, lb = b.bytes.count
        let n = max(la, lb)
        var out = [UInt8](repeating: 0, count: n + 1)
        var carry = 0
        for i in 0..<n {
            let ai = i < la ? Int(a.bytes[la - 1 - i]) : 0
            let bi = i < lb ? Int(b.bytes[lb - 1 - i]) : 0
            let s = ai + bi + carry
            out[out.count - 1 - i] = UInt8(s & 0xFF)
            carry = s >> 8
        }
        out[0] = UInt8(carry)
        return BigN(out)
    }

    // Assumes a >= b.
    static func - (a: BigN, b: BigN) -> BigN {
        let la = a.bytes.count, lb = b.bytes.count
        var out = [UInt8](repeating: 0, count: la)
        var borrow = 0
        for i in 0..<la {
            let ai = Int(a.bytes[la - 1 - i])
            let bi = i < lb ? Int(b.bytes[lb - 1 - i]) : 0
            var d = ai - bi - borrow
            if d < 0 { d += 256; borrow = 1 } else { borrow = 0 }
            out[la - 1 - i] = UInt8(d)
        }
        return BigN(out)
    }

    static func * (a: BigN, b: BigN) -> BigN {
        let la = a.bytes.count, lb = b.bytes.count
        var scratch = [Int](repeating: 0, count: la + lb)
        for i in 0..<la {
            let ai = Int(a.bytes[la - 1 - i])
            for j in 0..<lb {
                let bj = Int(b.bytes[lb - 1 - j])
                scratch[i + j] += ai * bj
            }
        }
        // Propagate carries
        for i in 0..<(scratch.count - 1) {
            scratch[i + 1] += scratch[i] >> 8
            scratch[i] &= 0xFF
        }
        var out = [UInt8](repeating: 0, count: scratch.count)
        for i in 0..<scratch.count { out[out.count - 1 - i] = UInt8(scratch[i] & 0xFF) }
        return BigN(out)
    }

    // Bitwise left shift by one.
    func shl1() -> BigN {
        var out = [UInt8](repeating: 0, count: bytes.count + 1)
        var carry: UInt8 = 0
        for i in (0..<bytes.count).reversed() {
            let v = (UInt16(bytes[i]) << 1) | UInt16(carry)
            out[i + 1] = UInt8(v & 0xFF)
            carry = UInt8((v >> 8) & 1)
        }
        out[0] = carry
        return BigN(out)
    }

    // a mod m, via binary long division (slow but simple).
    func mod(_ m: BigN) -> BigN {
        precondition(!m.isZero, "mod by zero")
        var r = BigN.zero
        for i in (0..<(8 * self.bytes.count)).reversed() {
            r = r.shl1()
            if self.bit(i) == 1 {
                r = r + BigN.one
            }
            if r >= m {
                r = r - m
            }
        }
        return r
    }
}

// Modular exponentiation: base^exp mod m. Square-and-multiply, MSB first.
func modPow(_ base: BigN, _ exp: BigN, _ m: BigN) -> BigN {
    if m == BigN.one { return BigN.zero }
    var result = BigN.one
    let b = base.mod(m)
    let bits = exp.bitCount
    if bits == 0 { return BigN.one }
    for i in (0..<bits).reversed() {
        result = (result * result).mod(m)
        if exp.bit(i) == 1 {
            result = (result * b).mod(m)
        }
    }
    return result
}

// --- DER encoders ------------------------------------------------------

func derLength(_ n: Int) -> Data {
    if n < 0x80 { return Data([UInt8(n)]) }
    var v = n, raw = [UInt8]()
    while v > 0 { raw.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
    var out = Data([0x80 | UInt8(raw.count)])
    out.append(Data(raw))
    return out
}

func derInt(_ bytes: Data) -> Data {
    // Strip leading zeros, then prepend 0x00 if high bit is set.
    var b = Array(bytes)
    while b.count > 1 && b[0] == 0 { b.removeFirst() }
    if b.isEmpty { b = [0] }
    if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
    var out = Data([0x02])
    out.append(derLength(b.count))
    out.append(Data(b))
    return out
}

func derSequence(_ content: Data) -> Data {
    var out = Data([0x30])
    out.append(derLength(content.count))
    out.append(content)
    return out
}

// --- RSA OpenSSH-to-PKCS#1 bridge + sign -------------------------------

// Convert raw OpenSSH RSA private bytes into PKCS#1 DER suitable for SecKey.
// Heavy work lives here: one modular exponentiation (q^(p-2) mod p) — we pay
// it once at bootstrap time and cache the result inside the wrap blob.
func convertOpenSSHRSAToPKCS1(_ openSSHBlob: Data) -> Data? {
    guard let c = parseOpenSSHPrivate(openSSHBlob, expectedType: "ssh-rsa"),
          let nData = c["n"], let eData = c["e"], let dData = c["d"],
          let pData = c["p"], let qData = c["q"] else { return nil }
    let p = BigN(pData), q = BigN(qData), d = BigN(dData)
    let dp = d.mod(p - BigN.one)
    let dq = d.mod(q - BigN.one)
    let qinv = modPow(q, p - BigN([0x02]), p)        // Fermat: q^(p-2) mod p
    return derSequence(
        derInt(Data([0x00])) +   // version
        derInt(nData) +
        derInt(eData) +
        derInt(dData) +
        derInt(pData) +
        derInt(qData) +
        derInt(Data(dp.bytes)) +
        derInt(Data(dq.bytes)) +
        derInt(Data(qinv.bytes))
    )
}

func signRSA(pkcs1DER: Data, data: Data, flags: UInt32) -> Data? {
    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attrs as CFDictionary, &error) else {
        return nil
    }

    let algorithm: SecKeyAlgorithm
    let sigType: String
    if flags & SSH_AGENT_RSA_SHA2_512 != 0 {
        algorithm = .rsaSignatureMessagePKCS1v15SHA512
        sigType = "rsa-sha2-512"
    } else if flags & SSH_AGENT_RSA_SHA2_256 != 0 {
        algorithm = .rsaSignatureMessagePKCS1v15SHA256
        sigType = "rsa-sha2-256"
    } else {
        algorithm = .rsaSignatureMessagePKCS1v15SHA1
        sigType = "ssh-rsa"
    }

    guard let sig = SecKeyCreateSignature(key, algorithm, data as CFData, &error) as Data? else {
        return nil
    }
    var out = Data()
    out.append(wireString(sigType))
    out.append(wireString(sig))
    return out
}

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

func unwrapViaTouchID(name: String) -> Data? {
    // If /tmp/s3c-gorilla/<name>.blob doesn't exist, trigger bootstrap.
    let blobPath = "\(blobDir)/\(name).blob"
    if !FileManager.default.fileExists(atPath: blobPath) {
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
    proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/keepassxc-cli")
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
    return proc.terminationStatus == 0 && !data.isEmpty ? data : nil
}

// MARK: - Wire framing + dispatch

func framed(_ payload: Data) -> Data {
    var out = Data()
    var len = UInt32(payload.count).bigEndian
    out.append(Data(bytes: &len, count: 4))
    out.append(payload)
    return out
}

func handleMessage(_ msg: Data) -> Data {
    guard let type = msg.first else { return framed(Data([SSH_AGENT_FAILURE])) }
    let body = msg.count > 1 ? msg.subdata(in: 1..<msg.count) : Data()
    switch type {
    case SSH_AGENTC_REQUEST_IDENTITIES:
        return handleRequestIdentities()
    case SSH_AGENTC_SIGN_REQUEST:
        return handleSignRequest(body: body)
    default:
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
        fputs("bind() failed: \(String(cString: strerror(errno)))\n", stderr); exit(1)
    }
    chmod(socketPath, 0o600)
    guard listen(fd, 8) == 0 else {
        fputs("listen() failed: \(String(cString: strerror(errno)))\n", stderr); exit(1)
    }
    fputs("s3c-ssh-agent listening on \(socketPath)\n", stderr)

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
    // Wipe /tmp/s3c-gorilla/ on session end
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: touchidPath)
    proc.arguments = ["wrap-clear"]
    try? proc.run()
    proc.waitUntilExit()
    try? FileManager.default.removeItem(atPath: socketPath)
}

// Install SIGTERM / SIGINT handlers
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { cleanup(); exit(0) }
termSource.resume()
signal(SIGTERM, SIG_IGN)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { cleanup(); exit(0) }
intSource.resume()
signal(SIGINT, SIG_IGN)

// MARK: - Util

func zeroOut(_ d: inout Data) {
    let count = d.count
    d.withUnsafeMutableBytes { ptr in
        if let base = ptr.baseAddress {
            memset(base, 0, count)
        }
    }
    d.removeAll(keepingCapacity: false)
}

// MARK: - Main
// serve() is a tight accept-loop — must run off the main queue so dispatchMain()
// can process the DispatchSource signal handlers registered above.
DispatchQueue.global(qos: .userInitiated).async { serve() }
dispatchMain()
