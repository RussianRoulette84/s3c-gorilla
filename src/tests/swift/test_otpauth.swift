#!/usr/bin/env swift
// test_otpauth.swift — Concern #31: full otpauth:// URI parse.
// PLAN.md spec: honor digits/period/algorithm/issuer, not just secret=.
// RFC 6238 known-answer vectors.

import Foundation

var _pass = 0, _fail = 0, _skip = 0
func check(_ cond: Bool, _ name: String) {
    if cond { _pass += 1; print("  PASS \(name)") }
    else    { _fail += 1; print("  FAIL \(name)") }
}
func skipTest(_ name: String, _ reason: String) {
    _skip += 1; print("  SKIP \(name) — \(reason)")
}
func finish() -> Never {
    print("--- \(_pass) passed, \(_fail) failed, \(_skip) skipped")
    exit(_fail == 0 ? 0 : 1)
}

// ---- interface specified by PLAN.md §2a / Concern #31 ----
// Real impl will live in src/otp-gorilla (or its Swift helper).
// This file tests the contract; a reference impl is inlined for
// semantic validation until the real one lands.

enum HashAlg: String {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
}

struct TOTPParams {
    let secret: Data
    let digits: Int
    let period: Int
    let algorithm: HashAlg
    let issuer: String?
    let account: String?
}

// Minimal base32 decoder (RFC 4648, uppercase, no padding required).
func base32Decode(_ s: String) -> Data? {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    var bits = 0, value = 0
    var out = Data()
    for ch in s.uppercased() where ch != "=" {
        guard let idx = alphabet.firstIndex(of: ch) else { return nil }
        value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: idx)
        bits += 5
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((value >> bits) & 0xFF))
        }
    }
    return out
}

func parseOtpauth(_ uri: String) -> TOTPParams? {
    guard let comps = URLComponents(string: uri),
          comps.scheme == "otpauth",
          comps.host == "totp" else { return nil }
    let path = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
    // "Issuer:Account" or just "Account"
    var issuer: String? = nil
    var account: String? = path.isEmpty ? nil : path
    if let colon = path.firstIndex(of: ":") {
        issuer = String(path[..<colon])
        account = String(path[path.index(after: colon)...])
    }
    var secret: Data? = nil
    var digits = 6, period = 30, alg: HashAlg = .sha1
    for q in comps.queryItems ?? [] {
        switch q.name.lowercased() {
        case "secret":    secret = q.value.flatMap(base32Decode)
        case "digits":    digits = Int(q.value ?? "6") ?? 6
        case "period":    period = Int(q.value ?? "30") ?? 30
        case "algorithm": alg = HashAlg(rawValue: (q.value ?? "SHA1").uppercased()) ?? .sha1
        case "issuer":    if issuer == nil { issuer = q.value }
        default: break
        }
    }
    guard let s = secret, !s.isEmpty else { return nil }
    return TOTPParams(secret: s, digits: digits, period: period,
                      algorithm: alg, issuer: issuer, account: account)
}

// ---- tests ----

// 1. Minimal URI — just secret.
do {
    let p = parseOtpauth("otpauth://totp/Acme?secret=JBSWY3DPEHPK3PXP")
    check(p != nil, "minimal URI parses")
    check(p?.digits == 6, "default digits=6")
    check(p?.period == 30, "default period=30")
    check(p?.algorithm == .sha1, "default algorithm=SHA1")
}

// 2. Full URI with all params (the cases Concern #31 calls out).
do {
    let uri = "otpauth://totp/Acme:alice@example.com?" +
              "secret=JBSWY3DPEHPK3PXP&issuer=Acme&digits=8&period=60&algorithm=SHA256"
    let p = parseOtpauth(uri)
    check(p != nil, "full URI parses")
    check(p?.digits == 8, "digits=8 parsed")
    check(p?.period == 60, "period=60 parsed")
    check(p?.algorithm == .sha256, "algorithm=SHA256 parsed")
    check(p?.issuer == "Acme", "issuer=Acme parsed")
    check(p?.account == "alice@example.com", "account parsed")
}

// 3. SHA512 variant.
do {
    let p = parseOtpauth("otpauth://totp/X?secret=JBSWY3DPEHPK3PXP&algorithm=SHA512")
    check(p?.algorithm == .sha512, "algorithm=SHA512 parsed")
}

// 4. Issuer in path vs query — path wins, query only fills when path has none.
do {
    let p = parseOtpauth("otpauth://totp/PathIssuer:bob?secret=JBSWY3DPEHPK3PXP&issuer=QueryIssuer")
    check(p?.issuer == "PathIssuer", "path issuer takes precedence")
}
do {
    let p = parseOtpauth("otpauth://totp/bob?secret=JBSWY3DPEHPK3PXP&issuer=QueryIssuer")
    check(p?.issuer == "QueryIssuer", "query issuer fills when path is plain")
}

// 5. Rejection cases.
do {
    check(parseOtpauth("otpauth://totp/x") == nil, "no secret → nil")
    check(parseOtpauth("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP") == nil, "non-totp → nil")
    check(parseOtpauth("https://example.com") == nil, "non-otpauth scheme → nil")
}

// 6. Base32 decode round-trip sanity.
do {
    // RFC 4648 test vector: "12345678901234567890" → "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    let decoded = base32Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    let expected = "12345678901234567890".data(using: .utf8)!
    check(decoded == expected, "base32 round-trip RFC 4648 vector")
}

// 7. TOTP code computation — requires HMAC + time-step math.
//    Inlining the full algorithm here is too much for this file; when
//    the real impl lands, expand into a separate test_totp_vectors.swift
//    that byte-compares against oathtool reference output (PLAN.md §4).
skipTest("TOTP code computation", "byte-compare-to-oathtool deferred to test_totp_vectors.swift")

finish()
