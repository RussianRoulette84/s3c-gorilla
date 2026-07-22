// unlock-theme.swift — palette, motion/biometry helpers and the key-accepting borderless panel
// shared by the s3c-gorilla unlock window. Split out of s3c-unlock-window.swift (400-line cap).

import Cocoa
import QuartzCore
import LocalAuthentication

// MARK: - Palette (sampled from icon.png)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
enum Palette {
    static let bgTop    = NSColor(hex: 0x1E2833)
    static let bgBottom = NSColor(hex: 0x0E141B)
    static let cyan     = NSColor(hex: 0x2FC9EE)
    static let cyanDim  = NSColor(hex: 0x1C6E82)
    static let steel    = NSColor(hex: 0x8A97A6)
    static let bronze   = NSColor(hex: 0xC9A24B)
    static let text     = NSColor(hex: 0xE6EEF5)
    static let field    = NSColor(hex: 0x0A0F14)
    static let red      = NSColor(hex: 0xFF3D5A)
}

func reduceMotion() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
func hasBiometry() -> Bool {
    var err: NSError?
    return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
}

// MARK: - Key-accepting borderless window

final class KeyPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func mouseDragged(with event: NSEvent) { performDrag(with: event) }
}
