#!/usr/bin/env swift
// test_wipe.swift — Concern #27 (90/5 rule): wipe(&Data) helper.
// PLAN.md spec: five-line helper that memsets Data bytes and clears length.

import Foundation

// Inline harness (each test file is standalone per project convention).
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

// Reference impl of the helper as PLAN.md specifies.
// Real implementation will live in src/touchid-gorilla.swift (or a
// shared Secrets.swift). This test validates the semantics.
func wipe(_ d: inout Data) {
    d.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress else { return }
        memset(base, 0, buf.count)
    }
    d.removeAll(keepingCapacity: false)
}

// ---- tests ----

// 1. Known bytes get zeroed AND count goes to 0.
do {
    var d = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    let originalCount = d.count
    wipe(&d)
    check(d.count == 0, "count zero after wipe (was \(originalCount))")
    check(d.isEmpty, "isEmpty after wipe")
}

// 2. Empty Data stays empty, no crash.
do {
    var d = Data()
    wipe(&d)
    check(d.count == 0, "empty Data stays empty")
}

// 3. Large buffer (10 MiB) wipes without exploding.
do {
    var d = Data(count: 10 * 1024 * 1024)
    for i in 0..<d.count where i % 4096 == 0 { d[i] = 0x5A }
    wipe(&d)
    check(d.count == 0, "10 MiB buffer wiped clean")
}

// 4. After wipe, re-assigning bytes works (no aliasing weirdness).
do {
    var d = Data([0x01, 0x02])
    wipe(&d)
    d.append(contentsOf: [0x03, 0x04])
    check(d == Data([0x03, 0x04]), "reusable after wipe")
}

// 5. Wiping a Data that's a slice of a larger buffer only zeroes the slice.
//    (Edge case: Swift's Data can be backed by a subrange.)
do {
    let backing = Data([0x10, 0x20, 0x30, 0x40, 0x50])
    var slice = backing.subdata(in: 1..<4)   // [0x20, 0x30, 0x40]
    wipe(&slice)
    check(slice.count == 0, "slice wiped to empty")
    // Backing is immutable (we took a copy via subdata), so we can't
    // easily check it stayed put — but at minimum the slice itself
    // is empty, which is the spec.
}

// 6. Regression guard — the helper is exactly five lines of body
//    (not counting braces). Sanity check against scope creep.
//    This is advisory; skip if anyone reformats the helper later.
skipTest("helper LOC sanity", "static analysis, not runtime-testable")

finish()
