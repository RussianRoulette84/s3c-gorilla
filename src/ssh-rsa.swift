// ssh-rsa.swift — shared RSA signing for BOTH agents (#RSA).
//
// Moved here verbatim from s3c-ssh-agent.swift so the password-mode agent
// (s3c-session-agent, via ssh-agent-core.swift) can sign RSA keys too, not just
// the chip agent. One copy of the OpenSSH→PKCS#1 bridge + the tiny BigInt → no drift.
//
// Each binary supplies its own `parseOpenSSHPrivate` (with the ssh-rsa case) and the
// wire helpers from ssh-wire.swift; this file resolves to whichever is linked in.

import Foundation
import Security

// SSH_AGENTC_SIGN_REQUEST flag bits selecting the RSA hash (rsa-sha2-*).
let SSH_AGENT_RSA_SHA2_256: UInt32 = 2
let SSH_AGENT_RSA_SHA2_512: UInt32 = 4

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
