// s3c-kdbx-parse.swift — productionized from tests/swift/test_xml_parser.swift (§2a / #X).
// Reads `keepassxc-cli export --format xml` on STDIN and emits one TAB line per ENV/2FA/SSH
// entry:  <kind>\t<title>\t<base64(payload)>   (kind = env|otp|ssh).
//   ENV/SSH payload = the attachment bytes; OTP payload = the otpauth:// URI.
// fan_out_all wraps these in ONE keepassxc unlock instead of N. Gzip-compressed attachments
// are SKIPPED here (no payload emitted) so the caller's per-secret loop handles them — keeps
// this tool simple and dependency-free (Foundation only, no gunzip). Never touches disk.

import Foundation

enum GroupKind { case ssh, env, otp, other }
struct VaultEntry { let group: GroupKind; let title: String; let payload: Data }

final class TwoPassParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var currentBinaryID: String?
    private var currentBinaryCompressed = false
    var binariesByID: [String: Data] = [:]
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

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        stack.append(name); text = ""
        if pass == 1 {
            if name == "Binary" && stack.contains("Binaries") {
                currentBinaryID = attrs["ID"]
                currentBinaryCompressed = (attrs["Compressed"]?.lowercased() == "true")
            }
        } else {
            if name == "Group" { pendingGroupName = "" }
            if name == "Entry" { inEntry = true; entryRows.removeAll(); currentKey = ""; currentValue = ""; currentRef = nil }
            if inEntry && (name == "String" || name == "Binary") { currentKey = ""; currentValue = ""; currentRef = nil }
            if inEntry, let r = attrs["Ref"] { currentRef = r }
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass == 1 {
            if name == "Binary" && stack.contains("Binaries"), let id = currentBinaryID {
                // Skip gzip-compressed blobs (no gunzip here) → the caller re-exports those per-secret.
                if !currentBinaryCompressed, let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                    binariesByID[id] = data
                }
                currentBinaryID = nil
            }
        } else {
            if name == "Name", stack.count >= 2, stack[stack.count - 2] == "Group", pendingGroupName == "" {
                pendingGroupName = trimmed
            }
            if inEntry {
                if name == "Key" { currentKey = trimmed }
                if name == "Value" { currentValue = trimmed }
                if name == "String" { entryRows.append((kind: "S", key: currentKey, valueOrRef: currentValue)) }
                if name == "Binary" { entryRows.append((kind: "B", key: currentKey, valueOrRef: currentRef ?? "")) }
            }
            if name == "Entry" {
                let groupName = groupNameStack.last ?? ""
                let kind: GroupKind = {
                    switch groupName { case "SSH": return .ssh; case "ENV": return .env; case "2FA": return .otp; default: return .other }
                }()
                var title = ""; var payload = Data()
                for row in entryRows {
                    if row.kind == "S" && row.key == "Title" { title = row.valueOrRef }
                    if kind == .otp && row.kind == "S" && row.key == "otp" { payload = row.valueOrRef.data(using: .utf8) ?? Data() }
                    if (kind == .ssh || kind == .env) && row.kind == "B" { if let b = binariesByID[row.valueOrRef] { payload = b } }
                }
                if kind != .other && !title.isEmpty { entries.append(VaultEntry(group: kind, title: title, payload: payload)) }
                inEntry = false; entryRows.removeAll()
            }
        }
        if pass == 2 && name == "Group" { if !groupNameStack.isEmpty { groupNameStack.removeLast() } }
        if pass == 2 && name == "Name", stack.count >= 2, stack[stack.count - 2] == "Group",
           let n = pendingGroupName, !n.isEmpty { groupNameStack.append(n); pendingGroupName = nil }
        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }
}

// --- main: stdin XML → TAB lines ---
let xml = FileHandle.standardInput.readDataToEndOfFile()
guard !xml.isEmpty else { exit(1) }
let parser = TwoPassParser()
parser.parse(pass: 1, data: xml)
parser.parse(pass: 2, data: xml)
for e in parser.entries where !e.payload.isEmpty {
    let kind: String
    switch e.group { case .ssh: kind = "ssh"; case .env: kind = "env"; case .otp: kind = "otp"; case .other: continue }
    print("\(kind)\t\(e.title)\t\(e.payload.base64EncodedString())")
}
