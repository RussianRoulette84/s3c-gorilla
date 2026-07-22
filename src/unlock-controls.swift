// unlock-controls.swift — the bespoke controls for the unlock window: the spinning-circle
// password field and the scope/timer "switcherdropdown". Split out of s3c-unlock-window.swift.

import Cocoa
import QuartzCore
import Carbon.HIToolbox   // EnableSecureEventInput / key codes

// MARK: - Password field — a fixed row of circles (shooting-gallery targets)
// A fixed number of placeholder circles sit ahead. Typing fills one and spins it on its X axis a
// few cycles before it stops (like a shot ferry target). The cursor is a movable highlight (ring +
// glow) on the active circle — arrow keys move it — with NO I-beam and NO field rectangle.

final class PasswordDots: NSView {
    var secret: String { String(chars) }
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    private var chars: [Character] = []
    private var cursor = 0                 // insertion index in [0, chars.count]
    private var focused = false

    private let slotCount = 16             // fixed circles shown ahead
    private let dotSize: CGFloat = 20      // 20% bigger than before
    private let gap: CGFloat = 12
    private var rings: [CAShapeLayer] = []
    private var fills: [CAShapeLayer] = []
    private var slots: [CALayer] = []      // per-circle container (carries the X-axis spin)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        var t = CATransform3DIdentity; t.m34 = -1.0 / 600   // perspective so the X spin reads 3-D
        layer?.sublayerTransform = t
        for _ in 0..<slotCount {
            let c = CALayer()
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: dotSize - 2, height: dotSize - 2), transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 1.5
            c.addSublayer(ring)
            let fill = CAShapeLayer()
            fill.path = CGPath(ellipseIn: CGRect(x: 3, y: 3, width: dotSize - 6, height: dotSize - 6), transform: nil)
            fill.fillColor = Palette.cyanDim.cgColor
            fill.opacity = 0
            c.addSublayer(fill)
            c.shadowColor = Palette.cyan.cgColor; c.shadowOffset = .zero; c.shadowRadius = 7; c.shadowOpacity = 0
            layer?.addSublayer(c)
            slots.append(c); rings.append(ring); fills.append(fill)
        }
        layoutSlots(); refresh()
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { EnableSecureEventInput(); focused = true; refresh(); return true }
    override func resignFirstResponder() -> Bool { DisableSecureEventInput(); focused = false; refresh(); return true }

    override func keyDown(with e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: onSubmit?(); return
        case kVK_Escape: onCancel?(); return
        case kVK_LeftArrow:  cursor = max(0, cursor - 1); refresh(); return
        case kVK_RightArrow: cursor = min(chars.count, cursor + 1); refresh(); return
        case kVK_Delete:
            if cursor > 0 { chars.remove(at: cursor - 1); cursor -= 1 }
            refresh(); return
        case kVK_ForwardDelete:
            if cursor < chars.count { chars.remove(at: cursor) }
            refresh(); return
        default:
            guard !e.modifierFlags.contains(.command) else { return }
            var typed = false
            for ch in (e.characters ?? "") where !ch.isNewline && ch != "\u{7f}" {
                chars.insert(ch, at: min(cursor, chars.count)); cursor += 1; typed = true
            }
            if typed { refresh(); spin(cursor - 1) }   // spin the circle just filled
        }
    }

    private func layoutSlots() {
        let y = bounds.height / 2 - dotSize / 2
        for (i, c) in slots.enumerated() {
            c.frame = CGRect(x: CGFloat(i) * (dotSize + gap), y: y, width: dotSize, height: dotSize)
        }
    }

    // active = the circle the cursor sits on (the last typed one, or an arrow-selected one).
    private func activeIndex() -> Int {
        let a = cursor == 0 ? 0 : cursor - 1
        return min(a, slotCount - 1)
    }
    private func refresh() {
        let count = min(chars.count, slotCount)
        let act = activeIndex()
        for i in 0..<slotCount {
            let filled = i < count
            fills[i].fillColor = Palette.cyanDim.cgColor   // recover from an error flash
            fills[i].opacity = filled ? 1 : 0
            let active = focused && i == act && (filled || chars.isEmpty)
            if active {
                rings[i].opacity = 1
                rings[i].strokeColor = Palette.cyan.cgColor
                slots[i].shadowOpacity = 0.9
            } else if !filled {
                rings[i].opacity = 1
                rings[i].strokeColor = Palette.steel.withAlphaComponent(0.32).cgColor
                slots[i].shadowOpacity = 0
            } else {
                rings[i].opacity = 0          // settled circle = solid disc, no ring/glow
                slots[i].shadowOpacity = 0
            }
        }
    }

    func clearAll() { chars.removeAll(); cursor = 0; refresh() }

    // Flash every filled circle red (paired with the window shake on a wrong password).
    func flashError() {
        let count = min(chars.count, slotCount)
        for i in 0..<count {
            fills[i].fillColor = Palette.red.cgColor
            rings[i].opacity = 1; rings[i].strokeColor = Palette.red.cgColor
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.25; a.duration = 0.1; a.autoreverses = true; a.repeatCount = 3
            fills[i].add(a, forKey: "err")
        }
    }

    // Shooting-gallery spin: a few turns about the X axis, easing to a stop.
    private func spin(_ i: Int) {
        guard !reduceMotion(), i >= 0, i < slotCount else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.x")
        a.fromValue = 0
        a.toValue = CGFloat.pi * 2 * 3
        a.duration = 0.75
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slots[i].add(a, forKey: "spin")
    }
}

// MARK: - Switcherdropdown: scope states in one bar. The timer state opens a minutes dropdown;
// "Ask pw" (Touch ID Macs only) is the paranoid state — no cache, master pw each time.

// Which states the bar offers is decided by the Mac, so the segments are a table, not fixed
// indices: password-only Macs have no per-app tracking and no per-sign biometric to skip.
enum ScopeSeg { case once, app, session, timer, askpw }

final class ScopeTimerSwitch: NSView {
    let biometry: Bool
    let segs: [ScopeSeg]
    let ttlOptions: [(String, Int)] = [("5 min", 5), ("15 min", 15), ("30 min", 30),
                                       ("60 min", 60), ("2 hrs", 120), ("8 hrs", 480), ("24 hrs", 1440)]
    var ttlIndex = 1                          // default 15 min (only used when the timer state is picked)
    var selected = 0 { didSet { restyle(); movePill(animated: true) } }
    private var buttons: [NSButton] = []
    private var weights: [CGFloat] = []
    private var timerSeg: Int { segs.firstIndex(of: .timer) ?? -1 }
    private var askPwSeg: Int { segs.firstIndex(of: .askpw) ?? -1 }
    private var panel: NSWindow?
    private let pill = CALayer()               // the single sliding selection highlight

    var scope: String {
        switch segs[selected] {
        case .once, .askpw: return "once"
        case .app:          return "app"
        default:            return "session"
        }
    }
    var ttlMinutes: Int { selected == timerSeg ? ttlOptions[ttlIndex].1 : 0 }
    var askPw: Bool { selected == askPwSeg }

    // passwordMode = no Secure Enclave. Keys are served by the per-tty session agent, so
    // "this app" (owning-PID tracking) and "ask pw each time" (skipping a fingerprint that
    // never happens) are meaningless there — only once / until-lock / timer make sense.
    init(biometry: Bool, passwordMode: Bool) {
        self.biometry = biometry
        var s: [ScopeSeg] = passwordMode ? [.once, .session, .timer] : [.once, .app, .session, .timer]
        if biometry && !passwordMode { s.append(.askpw) }
        segs = s
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.field.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = Palette.steel.withAlphaComponent(0.3).cgColor
        pill.cornerRadius = 7
        pill.borderWidth = 1
        layer?.insertSublayer(pill, at: 0)   // behind the (transparent) buttons

        weights = segs.map { (seg: ScopeSeg) -> CGFloat in
            switch seg { case .timer: return 1.35; case .askpw: return 0.9; default: return 1 }
        }
        selected = segs.firstIndex(of: .session) ?? 0   // default "Until lock"; timer OFF
        for i in 0..<weights.count {
            let b = HoverSeg(title: "", target: self, action: #selector(pick(_:)))
            b.tag = i; b.isBordered = false; b.wantsLayer = true
            b.font = .systemFont(ofSize: 11, weight: .semibold)
            addSubview(b); buttons.append(b)
        }
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    // The timer segment is a touch wider (label + chevron); the rest split by weight.
    override func layout() {
        super.layout()
        let total = weights.reduce(0, +)
        let avail = bounds.width - 8
        var x: CGFloat = 4
        for (i, b) in buttons.enumerated() {
            let w = avail * weights[i] / total
            b.frame = NSRect(x: x, y: 4, width: w, height: bounds.height - 8)
            x += w
        }
        movePill(animated: false)   // snap to the current selection after (re)layout
    }

    // Slide the highlight to the selected segment with a springy left/right glide.
    private func movePill(animated: Bool) {
        guard selected < buttons.count, buttons[selected].frame.width > 0 else { return }
        let target = buttons[selected].frame
        let accent = (selected == askPwSeg ? Palette.bronze : Palette.cyan)
        pill.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        pill.borderColor = accent.cgColor
        pill.shadowColor = accent.cgColor; pill.shadowOffset = .zero
        pill.shadowRadius = 8; pill.shadowOpacity = 0.6
        let toPos = CGPoint(x: target.midX, y: target.midY)
        let toBounds = CGRect(origin: .zero, size: target.size)
        if animated && !reduceMotion() {
            let from = pill.presentation()?.position ?? pill.position
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: from)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 15; spring.stiffness = 220; spring.mass = 0.9
            spring.initialVelocity = 6
            spring.duration = spring.settlingDuration
            let sz = CABasicAnimation(keyPath: "bounds.size")
            sz.fromValue = NSValue(size: pill.presentation()?.bounds.size ?? pill.bounds.size)
            sz.toValue = NSValue(size: toBounds.size)
            sz.duration = 0.35; sz.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pill.position = toPos; pill.bounds = toBounds
            pill.add(spring, forKey: "pos"); pill.add(sz, forKey: "sz")
        } else {
            pill.position = toPos; pill.bounds = toBounds
        }
    }
    private func titles() -> [String] {
        segs.map { (seg: ScopeSeg) -> String in
            switch seg {
            case .once:    return "Just once"
            case .app:     return "This app"
            case .session: return "Until lock"
            case .timer:   return "⏱ \(ttlOptions[ttlIndex].0) ▾"
            case .askpw:   return "Ask pw"
            }
        }
    }
    private func refreshTimerTitle() {
        guard timerSeg >= 0 else { return }
        buttons[timerSeg].title = titles()[timerSeg]
    }

    @objc private func pick(_ s: NSButton) {
        selected = s.tag
        if s.tag == timerSeg { openPanel() }   // choosing the timer opens its dropdown to set the minutes
    }
    private func restyle() {
        let t = titles()
        for (i, b) in buttons.enumerated() {
            b.title = t[i]                              // highlight is the sliding pill; buttons just tint text
            let accent = i == askPwSeg ? Palette.bronze : Palette.cyan
            b.contentTintColor = i == selected ? accent : Palette.steel
        }
    }

    private func openPanel() {
        close()
        guard let host = window else { return }
        let seg = buttons[timerSeg].frame
        let rowH: CGFloat = 30, w = max(seg.width, 110)
        let h = rowH * CGFloat(ttlOptions.count) + 8
        // Drop DOWN by default; flip UP only if there isn't room below on this screen.
        let vis = (host.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let botScreen = host.convertPoint(toScreen: convert(NSPoint(x: seg.minX, y: seg.minY), to: nil))
        let topScreen = host.convertPoint(toScreen: convert(NSPoint(x: seg.minX, y: seg.maxY), to: nil))
        let openDown = (botScreen.y - h - 4) >= vis.minY
        let originY = openDown ? (botScreen.y - h - 4) : (topScreen.y + 4)
        let p = NSWindow(contentRect: NSRect(x: botScreen.x, y: originY, width: w, height: h),
                         styleMask: .borderless, backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .popUpMenu
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.bgBottom.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.cyan.withAlphaComponent(0.45).cgColor
        for (i, opt) in ttlOptions.enumerated() {
            let b = HoverButton(title: "", target: self, action: #selector(chooseMinutes(_:)))
            b.tag = i; b.isBordered = false; b.wantsLayer = true; b.alignment = .left
            let para = NSMutableParagraphStyle(); para.firstLineHeadIndent = 8; para.headIndent = 8
            b.attributedTitle = NSAttributedString(string: opt.0, attributes: [
                .paragraphStyle: para,
                .foregroundColor: (i == ttlIndex ? Palette.cyan : Palette.text),
                .font: NSFont.systemFont(ofSize: 12)])
            b.frame = NSRect(x: 6, y: h - 4 - rowH * CGFloat(i + 1), width: w - 12, height: rowH)
            container.addSubview(b)
        }
        p.contentView = container
        host.addChildWindow(p, ordered: .above)
        panel = p
    }
    private func close() { if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil); panel = nil } }
    @objc private func chooseMinutes(_ s: NSButton) {
        ttlIndex = s.tag; selected = timerSeg; refreshTimerTitle(); restyle(); close()
    }
}

final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        Palette.cyan.withAlphaComponent(0.8).setFill()
        NSRect(x: 0, y: 4, width: 2, height: bounds.height - 8).fill()
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Palette.cyan.withAlphaComponent(0.14).cgColor; layer?.cornerRadius = 7 }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

// A scope segment that glows faintly on hover (before you even click).
final class HoverSeg: NSButton {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.cornerRadius = 7; layer?.backgroundColor = Palette.cyan.withAlphaComponent(0.08).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}
