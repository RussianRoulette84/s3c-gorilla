// unlock-vault.swift — kdbx lookups for the unlock window: locate keepassxc-cli + the database,
// and check the typed master password so the window can react in place (shake / D'oh) instead of
// exiting blind. Split out of s3c-unlock-window.swift (400-line cap).

import Cocoa

extension UnlockController {
    // Validate the master password against the kdbx so we can react in-window (shake / D'oh) instead
    // of exiting blind. Fail-OPEN if keepassxc-cli is missing — the agent re-validates anyway.
    func validate(_ pw: String) -> Bool {
        // GORILLA_UNLOCK_DEBUG=1 → log to stderr what we captured + keepassxc's real error, so a
        // "correct password rejected" bug can be diagnosed without printing the password itself.
        let debug = ProcessInfo.processInfo.environment["GORILLA_UNLOCK_DEBUG"] == "1"
        let cli = keepassxcCLI(), db = dbPath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["ls", "-q", db]
        let inp = Pipe(); proc.standardInput = inp
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = debug ? Pipe() : nil
        proc.standardError = errPipe?.fileHandleForWriting ?? FileHandle.nullDevice
        do { try proc.run() } catch {
            if debug { FileHandle.standardError.write("unlock-debug: could not run \(cli): \(error)\n".data(using: .utf8)!) }
            return true
        }
        inp.fileHandleForWriting.write((pw + "\n").data(using: .utf8)!)
        try? inp.fileHandleForWriting.close()
        var errText = ""
        if let e = errPipe { errText = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
        proc.waitUntilExit()
        if debug {
            let msg = "unlock-debug: cli=\(cli) db=\(db) capturedChars=\(pw.count) exit=\(proc.terminationStatus) err=\(errText.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
        return proc.terminationStatus == 0
    }
    func keepassxcCLI() -> String {
        for c in ["/opt/homebrew/bin/keepassxc-cli", "/usr/local/bin/keepassxc-cli"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/usr/local/bin/keepassxc-cli"
    }
    func dbPath() -> String {
        let home = NSHomeDirectory()
        var db = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/gorilla_tunnel.dat.kdbx"
        if let text = try? String(contentsOfFile: "\(home)/.config/s3c-gorilla/config", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("GORILLA_DB=") {
                    db = String(t.dropFirst("GORILLA_DB=".count))
                        .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "$HOME", with: home)
                }
            }
        }
        return db
    }

}
