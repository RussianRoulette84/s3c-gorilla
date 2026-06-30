// ssh-agent-core.swift — password-mode ssh-agent protocol (Ed25519 + ECDSA-P256 + RSA).
//
// Compiled INTO s3c-session-agent so the per-tty agent can serve SSH in password
// mode using the master password it already holds. RSA signing lives in the shared
// ssh-rsa.swift (#RSA), compiled into both agents. The crypto/protocol below is lifted
// verbatim from s3c-ssh-agent.swift (the SE-only paths omitted).
//
// The host agent provides: homeDir, dlog, makeSockaddr, peerIsSameUID, and sets the
// `sshKeyBytes` hook (extract a key's OpenSSH private bytes from the kdbx by name).

import Foundation
import Security
import CryptoKit
import Darwin

// MARK: - Registry + paths
let coreAgentDir = "\(homeDir)/.s3c-gorilla"
let registryPath = "\(coreAgentDir)/keys.json"
let pubDir = "\(coreAgentDir)/pubkeys"

struct KeyEntry: Codable {
    let name: String
    let mode: String
    let keyType: String
}

func loadRegistry() -> [KeyEntry] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)) else { return [] }
    return (try? JSONDecoder().decode([KeyEntry].self, from: data)) ?? []
}

// MARK: - ssh-agent protocol constants
let SSH_AGENTC_REQUEST_IDENTITIES: UInt8 = 11
let SSH_AGENTC_SIGN_REQUEST: UInt8 = 13
let SSH_AGENT_FAILURE: UInt8 = 5
let SSH_AGENT_IDENTITIES_ANSWER: UInt8 = 12
let SSH_AGENT_SIGN_RESPONSE: UInt8 = 14

// Host hook: extract the key's OpenSSH private bytes from the kdbx (by key name).
var sshKeyBytes: (String) -> Data? = { _ in nil }
// Host hook: called on every ssh-agent request so the session TTL tracks ssh activity, not
// just env/otp (HR #7). The session-agent wires this to touchActivity().
var onActivity: () -> Void = {}

// SSH wire helpers (wireString / wireMpint / Reader / zeroOut / framed / parseECDSADer)
// now live once in ssh-wire.swift (#13), compiled alongside this file.

// MARK: - Public key blob (from ~/.s3c-gorilla/pubkeys/<name>.pub)
func pubBlob(for entry: KeyEntry) -> Data? {
    let path = "\(pubDir)/\(entry.name).pub"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let parts = content.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }
    return Data(base64Encoded: String(parts[1]))
}

// MARK: - Protocol handlers
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

func handleSignRequest(body: Data) -> Data {
    var r = Reader(data: body)
    guard let keyBlob = r.readString(),
          let signData = r.readString(),
          let flags = r.readUInt32() else { return framed(Data([SSH_AGENT_FAILURE])) }
    let entries = loadRegistry()
    var matched: KeyEntry? = nil
    for e in entries where pubBlob(for: e) == keyBlob { matched = e; break }
    guard let entry = matched, let sig = sign(entry: entry, data: signData, flags: flags) else {
        return framed(Data([SSH_AGENT_FAILURE]))
    }
    var out = Data()
    out.append(SSH_AGENT_SIGN_RESPONSE)
    out.append(wireString(sig))
    return framed(out)
}

// Password-mode signing: extract the key (host hook) then sign. RSA → nil (fallthrough).
func sign(entry: KeyEntry, data: Data, flags: UInt32) -> Data? {
    guard var keyBytes = sshKeyBytes(entry.name) else { return nil }
    defer { zeroOut(&keyBytes) }
    switch entry.keyType {
    case "ssh-ed25519":          return signEd25519(openSSHBlob: keyBytes, data: data)
    case "ecdsa-sha2-nistp256":  return signECDSAP256(openSSHBlob: keyBytes, data: data)
    case "ssh-rsa":                                              // #RSA — shared with chip agent
        guard let pkcs1 = convertOpenSSHRSAToPKCS1(keyBytes) else { return nil }
        return signRSA(pkcs1DER: pkcs1, data: data, flags: flags)
    default:
        dlog("unsupported key type in password mode: \(entry.keyType) (\(entry.name))")
        return nil
    }
}

func handleMessage(_ msg: Data) -> Data {
    guard let type = msg.first else { return framed(Data([SSH_AGENT_FAILURE])) }
    let body = msg.count > 1 ? msg.subdata(in: 1..<msg.count) : Data()
    switch type {
    case SSH_AGENTC_REQUEST_IDENTITIES: onActivity(); return handleRequestIdentities()
    case SSH_AGENTC_SIGN_REQUEST:       onActivity(); return handleSignRequest(body: body)
    default:                            return framed(Data([SSH_AGENT_FAILURE]))
    }
}

// MARK: - Signers
func signEd25519(openSSHBlob: Data, data: Data) -> Data? {
    guard let comps = parseOpenSSHPrivate(openSSHBlob, expectedType: "ssh-ed25519") else { return nil }
    guard let priv = comps["priv"], priv.count >= 32 else { return nil }
    let seed = priv.subdata(in: 0..<32)
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
          let sig = try? key.signature(for: data) else { return nil }
    var out = Data()
    out.append(wireString("ssh-ed25519"))
    out.append(wireString(sig))
    return out
}

func signECDSAP256(openSSHBlob: Data, data: Data) -> Data? {
    guard let comps = parseOpenSSHPrivate(openSSHBlob, expectedType: "ecdsa-sha2-nistp256") else { return nil }
    guard let pub = comps["pub"], let priv = comps["priv"] else { return nil }
    var raw = Data(); raw.append(pub); raw.append(priv)   // 0x04||X||Y || D
    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits as String: 256
    ]
    var error: Unmanaged<CFError>?
    guard let secKey = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, &error),
          let der = SecKeyCreateSignature(secKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data?,
          let (r, s) = parseECDSADer(der) else { return nil }
    var inner = Data(); inner.append(wireMpint(r)); inner.append(wireMpint(s))
    var out = Data()
    out.append(wireString("ecdsa-sha2-nistp256"))
    out.append(wireString(inner))
    return out
}

// Minimal OpenSSH private-key parser — Ed25519 + ECDSA P-256 only.
func parseOpenSSHPrivate(_ blob: Data, expectedType: String) -> [String: Data]? {
    var body = blob
    if let s = String(data: blob, encoding: .utf8), s.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
        let stripped = s
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let decoded = Data(base64Encoded: stripped) else { return nil }
        body = decoded
    }
    let magic = Array("openssh-key-v1\0".utf8)
    guard body.count > magic.count, Array(body.prefix(magic.count)) == magic else { return nil }
    var r = Reader(data: body); r.pos = magic.count
    guard let ciphername = r.readString(),
          String(data: ciphername, encoding: .utf8) == "none",
          let _ = r.readString(), let _ = r.readString(),
          let nkeys = r.readUInt32(), nkeys == 1,
          let _ = r.readString(),
          let privSection = r.readString() else { return nil }
    var pr = Reader(data: privSection)
    guard let check1 = pr.readUInt32(), let check2 = pr.readUInt32(), check1 == check2,
          let keyType = pr.readString(),
          let ktStr = String(data: keyType, encoding: .utf8), ktStr == expectedType else { return nil }
    var out: [String: Data] = ["type": keyType]
    switch expectedType {
    case "ssh-ed25519":
        guard let pub = pr.readString(), let priv = pr.readString() else { return nil }
        out["pub"] = pub; out["priv"] = priv
    case "ecdsa-sha2-nistp256":
        guard let _ = pr.readString(), let pub = pr.readString(), let d = pr.readMpint() else { return nil }
        out["pub"] = pub
        var scalar = Data(d)
        while scalar.count < 32 { scalar.insert(0, at: 0) }
        if scalar.count > 32 { scalar = scalar.subdata(in: (scalar.count-32)..<scalar.count) }
        out["priv"] = scalar
    case "ssh-rsa":                                              // #RSA — n,e,d,iqmp,p,q
        guard let n = pr.readMpint(), let e = pr.readMpint(), let d = pr.readMpint(),
              let iqmp = pr.readMpint(), let p = pr.readMpint(), let q = pr.readMpint() else { return nil }
        out["n"] = n; out["e"] = e; out["d"] = d; out["iqmp"] = iqmp; out["p"] = p; out["q"] = q
    default:
        return nil
    }
    return out
}

// MARK: - Accept loop (per-tty ssh socket). Uses the host's makeSockaddr + peerIsSameUID.
func handleConnection(_ cfd: Int32) {
    guard peerIsSameUID(cfd) else { dlog("ssh peer-cred reject"); return }
    while true {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let n = read(cfd, &lenBuf, 4)
        if n < 4 { return }
        let msgLen = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) |
                     (UInt32(lenBuf[2]) << 8)  | UInt32(lenBuf[3])
        if msgLen == 0 || msgLen > 1_048_576 { return }
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

func runSSHAgentLoop(sockPath: String) {
    try? FileManager.default.createDirectory(atPath: pubDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.removeItem(atPath: sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { dlog("ssh socket() failed"); return }
    var addr = makeSockaddr(sockPath)
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
    }
    // EADDRINUSE here means another LIVE agent for this tty already owns the SSH socket — do
    // NOT steal it (it may be the one holding the master pw). Just don't serve ssh from this
    // duplicate. Genuinely-stale files were already removed by the unlink above.
    guard bound == 0 else { dlog("ssh bind skipped (\(sockPath)): \(String(cString: strerror(errno)))"); return }
    chmod(sockPath, 0o600)
    guard listen(fd, 8) == 0 else { dlog("ssh listen failed: \(String(cString: strerror(errno)))"); return }
    // Bind + listen are done SYNCHRONOUSLY (above) before this returns, so the SSH socket is
    // live the instant the caller (serve) lets the control socket start answering `get`. Only
    // the accept loop runs in the background — that's what kills the startup race where `ssh`
    // raced ahead and found no socket.
    DispatchQueue.global().async {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            DispatchQueue.global().async { handleConnection(cfd); close(cfd) }
        }
    }
}
