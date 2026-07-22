// ssh-agent-sign — signing: dispatch by key mode + type, then Ed25519 / RSA / ECDSA-P256 /
// SE-born, plus the minimal OpenSSH private-key parser. Part of s3c-ssh-agent.

import Foundation
import Security
import CryptoKit
import Darwin

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
