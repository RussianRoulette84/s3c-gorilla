import Foundation
import LocalAuthentication
import Security

let service = "s3c-gorilla"
let account = "master"

func store(password: String) {
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: password.data(using: .utf8)!,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess {
        fputs("✅ Master password stored (Touch ID will guard access)\n", stderr)
    } else {
        fputs("❌ Failed to store: \(status)\n", stderr)
        exit(1)
    }
}

func retrieve() {
    let context = LAContext()
    let semaphore = DispatchSemaphore(value: 0)
    var authSuccess = false

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: "s3c-gorilla needs to unlock your secrets"
    ) { success, error in
        authSuccess = success
        if !success {
            if let err = error {
                fputs("❌ Touch ID failed: \(err.localizedDescription)\n", stderr)
            }
        }
        semaphore.signal()
    }
    semaphore.wait()

    if !authSuccess {
        exit(1)
    }

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, let pw = String(data: data, encoding: .utf8) {
        print(pw, terminator: "")
    } else {
        fputs("❌ Failed to retrieve: \(status)\n", stderr)
        exit(1)
    }
}

func delete() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess {
        fputs("✅ Master password removed\n", stderr)
    } else {
        fputs("❌ Nothing to delete: \(status)\n", stderr)
        exit(1)
    }
}

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "store":
        let pw = String(cString: getpass("🔐 Enter KeePassXC master password: "))
        store(password: pw)
    case "delete":
        delete()
    default:
        fputs("Usage: gorilla-touchid [store|delete]\n", stderr)
        fputs("  (no args) = retrieve with Touch ID\n", stderr)
        fputs("  store     = save master password\n", stderr)
        fputs("  delete    = remove stored password\n", stderr)
        exit(1)
    }
} else {
    retrieve()
}
