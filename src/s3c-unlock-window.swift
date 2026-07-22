// s3c-unlock-window — the native vault-unlock window the SSH agent spawns on a cold unlock.
//
// Standalone GUI helper (NOT part of the agent's run loop): the agent runs it as a subprocess,
// the user unlocks, and on success we print four lines to stdout the agent parses:
//   <master password>
//   scope=<once|app|session>
//   askpw=<0|1>
//   ttl=<minutes>         (0 = no timer)
// Cancel / empty password → exit 1 (nothing printed). The agent also passes argv:
//   [1] = requesting app name, [2] = its .app bundle path — shown as the "guard" motif.
//   --password-mode  = Mac with no Secure Enclave (keys come from the per-tty session
//                      agent), so the "this app" and "ask pw each time" states are hidden.
//
// Controls live in unlock-controls.swift; palette/panel in unlock-theme.swift.

import Cocoa
import QuartzCore
import LocalAuthentication

// MARK: - Controller

final class UnlockController: NSObject {
    private var win: KeyPanel!
    private var rootView: NSView!
    private var pw: PasswordDots!
    private var scope: ScopeTimerSwitch!
    private var dimWin: NSWindow?
    private var unlockBtn: NSButton!
    var lockShackle: CAShapeLayer?    // the guard lock's shackle (lifts open on unlock)
    private var capsDot: CALayer?
    private let biometry = hasBiometry()
    let W: CGFloat = 700
    private let H: CGFloat = 212

    // Who triggered SSH — passed by the agent as argv: [1]=app name, [2]=app bundle path.
    // `--password-mode` (any position) = Mac without a Secure Enclave: drop the scope choices
    // that only exist because of the chip. Flags are filtered out of the positional args.
    private static let argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("--") }
    let passwordMode = CommandLine.arguments.contains("--password-mode")
    let appName = UnlockController.argv.count > 0 ? UnlockController.argv[0] : ""
    let appPath = UnlockController.argv.count > 1 ? UnlockController.argv[1] : ""

    private var busyOverlay: NSView?
    private var busyLabel: NSTextField?
    private var failedOnce = false
    private var activeSound: NSSound?
    private let soundsDir = "/usr/local/share/s3c-gorilla/sounds"
    private let dohFile = "doh3.mp3"        // Yaro's pick
    private let woohooFile = "woohoo.mp3"

    func show() {
        win = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                       styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        win.level = .floating; win.isMovableByWindowBackground = true
        // Spawned from a LaunchAgent: without this the panel can land on another Space (or behind
        // a fullscreen app) and the caller waits forever for a window nobody can see.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        rootView = root
        root.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = root.bounds
        grad.colors = [Palette.bgTop.cgColor, Palette.bgBottom.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 1); grad.endPoint = CGPoint(x: 1, y: 0)
        grad.cornerRadius = 18
        root.layer?.addSublayer(grad)
        root.layer?.cornerRadius = 18
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Palette.cyan.withAlphaComponent(0.5).cgColor
        win.contentView = root

        // Left: glowing icon (the icon already carries the wordmark — no separate label).
        // A radial halo BEHIND the icon is the visible colored glow (a layer shadow on an
        // NSImageView renders unreliably); the icon breathes toward/away via a tiny scale pulse.
        let iconRect = NSRect(x: 22, y: 30, width: 108, height: 108)
        let cx = iconRect.midX, cy = iconRect.midY
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [Palette.cyan.withAlphaComponent(0.3).cgColor, Palette.cyan.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        halo.frame = CGRect(x: cx - 82, y: cy - 82, width: 164, height: 164)
        root.layer?.addSublayer(halo)

        let icon = NSImageView(frame: iconRect)
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let img = NSImage(contentsOfFile: "/usr/local/share/s3c-gorilla/icon.png") { icon.image = img }
        root.addSubview(icon)

        if !reduceMotion() {
            let pulse = CABasicAnimation(keyPath: "transform.scale")   // toward/away, tiny
            pulse.fromValue = 0.98; pulse.toValue = 1.035; pulse.duration = 2.2
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.layer?.add(pulse, forKey: "pulse")

            let haloOp = CABasicAnimation(keyPath: "opacity")          // glow breathes with it
            haloOp.fromValue = 0.25; haloOp.toValue = 0.55; haloOp.duration = 2.2
            haloOp.autoreverses = true; haloOp.repeatCount = .infinity
            haloOp.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(haloOp, forKey: "haloOp")
            let haloSc = CABasicAnimation(keyPath: "transform.scale")
            haloSc.fromValue = 0.92; haloSc.toValue = 1.05; haloSc.duration = 2.2
            haloSc.autoreverses = true; haloSc.repeatCount = .infinity
            haloSc.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(haloSc, forKey: "haloSc")
        }

        let colX: CGFloat = 152
        let colW = W - colX - 24

        // Guard strip (top): the gorilla (left) beams a locked link to the requesting app.
        buildGuardStrip(on: root, colX: colX)

        // Row 1: password field.
        pw = PasswordDots(frame: NSRect(x: colX, y: 96, width: colW - 24, height: 48))
        pw.onSubmit = { [weak self] in self?.submit() }
        pw.onCancel = { [weak self] in self?.cancel() }
        root.addSubview(pw)

        // Caps-lock warning dot (amber), right of the password row; hidden unless caps is on.
        let dot = CALayer()
        dot.frame = CGRect(x: W - 40, y: 112, width: 10, height: 10)
        dot.cornerRadius = 5
        dot.backgroundColor = NSColor(hex: 0xFFB000).cgColor
        dot.shadowColor = NSColor(hex: 0xFFB000).cgColor; dot.shadowRadius = 5; dot.shadowOpacity = 0.9; dot.shadowOffset = .zero
        dot.opacity = 0
        root.layer?.addSublayer(dot); capsDot = dot

        // Row 2: the switcherdropdown (scope + timer + paranoid "Ask pw") spans the row; Unlock right.
        let unlockW: CGFloat = 108
        let switchW = colW - unlockW - 12
        scope = ScopeTimerSwitch(biometry: biometry, passwordMode: passwordMode)
        scope.frame = NSRect(x: colX, y: 30, width: switchW, height: 44)
        root.addSubview(scope)

        // Unlock — dark base, cyan hairline + glowing cyan text (cooler than a flat bright fill).
        let unlock = NSButton(title: "Unlock", target: self, action: #selector(submit))
        unlock.frame = NSRect(x: W - 24 - unlockW, y: 30, width: unlockW, height: 44)
        unlock.isBordered = false; unlock.wantsLayer = true
        unlock.font = .systemFont(ofSize: 14, weight: .bold)
        unlock.attributedTitle = NSAttributedString(string: "Unlock", attributes: [
            .foregroundColor: Palette.cyan,
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .kern: 1.5])
        let ug = CAGradientLayer()
        ug.frame = unlock.bounds
        ug.colors = [Palette.bgTop.cgColor, Palette.field.cgColor]
        ug.startPoint = CGPoint(x: 0.5, y: 1); ug.endPoint = CGPoint(x: 0.5, y: 0)
        ug.cornerRadius = 11
        unlock.layer?.addSublayer(ug)
        unlock.layer?.cornerRadius = 11
        unlock.layer?.borderWidth = 1.5
        unlock.layer?.borderColor = Palette.cyan.cgColor
        unlock.layer?.shadowColor = Palette.cyan.cgColor
        unlock.layer?.shadowRadius = 12; unlock.layer?.shadowOpacity = 0.55; unlock.layer?.shadowOffset = .zero
        unlock.keyEquivalent = "\r"
        root.addSubview(unlock); unlockBtn = unlock

        let cancel = NSButton(title: "", target: self, action: #selector(cancel))
        cancel.frame = .zero; cancel.isBordered = false; cancel.keyEquivalent = "\u{1b}"
        root.addSubview(cancel)

        // Live caps-lock tracking.
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.updateCaps(e.modifierFlags.contains(.capsLock)); return e
        }

        // Dead-center on the active screen (NSWindow.center() biases above middle).
        if let vf = (NSScreen.main)?.visibleFrame {
            win.setFrameOrigin(NSPoint(x: vf.midX - W / 2, y: vf.midY - H / 2))
        } else {
            win.center()
        }
        showBackdrop()                 // dim the screen behind, animated
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()     // agent-spawned: force it in front of whatever is focused
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(pw)
        unfoldOpen()                   // 3-D fold-in from a tiny box
    }

    @objc private func submit() {
        let secret = pw.secret
        guard !secret.isEmpty else { cancel(); return }
        ripple()
        // Checking the password runs KeePass's key derivation — seconds on a big vault. Do it OFF
        // the main thread, or the window freezes solid and looks crashed.
        setBusy("checking your master password…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.validate(secret)
            DispatchQueue.main.async {
                if ok {
                    self.setBusy("opening the vault — this can take a few seconds…")
                    self.openLock()                           // the guard lock clicks open
                    if self.failedOnce {                      // redeemed after a D'oh → Woohoo, let it play
                        self.play(self.woohooFile)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.emit(secret) }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.emit(secret) }
                    }
                } else {
                    self.clearBusy()
                    self.failedOnce = true
                    self.play(self.dohFile)
                    self.shake(); self.flashScreen(); self.pw.flashError()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pw.clearAll() }
                }
            }
        }
    }

    // MARK: busy state — spinning ring + status line over the panel

    private func setBusy(_ text: String) {
        if let l = busyLabel { l.stringValue = text; return }
        let o = NSView(frame: rootView.bounds)
        o.wantsLayer = true
        o.layer?.backgroundColor = Palette.bgBottom.withAlphaComponent(0.88).cgColor
        o.layer?.cornerRadius = 18

        let r: CGFloat = 15
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: 150, y: H / 2 - r, width: r * 2, height: r * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: r * 2 - 4, height: r * 2 - 4), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Palette.cyan.cgColor
        ring.lineWidth = 3
        ring.lineCap = .round
        ring.strokeStart = 0; ring.strokeEnd = 0.3
        ring.shadowColor = Palette.cyan.cgColor; ring.shadowRadius = 6
        ring.shadowOpacity = 0.9; ring.shadowOffset = .zero
        o.layer?.addSublayer(ring)
        if !reduceMotion() {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -CGFloat.pi * 2
            spin.duration = 0.9; spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }

        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = Palette.text
        l.backgroundColor = .clear; l.isBezeled = false
        l.frame = NSRect(x: 196, y: H / 2 - 11, width: W - 220, height: 22)
        o.addSubview(l)
        rootView.addSubview(o, positioned: .above, relativeTo: nil)
        busyOverlay = o; busyLabel = l
    }
    private func clearBusy() {
        busyOverlay?.removeFromSuperview()
        busyOverlay = nil; busyLabel = nil
    }
    private func emit(_ secret: String) {
        print(secret)
        print("scope=\(scope.scope)")
        print("askpw=\(scope.askPw ? 1 : 0)")
        print("ttl=\(scope.ttlMinutes)")
        fflush(stdout)
        fadeOutAndExit(0)
    }
    @objc private func cancel() { fadeOutAndExit(1) }

    // Fade the window + backdrop out, then quit with the given code.
    private func fadeOutAndExit(_ code: Int32) {
        hideBackdrop()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            win.animator().alphaValue = 0
        }, completionHandler: { exit(code) })
    }

    private func play(_ file: String) {
        let p = "\(soundsDir)/\(file)"
        guard FileManager.default.fileExists(atPath: p), let s = NSSound(contentsOfFile: p, byReference: true) else { return }
        activeSound = s   // retain so it isn't freed mid-play
        s.play()
    }
    private func shake() {
        guard let l = rootView.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -14, 12, -10, 8, -5, 3, 0]; a.duration = 0.5
        l.add(a, forKey: "shake")
    }
    private func flashScreen() {
        guard let l = rootView.layer else { return }
        let f = CALayer(); f.frame = rootView.bounds; f.cornerRadius = 18
        f.backgroundColor = Palette.red.cgColor; f.opacity = 0
        l.addSublayer(f)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 0.32; a.duration = 0.12; a.autoreverses = true; a.repeatCount = 2
        f.add(a, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { f.removeFromSuperlayer() }
    }


    // MARK: motion helpers

    private func showBackdrop() {
        guard let scr = NSScreen.main else { return }
        let d = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
        d.isOpaque = false; d.backgroundColor = .black; d.alphaValue = 0
        d.ignoresMouseEvents = true
        d.level = NSWindow.Level(rawValue: win.level.rawValue - 1)
        d.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        d.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.66; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.animator().alphaValue = 0.5
        }
        dimWin = d
    }
    private func hideBackdrop() {
        guard let d = dimWin else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.animator().alphaValue = 0
        }
        dimWin = nil
    }

    // 3-D fold: the bar unfolds from a tiny tilted box; a few cyan rectangles slide out.
    private func unfoldOpen() {
        guard !reduceMotion(), let l = win.contentView?.layer else { return }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5); l.position = CGPoint(x: W / 2, y: H / 2)
        var persp = CATransform3DIdentity; persp.m34 = -1.0 / 900
        let start = CATransform3DConcat(CATransform3DMakeScale(0.05, 0.5, 1),
                                        CATransform3DRotate(persp, 72 * .pi / 180, 0, 1, 0))
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: start)
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.duration = 0.5
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        l.add(a, forKey: "unfold")
        for i in 0..<3 {
            let p = CALayer()
            let h: CGFloat = 2 + CGFloat(i)
            p.frame = CGRect(x: W / 2 - 20, y: H / 2 + CGFloat(i * 10 - 10), width: 40, height: h)
            p.backgroundColor = Palette.cyan.cgColor; p.opacity = 0
            rootView.layer?.addSublayer(p)
            let w = CABasicAnimation(keyPath: "bounds.size.width")
            w.fromValue = 40; w.toValue = W - 60; w.duration = 0.5
            let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.8; op.toValue = 0; op.duration = 0.6
            w.beginTime = CACurrentMediaTime() + Double(i) * 0.05
            p.add(w, forKey: "w"); p.add(op, forKey: "op")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { p.removeFromSuperlayer() }
        }
    }
    private func ripple() {
        guard let host = rootView.layer, let b = unlockBtn else { return }
        let ring = CAShapeLayer()
        ring.frame = b.frame
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: b.frame.size), cornerWidth: 11, cornerHeight: 11, transform: nil)
        ring.fillColor = NSColor.clear.cgColor; ring.strokeColor = Palette.cyan.cgColor; ring.lineWidth = 2
        host.addSublayer(ring)
        let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 1; sc.toValue = 2.2; sc.duration = 0.5
        sc.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.85; op.toValue = 0; op.duration = 0.5
        ring.add(sc, forKey: "sc"); ring.add(op, forKey: "op")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring.removeFromSuperlayer() }
    }
    private func updateCaps(_ on: Bool) { capsDot?.opacity = on ? 1 : 0 }
}


// MARK: - Main
// @main (not top-level code) so this file can compile alongside unlock-theme/unlock-controls —
// multi-file builds forbid top-level statements.

@main
struct UnlockWindowMain {
    static var controller: UnlockController?   // retained for the app's lifetime
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let c = UnlockController()
        controller = c
        c.show()
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
