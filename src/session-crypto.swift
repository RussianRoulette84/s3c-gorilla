// session-crypto — how the master password is held and how the tools reach us: the
// obfuscated mlock'd SecretBox, process hardening, and the unix-socket plumbing both the
// agent and its client half use. Part of s3c-session-agent.

import Foundation
import CryptoKit
import Darwin

// MARK: - Obfuscated, mlock'd secret store

// Holds the master password as a CryptoKit AES-GCM sealed box. BE HONEST ABOUT WHAT THIS
// BUYS: the key and the sealed bytes both live in this same process's (mlock'd) memory, so
// an attacker who can read our address space (debugger, same-uid + task_for_pid) gets both
// and trivially recovers the password — this is NOT encryption-at-rest-in-RAM. What it
// actually defends: the password never sits as plaintext in a core dump, a `strings` of the
// heap, or swap (RLIMIT_CORE=0 + mlock), and the AEAD tag catches accidental corruption.
// Defense-in-depth and tidiness, not a cryptographic boundary against a privileged peer. (H5)
final class SecretBox {
    private var keyPtr: UnsafeMutableRawPointer
    private var sealedPtr: UnsafeMutableRawPointer
    private let keyLen = 32
    private let sealedLen: Int

    init?(_ pw: [UInt8]) {
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(Data(pw), using: key),
              let combined = sealed.combined else { return nil }
        sealedLen = combined.count
        keyPtr = UnsafeMutableRawPointer.allocate(byteCount: keyLen, alignment: 1)
        sealedPtr = UnsafeMutableRawPointer.allocate(byteCount: max(sealedLen, 1), alignment: 1)
        if mlock(keyPtr, keyLen) != 0 { dlog("mlock(key) failed: \(String(cString: strerror(errno)))") }
        if mlock(sealedPtr, max(sealedLen, 1)) != 0 { dlog("mlock(sealed) failed: \(String(cString: strerror(errno)))") }
        key.withUnsafeBytes { raw in keyPtr.copyMemory(from: raw.baseAddress!, byteCount: keyLen) }
        combined.withUnsafeBytes { raw in sealedPtr.copyMemory(from: raw.baseAddress!, byteCount: sealedLen) }
    }

    // Reveal into a fresh buffer; caller must zero it after use. nil on tamper/failure.
    func reveal() -> [UInt8]? {
        let key = SymmetricKey(data: Data(bytes: keyPtr, count: keyLen))
        let combined = Data(bytes: sealedPtr, count: sealedLen)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return [UInt8](plain)
    }

    func wipe() {
        memset(keyPtr, 0, keyLen)
        memset(sealedPtr, 0, max(sealedLen, 1))
        munlock(keyPtr, keyLen); munlock(sealedPtr, max(sealedLen, 1))
        keyPtr.deallocate(); sealedPtr.deallocate()
    }
}

// MARK: - Hardening

func hardenProcess() {
    var rl = rlimit(rlim_cur: 0, rlim_max: 0)   // no core dumps — never leak memory on crash
    setrlimit(RLIMIT_CORE, &rl)
}

// MARK: - Low-level unix socket

func makeSockaddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { bp in
            for (i, b) in bytes.enumerated() where i < 104 { bp[i] = b }
        }
    }
    return addr
}

func selfPath() -> String {
    // Robust: ask dyld for our own absolute path (B9).
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    if size > 0 {
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 { return String(cString: buf) }
    }
    let a0 = CommandLine.arguments[0]
    return a0.hasPrefix("/") ? a0 : "/usr/local/bin/s3c-session-agent"
}

// MARK: - Client (get / stop)

// Send a newline-terminated request ("G", "Q", "E <entry>", "O <entry>") and read
// the full response. nil if no live agent answers.
func clientSend(tty: String, _ request: String) -> [UInt8]? {
    let path = socketPath(forTTY: tty)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = makeSockaddr(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { return nil }
    let line = Array((request + "\n").utf8)
    guard write(fd, line, line.count) == line.count else { return nil }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}
