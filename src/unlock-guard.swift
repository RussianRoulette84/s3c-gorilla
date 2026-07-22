// unlock-guard.swift — the "gorilla guards this app" motif: a dashed beam from the gorilla to a
// tile showing the app that asked for SSH, with a padlock in the middle that opens on a
// successful unlock. Split out of s3c-unlock-window.swift (400-line cap).

import Cocoa
import QuartzCore

extension UnlockController {
    // MARK: guard motif (gorilla ── lock ── app)

    func buildGuardStrip(on root: NSView, colX: CGFloat) {
        let y: CGFloat = 178
        let tileX = W - 84.0

        let beam = CAShapeLayer()                      // glowing dashed link from the gorilla to the app
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 138, y: y)); path.addLine(to: CGPoint(x: tileX, y: y))
        beam.path = path
        beam.strokeColor = Palette.cyan.withAlphaComponent(0.5).cgColor
        beam.lineWidth = 2; beam.lineDashPattern = [2, 4]
        beam.shadowColor = Palette.cyan.cgColor; beam.shadowRadius = 4; beam.shadowOpacity = 0.7; beam.shadowOffset = .zero
        root.layer?.addSublayer(beam)

        let pad = CALayer()                            // dark pad so the lock reads over the beam
        pad.frame = CGRect(x: 292, y: y - 16, width: 40, height: 32)
        pad.backgroundColor = Palette.bgBottom.cgColor; pad.cornerRadius = 6
        root.layer?.addSublayer(pad)
        let (lock, shackle) = makeLock()
        lock.frame = CGRect(x: 301, y: y - 13, width: 22, height: 26)
        root.layer?.addSublayer(lock); lockShackle = shackle

        let tile = NSView(frame: NSRect(x: tileX, y: y - 22, width: 44, height: 44))
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10; tile.layer?.borderWidth = 1
        tile.layer?.borderColor = Palette.cyan.withAlphaComponent(0.6).cgColor
        tile.layer?.backgroundColor = Palette.field.cgColor
        let iv = NSImageView(frame: NSRect(x: 5, y: 5, width: 34, height: 34))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = appPath.isEmpty ? NSImage(named: NSImage.applicationIconName)
                                   : NSWorkspace.shared.icon(forFile: appPath)
        tile.addSubview(iv); root.addSubview(tile)

        let label = NSTextField(labelWithString: "for  " + (appName.isEmpty ? "an app" : appName))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Palette.steel; label.alignment = .right
        label.backgroundColor = .clear; label.isBezeled = false
        label.frame = NSRect(x: 336, y: y - 9, width: tileX - 336 - 10, height: 18)
        root.addSubview(label)
    }
    func makeLock() -> (CALayer, CAShapeLayer) {
        let c = CALayer()
        let body = CAShapeLayer()
        body.path = CGPath(roundedRect: CGRect(x: 3, y: 0, width: 16, height: 13), cornerWidth: 3, cornerHeight: 3, transform: nil)
        body.fillColor = Palette.bronze.cgColor
        body.shadowColor = Palette.bronze.cgColor; body.shadowRadius = 4; body.shadowOpacity = 0.7; body.shadowOffset = .zero
        c.addSublayer(body)
        let shackle = CAShapeLayer()
        let sp = CGMutablePath()
        sp.addArc(center: CGPoint(x: 11, y: 13), radius: 5, startAngle: .pi, endAngle: 0, clockwise: false)
        shackle.path = sp; shackle.strokeColor = Palette.bronze.cgColor
        shackle.lineWidth = 2.2; shackle.fillColor = NSColor.clear.cgColor; shackle.lineCap = .round
        c.addSublayer(shackle)
        return (c, shackle)
    }
    func openLock() {
        guard let s = lockShackle else { return }
        s.strokeColor = Palette.cyan.cgColor               // bronze → cyan = granted
        let up = CABasicAnimation(keyPath: "position.y")
        up.byValue = 4; up.duration = 0.2
        up.fillMode = .forwards; up.isRemovedOnCompletion = false
        up.timingFunction = CAMediaTimingFunction(name: .easeOut)
        s.add(up, forKey: "lockopen")
    }
}
