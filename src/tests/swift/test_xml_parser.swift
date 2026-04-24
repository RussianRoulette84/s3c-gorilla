#!/usr/bin/env swift
// test_xml_parser.swift — Concern #24 / §2a: keepassxc-cli XML export parser.
// PLAN.md spec: two-pass parse. Pass 1 harvests <Meta><Binaries>
// (base64 + optional gzip). Pass 2 walks entries; SSH/ENV use
// <Binary Ref="N"/> into the Pass-1 map; 2FA stores the full
// otpauth:// URI from <String><Key>otp</Key><Value>...</Value></String>.

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

enum GroupKind { case ssh, env, otp, other }
struct VaultEntry {
    let group: GroupKind
    let title: String
    let payload: Data   // SSH/ENV: attachment bytes; OTP: URI as UTF-8
}

// Two-pass XMLParser delegate with explicit element stack.
// Reference implementation for test-first; real parser lives in
// src/touchid-gorilla.swift's fan-out subcommand once Phase 1 lands.
final class TwoPassParser: NSObject, XMLParserDelegate {
    // shared
    private var stack: [String] = []
    private var text = ""

    // Pass 1
    private var currentBinaryID: String?
    private var currentBinaryCompressed = false
    var binariesByID: [String: Data] = [:]

    // Pass 2
    private var groupNameStack: [String] = []
    private var pendingGroupName: String?
    private var inEntry = false
    private var currentKey = ""
    private var currentValue = ""
    private var currentRef: String?
    private var entryRows: [(kind: String, key: String, valueOrRef: String)] = []
    var entries: [VaultEntry] = []

    private var pass = 1

    func parse(pass: Int, data: Data) {
        self.pass = pass
        stack.removeAll(); text = ""
        let p = XMLParser(data: data); p.delegate = self; p.parse()
    }

    func parser(_ p: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String] = [:]) {
        stack.append(name)
        text = ""
        if pass == 1 {
            if name == "Binary" && stack.contains("Binaries") {
                currentBinaryID = attrs["ID"]
                currentBinaryCompressed = (attrs["Compressed"]?.lowercased() == "true")
            }
        } else {
            if name == "Group" { pendingGroupName = "" }
            if name == "Entry" {
                inEntry = true; entryRows.removeAll()
                currentKey = ""; currentValue = ""; currentRef = nil
            }
            if inEntry && (name == "String" || name == "Binary") {
                currentKey = ""; currentValue = ""; currentRef = nil
            }
            // Ref is attached to <Value Ref="N"/> inside a <Binary>.
            if inEntry, let r = attrs["Ref"] { currentRef = r }
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if pass == 1 {
            if name == "Binary" && stack.contains("Binaries"), let id = currentBinaryID {
                if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                    // Real impl would gunzip when currentBinaryCompressed==true.
                    binariesByID[id] = data
                }
                currentBinaryID = nil
            }
        } else {
            // Group name (first <Name> child inside <Group>).
            if name == "Name",
               stack.count >= 2, stack[stack.count - 2] == "Group",
               pendingGroupName == "" {
                pendingGroupName = trimmed
            }
            if name == "Group" {
                // Entering group's scope ended → pop stack below.
            }
            if inEntry {
                if name == "Key" { currentKey = trimmed }
                if name == "Value" { currentValue = trimmed }
                if name == "String" {
                    entryRows.append((kind: "S", key: currentKey, valueOrRef: currentValue))
                }
                if name == "Binary" {
                    entryRows.append((kind: "B", key: currentKey,
                                      valueOrRef: currentRef ?? ""))
                }
            }
            if name == "Entry" {
                let groupName = groupNameStack.last ?? ""
                let kind: GroupKind = {
                    switch groupName {
                    case "SSH": return .ssh
                    case "ENV": return .env
                    case "2FA": return .otp
                    default: return .other
                    }
                }()
                var title = ""
                var payload = Data()
                for row in entryRows {
                    if row.kind == "S" && row.key == "Title" { title = row.valueOrRef }
                    if kind == .otp && row.kind == "S" && row.key == "otp" {
                        payload = row.valueOrRef.data(using: .utf8) ?? Data()
                    }
                    if (kind == .ssh || kind == .env) && row.kind == "B" {
                        if let b = binariesByID[row.valueOrRef] { payload = b }
                    }
                }
                if kind != .other && !title.isEmpty {
                    entries.append(VaultEntry(group: kind, title: title, payload: payload))
                }
                inEntry = false
                entryRows.removeAll()
            }
        }

        // Maintain group-name stack.
        if pass == 2 && name == "Group" {
            if !groupNameStack.isEmpty { groupNameStack.removeLast() }
        }
        // Push group name when we close its first <Name>.
        if pass == 2 && name == "Name",
           stack.count >= 2, stack[stack.count - 2] == "Group",
           let n = pendingGroupName, !n.isEmpty {
            groupNameStack.append(n)
            pendingGroupName = nil
        }

        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }
}

// ---- tests ----

let here = (#filePath as NSString).deletingLastPathComponent
let fixture = "\(here)/fixtures/synthetic_keepassxc.xml"
guard let xmlData = try? Data(contentsOf: URL(fileURLWithPath: fixture)) else {
    print("FAIL: cannot read \(fixture)"); exit(1)
}

let parser = TwoPassParser()
parser.parse(pass: 1, data: xmlData)
check(parser.binariesByID.count == 2, "Pass 1 harvested 2 binaries")
check(parser.binariesByID["0"] == "test-ssh-key-bytes".data(using: .utf8),
      "Binary ID=0 decoded")
check(parser.binariesByID["1"]?.starts(with: "API_KEY=".data(using: .utf8)!) == true,
      "Binary ID=1 decoded as .env bytes")

parser.parse(pass: 2, data: xmlData)
check(parser.entries.count == 3, "Pass 2 found 3 vault entries")

let ssh = parser.entries.first { $0.group == .ssh }
check(ssh?.title == "id_rsa", "SSH entry title = id_rsa")
check(ssh?.payload == "test-ssh-key-bytes".data(using: .utf8),
      "SSH payload resolved via Ref=0")

let env = parser.entries.first { $0.group == .env }
check(env?.title == "project_x", "ENV entry title = project_x")
check(env?.payload.starts(with: "API_KEY=".data(using: .utf8)!) == true,
      "ENV payload resolved via Ref=1")

let otp = parser.entries.first { $0.group == .otp }
check(otp?.title == "GitHub", "OTP entry title = GitHub")
let otpUri = String(data: otp?.payload ?? Data(), encoding: .utf8) ?? ""
check(otpUri.hasPrefix("otpauth://totp/"), "OTP payload is the full URI string")
check(otpUri.contains("digits=8"), "OTP URI preserves digits=8 (Concern #31)")

// Compressed binaries: Phase 0 verification + gunzip wiring.
skipTest("Compressed=\"True\" binaries", "Phase 0 + Foundation.Compression pending")

// Streaming budget: belongs in a separate file after fan-out lands.
skipTest("32 MiB streaming budget", "deferred to test_fanout_budget.swift")

finish()
