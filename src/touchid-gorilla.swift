import Foundation
import LocalAuthentication
import Security
import CryptoKit

// ECIES algorithm used for every encrypt/decrypt in this binary.
let algo: SecKeyAlgorithm = .eciesEncryptionCofactorX963SHA256AESGCM

// ---------------------------------------------------------------------------
// Shared wrap key — one biometry-gated SE key encrypts every /tmp blob.
// Compartmentalization comes from per-Touch-ID enforcement (each decrypt
// needs a fresh tap), not per-name key tags.
// ---------------------------------------------------------------------------
let wrapKeyTag = "s3c-gorilla.wrap.privkey".data(using: .utf8)!
let blobDir = "/tmp/s3c-gorilla"

func blobPath(for name: String) -> String { "\(blobDir)/\(name).blob" }


// MARK: - SE key helpers (parameterized by tag)

func createSEKey(tag: Data) -> SecKey? {
    guard let acl = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet],
        nil
    ) else { return nil }

    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessControl as String: acl
        ]
    ]
    var error: Unmanaged<CFError>?
    guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
        let msg = error?.takeRetainedValue().localizedDescription ?? "unknown"
        fputs("Failed to create Secure Enclave key: \(msg)\n", stderr)
        return nil
    }
    return k
}

func loadSEKey(tag: Data) -> SecKey? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrApplicationTag as String: tag,
        kSecReturnRef as String: true
    ]
    var ref: AnyObject?
    return SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess ? (ref as! SecKey) : nil
}

func loadOrCreateSEKey(tag: Data) -> SecKey? {
    loadSEKey(tag: tag) ?? createSEKey(tag: tag)
}

func deleteSEKey(tag: Data) {
    let q: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrApplicationTag as String: tag
    ]
    SecItemDelete(q as CFDictionary)
}

// MARK: - Blob file ops

func ensureBlobDir() -> Bool {
    do {
        try FileManager.default.createDirectory(
            atPath: blobDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return true
    } catch {
        fputs("Failed to create \(blobDir): \(error.localizedDescription)\n", stderr)
        return false
    }
}

func writeBlob(_ data: Data, to path: String) -> Bool {
    let dir = (path as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    } catch {
        fputs("Failed to create \(dir): \(error.localizedDescription)\n", stderr)
        return false
    }
    let tmp = path + ".tmp"
    guard FileManager.default.createFile(
        atPath: tmp, contents: data,
        attributes: [.posixPermissions: 0o600]) else {
        fputs("Failed to write \(tmp)\n", stderr)
        return false
    }
    guard rename(tmp, path) == 0 else {
        fputs("rename failed: \(String(cString: strerror(errno)))\n", stderr)
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
    return true
}

func readBlob(_ path: String) -> Data? {
    try? Data(contentsOf: URL(fileURLWithPath: path))
}

// MARK: - Generic wrap / unwrap (/tmp/s3c-gorilla/<name>.blob)

func wrap(name: String, data: Data) -> Bool {
    guard ensureBlobDir() else { return false }
    guard let priv = loadOrCreateSEKey(tag: wrapKeyTag) else { return false }
    guard let pub = SecKeyCopyPublicKey(priv) else {
        fputs("Failed to derive wrap public key\n", stderr); return false
    }
    var error: Unmanaged<CFError>?
    guard let cipher = SecKeyCreateEncryptedData(pub, algo, data as CFData, &error) else {
        let msg = error?.takeRetainedValue().localizedDescription ?? "unknown"
        fputs("Encrypt failed: \(msg)\n", stderr); return false
    }
    return writeBlob(cipher as Data, to: blobPath(for: name))
}

func unwrap(name: String) -> Data? {
    let path = blobPath(for: name)
    guard let cipher = readBlob(path) else {
        fputs("No blob at \(path)\n", stderr); return nil
    }
    guard let priv = loadSEKey(tag: wrapKeyTag) else {
        fputs("No wrap SE key found (nothing was ever wrapped on this Mac)\n", stderr)
        return nil
    }
    var error: Unmanaged<CFError>?
    guard let plain = SecKeyCreateDecryptedData(priv, algo, cipher as CFData, &error) else {
        let err = error?.takeRetainedValue()
        let code = err.map { CFErrorGetCode($0) } ?? 0
        if code == -128 || code == Int(errSecUserCanceled) { return nil }
        fputs("Decrypt failed: \(err?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }
    return plain as Data
}

func wrapList() {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: blobDir) else {
        return
    }
    for e in entries.sorted() where e.hasSuffix(".blob") {
        print(String(e.dropLast(".blob".count)))
    }
}

func wrapClear(name: String?) {
    if let n = name {
        try? FileManager.default.removeItem(atPath: blobPath(for: n))
    } else {
        try? FileManager.default.removeItem(atPath: blobDir)
    }
}


// MARK: - SE-born SSH key (Mode 2)

let sshKeyTagPrefix = "s3c-gorilla.ssh."
func sshKeyTag(for name: String) -> Data {
    (sshKeyTagPrefix + name).data(using: .utf8)!
}

func sshGenerate(name: String) -> Bool {
    let tag = sshKeyTag(for: name)
    if loadSEKey(tag: tag) != nil {
        fputs("SSH SE key '\(name)' already exists — delete it first with: touchid-gorilla ssh-delete \(name)\n", stderr)
        return false
    }
    guard createSEKey(tag: tag) != nil else { return false }
    return true
}

func sshDelete(name: String) {
    deleteSEKey(tag: sshKeyTag(for: name))
}

func sshPub(name: String) -> String? {
    let tag = sshKeyTag(for: name)
    guard let priv = loadSEKey(tag: tag),
          let pub = SecKeyCopyPublicKey(priv) else {
        fputs("No SE SSH key named '\(name)'\n", stderr); return nil
    }
    var error: Unmanaged<CFError>?
    guard let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
        fputs("Export failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")\n", stderr)
        return nil
    }
    // OpenSSH wire format for ecdsa-sha2-nistp256:
    //   string "ecdsa-sha2-nistp256" | string "nistp256" | string <raw ANSI X9.63 pubkey (0x04||X||Y)>
    var wire = Data()
    wire.appendSSHString("ecdsa-sha2-nistp256")
    wire.appendSSHString("nistp256")
    wire.appendSSHBlob(raw)
    return "ecdsa-sha2-nistp256 \(wire.base64EncodedString()) s3c-gorilla-\(name)"
}

extension Data {
    mutating func appendSSHString(_ s: String) { appendSSHBlob(Data(s.utf8)) }
    mutating func appendSSHBlob(_ blob: Data) {
        var len = UInt32(blob.count).bigEndian
        append(Data(bytes: &len, count: 4))
        append(blob)
    }
}

// MARK: - TOTP (RFC 6238, SHA-1, 6 digits, 30s step)

func base32Decode(_ s: String) -> Data? {
    // RFC 4648 base32 (KeePassXC default)
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    let clean = s.uppercased().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: " ", with: "")
    var bits: UInt64 = 0, bitCount = 0
    var out = Data()
    for ch in clean {
        guard let idx = alphabet.firstIndex(of: ch) else { return nil }
        let v = alphabet.distance(from: alphabet.startIndex, to: idx)
        bits = (bits << 5) | UInt64(v)
        bitCount += 5
        if bitCount >= 8 {
            bitCount -= 8
            out.append(UInt8((bits >> UInt64(bitCount)) & 0xFF))
        }
    }
    return out
}

func computeTOTP(secret: Data, unixTime: TimeInterval = Date().timeIntervalSince1970,
                 step: TimeInterval = 30, digits: Int = 6) -> String {
    let counter = UInt64(unixTime / step)
    var be = counter.bigEndian
    let counterBytes = Data(bytes: &be, count: 8)
    let key = SymmetricKey(data: secret)
    let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterBytes, using: key))
    let offset = Int(mac[19] & 0x0F)
    let b0 = UInt32(mac[offset] & 0x7F) << 24
    let b1 = UInt32(mac[offset + 1]) << 16
    let b2 = UInt32(mac[offset + 2]) << 8
    let b3 = UInt32(mac[offset + 3])
    let truncated = b0 | b1 | b2 | b3
    let mod = UInt32(pow(10.0, Double(digits)))
    let code = truncated % mod
    return String(format: "%0\(digits)d", code)
}

// MARK: - CLI

let usage = """
Usage:
  touchid-gorilla wrap <name>          stdin → /tmp/s3c-gorilla/<name>.blob (biometry-gated)
  touchid-gorilla unwrap <name>        Touch ID → decrypt → stdout
  touchid-gorilla wrap-list            list current wrap blobs
  touchid-gorilla wrap-clear [name]    delete one blob (or all if no arg)
  touchid-gorilla ssh-generate <name>  create SE-born ECDSA-P256 SSH key
  touchid-gorilla ssh-pub <name>       print OpenSSH public key
  touchid-gorilla ssh-delete <name>    delete SE-born SSH key
  touchid-gorilla totp <secret_or_uri> print current 6-digit TOTP code
"""

let args = CommandLine.arguments
if args.count < 2 {
    fputs(usage + "\n", stderr)
    exit(1)
}

switch args[1] {
case "wrap":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if !wrap(name: args[2], data: data) { exit(1) }

case "unwrap":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    guard let data = unwrap(name: args[2]) else { exit(1) }
    FileHandle.standardOutput.write(data)

case "wrap-list":
    wrapList()

case "wrap-clear":
    wrapClear(name: args.count >= 3 ? args[2] : nil)

case "ssh-generate":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    if !sshGenerate(name: args[2]) { exit(1) }
    if let pub = sshPub(name: args[2]) { print(pub) }

case "ssh-pub":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    guard let pub = sshPub(name: args[2]) else { exit(1) }
    print(pub)

case "ssh-delete":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    sshDelete(name: args[2])

case "totp":
    guard args.count >= 3 else { fputs(usage + "\n", stderr); exit(1) }
    var totpInput = args[2]
    if totpInput.hasPrefix("otpauth://") {
        if let comps = URLComponents(string: totpInput),
           let item = comps.queryItems?.first(where: { $0.name == "secret" }),
           let v = item.value {
            totpInput = v
        } else {
            fputs("Invalid otpauth URI\n", stderr); exit(1)
        }
    }
    guard let secret = base32Decode(totpInput) else {
        fputs("Invalid base32 secret\n", stderr); exit(1)
    }
    print(computeTOTP(secret: secret))

default:
    fputs(usage + "\n", stderr)
    exit(1)
}
