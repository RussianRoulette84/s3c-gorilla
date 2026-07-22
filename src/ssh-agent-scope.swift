// ssh-agent-scope — the warm-key cache that stops the per-signature Touch ID spam: how long a
// key stays unlocked (once / this app / until vault close / timer). Part of s3c-ssh-agent.

import Foundation
import Darwin

// MARK: - Unlock scope cache (stop the per-sign Touch-ID spam)
//
// Chip-wrap normally fires Touch ID on EVERY signature (a deploy = dozens of taps). Here we keep
// the unwrapped key warm in mlock-style zeroable memory for a user-chosen scope, so a burst of
// signs costs one tap. Mirrors the gPushed cache's zero-on-clear discipline. Wiped on screen-lock,
// logout, sleep/lid, and reboot (cleanup()). Default scope `session`; `once` = today's behavior.

struct CachedKey {
    var bytes: [UInt8]           // zeroable payload (OpenSSH blob or RSA PKCS#1 DER)
    let scope: String            // "app" | "session"  (never "once")
    let ownerPID: pid_t          // app scope: the owning app; else 0
    let expiry: Date             // TTL cap (min(scope, timer))
    mutating func zero() { for i in bytes.indices { bytes[i] = 0 } }
}
var gSSHCache: [String: CachedKey] = [:]        // keyName -> warm key
let sshCacheQueue = DispatchQueue(label: "s3c-gorilla.sshcache")

// Session-wide choices set by the unlock window (empty/nil → fall back to config).
var gSessionScope = ""
var gAskPwOverride: Bool? = nil
var gTTLMinutes = 0

func sshCacheClear() { sshCacheQueue.sync { for k in gSSHCache.keys { gSSHCache[k]?.zero() }; gSSHCache.removeAll() } }

// Generic config string: env wins, then ~/.config/s3c-gorilla/config, else `def`.
func stringConfig(_ key: String, default def: String) -> String {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
    let cfg = "\(homeDir)/.config/s3c-gorilla/config"
    if let text = try? String(contentsOfFile: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key)=") {
                return String(t.dropFirst(key.count + 1)).replacingOccurrences(of: "\"", with: "")
            }
        }
    }
    return def
}
func effectiveScope() -> String {
    if ["once", "app", "session"].contains(gSessionScope) { return gSessionScope }
    let c = stringConfig("GORILLA_SSH_UNLOCK_SCOPE", default: "session")
    return ["once", "app", "session"].contains(c) ? c : "session"
}
func askPwEachTime() -> Bool { gAskPwOverride ?? boolConfig("GORILLA_SSH_ASK_PW_EACH_TIME", default: false) }
func pidAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

// Walk from the connecting `ssh` process (a throwaway PID) up to the app macOS launched — the
// first ancestor whose parent is launchd (pid 1). For Xcode/SourceTree that's the app; for a
// terminal deploy it's the terminal window. That PID tags an `app`-scope cache entry.
func ppidOf(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    if sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 { return info.kp_eproc.e_ppid }
    return nil
}
func resolveOwningApp(_ pid: pid_t) -> pid_t {
    var cur = pid
    for _ in 0..<32 {
        guard let pp = ppidOf(cur), pp > 1 else { break }
        cur = pp
    }
    return cur
}

// Drop dead-owner app entries + anything past its TTL. Caller holds sshCacheQueue.
func sshReapLocked() {
    let now = Date()
    for (k, c) in gSSHCache where c.expiry < now || (c.scope == "app" && !pidAlive(c.ownerPID)) {
        gSSHCache[k]?.zero(); gSSHCache[k] = nil
    }
}

// The warm-key gate for chip-wrap. Returns the key bytes, unwrapping (one Touch ID) only on a
// miss. Held under the serial queue so a burst of concurrent signs waits on one prompt, then all
// reuse the cache — never two prompts for one unlock.
func chipKeyBytes(entry: KeyEntry, scope: String, peer: pid_t) -> Data? {
    return sshCacheQueue.sync {
        sshReapLocked()
        let paranoid = askPwEachTime()
        if scope != "once" && !paranoid, let c = gSSHCache[entry.name] {
            let ownerOK = c.scope != "app" || (pidAlive(c.ownerPID) && resolveOwningApp(peer) == c.ownerPID)
            if c.expiry > Date() && ownerOK { return Data(c.bytes) }
        }
        // Miss. Paranoid mode forces the password window (drop the blob so unwrap re-bootstraps);
        // otherwise a Touch-ID unwrap of the existing blob.
        if paranoid { try? FileManager.default.removeItem(atPath: "\(blobDir)/ssh-\(entry.name).blob") }
        guard var kb = unwrapViaTouchID(name: "ssh-\(entry.name)", peer: peer) else { return nil }
        let bytes = Array(kb); zeroOut(&kb)
        // The unlock window (shown during a cold bootstrap) may have just set the scope/TTL —
        // re-read them so the store honors the user's actual pick, not the pre-unlock default.
        let storeScope = effectiveScope()
        if storeScope != "once" && !askPwEachTime() {
            let owner = storeScope == "app" ? resolveOwningApp(peer) : 0
            let exp = gTTLMinutes > 0 ? Date().addingTimeInterval(Double(gTTLMinutes) * 60) : Date.distantFuture
            gSSHCache[entry.name]?.zero()
            gSSHCache[entry.name] = CachedKey(bytes: bytes, scope: storeScope, ownerPID: owner, expiry: exp)
        }
        return Data(bytes)
    }
}
