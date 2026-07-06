#!/usr/bin/env swift
// make-dmg-background.swift — render the Archive Suite DMG window background.
// Usage: swift make-dmg-background.swift [out.png]   (default: ./dmg-background.png)
// Runs on the dev Mac only (uses AppKit). The window layout in build-suite-dmg.sh places the two
// app icons on the left and the Applications alias on the right, vertically centered — matching the
// arrow drawn here.
import AppKit

let W: CGFloat = 640, H: CGFloat = 400   // matches the Finder window content size in build-suite-dmg.sh
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// Background: soft vertical gradient (AppKit origin is bottom-left; y increases upward).
NSGradient(colors: [
    NSColor(calibratedRed: 0.965, green: 0.975, blue: 0.995, alpha: 1),
    NSColor(calibratedRed: 0.878, green: 0.910, blue: 0.965, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

func draw(_ s: String, cx: CGFloat, yTop: CGFloat, size: CGFloat, weight: NSFont.Weight, white: CGFloat, alpha: CGFloat = 1) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: white, alpha: alpha),
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    // yTop is measured from the TOP of the image; convert to AppKit's bottom-left origin.
    str.draw(at: NSPoint(x: cx - sz.width / 2, y: H - yTop - sz.height))
}

// Title + subtitle near the top.
draw("Archive Suite", cx: W/2, yTop: 40, size: 34, weight: .bold, white: 0.13)
draw("Drag both apps into the Applications folder", cx: W/2, yTop: 86, size: 15, weight: .regular, white: 0.30)

// A right-pointing arrow across the middle (from behind the apps toward Applications).
let midY = H/2 - 6          // AppKit y of the arrow center (icons are vertically centered)
let x0: CGFloat = 300, x1: CGFloat = 396, headW: CGFloat = 22, shaftH: CGFloat = 10
NSColor(calibratedRed: 0.30, green: 0.46, blue: 0.78, alpha: 0.85).setFill()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: x0, y: midY - shaftH/2))
arrow.line(to: NSPoint(x: x1 - headW, y: midY - shaftH/2))
arrow.line(to: NSPoint(x: x1 - headW, y: midY - shaftH))
arrow.line(to: NSPoint(x: x1, y: midY))
arrow.line(to: NSPoint(x: x1 - headW, y: midY + shaftH))
arrow.line(to: NSPoint(x: x1 - headW, y: midY + shaftH/2))
arrow.line(to: NSPoint(x: x0, y: midY + shaftH/2))
arrow.close()
arrow.fill()

// Footer: first-launch note (ad-hoc signed, not notarized).
draw("First launch: Control-click each app → Open", cx: W/2, yTop: H - 44, size: 12, weight: .medium, white: 0.38)

img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render PNG\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(W))x\(Int(H)))")
