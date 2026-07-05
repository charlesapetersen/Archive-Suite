import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}
let folderBack  = rgb(0.79, 0.67, 0.42)
let folderFront = rgb(0.88, 0.79, 0.56)
let folderEdge  = rgb(0.72, 0.60, 0.36)
let page        = rgb(0.98, 0.96, 0.90)
let pageEdge     = rgb(0.86, 0.83, 0.74)
let line        = rgb(0.77, 0.74, 0.64)
let glass        = rgb(0.34, 0.29, 0.22)

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func softShadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    let s = NSShadow(); s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy); s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.set()
}

// ---- Folder back + tab (one silhouette) ----
NSGraphicsContext.current!.saveGraphicsState()
softShadow(34, -14, 0.28)
let back = NSBezierPath()
back.move(to: NSPoint(x: 150, y: 250))
back.line(to: NSPoint(x: 150, y: 690))
back.line(to: NSPoint(x: 300, y: 780))     // tab step
back.line(to: NSPoint(x: 470, y: 780))
back.line(to: NSPoint(x: 520, y: 700))
back.line(to: NSPoint(x: 874, y: 700))
back.line(to: NSPoint(x: 874, y: 250))
back.close()
let backRounded = NSBezierPath(roundedRect: NSRect(x: 150, y: 250, width: 724, height: 530), xRadius: 46, yRadius: 46)
folderBack.setFill(); backRounded.fill()
NSGraphicsContext.current!.restoreGraphicsState()

// ---- Two document pages peeking above the folder front ----
func drawPage(cx: CGFloat, angle: CGFloat, lean: CGFloat) {
    NSGraphicsContext.current!.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: cx, yBy: 470); t.rotate(byDegrees: angle); t.concat()
    softShadow(16, -6, 0.18)
    let p = rounded(-165, -70, 330, 470, 14)
    page.setFill(); p.fill()
    NSGraphicsContext.current!.restoreGraphicsState()
    // border + text lines (no shadow)
    NSGraphicsContext.current!.saveGraphicsState()
    let t2 = NSAffineTransform()
    t2.translateX(by: cx, yBy: 470); t2.rotate(byDegrees: angle); t2.concat()
    pageEdge.setStroke(); let border = rounded(-165, -70, 330, 470, 14); border.lineWidth = 3; border.stroke()
    line.setFill()
    for i in 0..<6 {
        let y = 320 - CGFloat(i) * 58
        let w: CGFloat = (i == 0) ? 150 : (240 - CGFloat(i % 2) * 40)
        rounded(-120, y, w, 20, 10).fill()
    }
    NSGraphicsContext.current!.restoreGraphicsState()
}
drawPage(cx: 400, angle: -7, lean: 0)
drawPage(cx: 620, angle: 7, lean: 0)

// ---- Folder front pocket (covers lower half of pages) ----
NSGraphicsContext.current!.saveGraphicsState()
softShadow(20, -8, 0.16)
let front = NSBezierPath(roundedRect: NSRect(x: 150, y: 250, width: 724, height: 300), xRadius: 46, yRadius: 46)
// square off the top of the pocket
let frontTop = NSBezierPath(rect: NSRect(x: 150, y: 470, width: 724, height: 90))
let frontCombined = front.copy() as! NSBezierPath
frontCombined.append(frontTop)
folderFront.setFill(); frontCombined.fill()
NSGraphicsContext.current!.restoreGraphicsState()
folderEdge.setStroke(); let frontStroke = NSBezierPath(roundedRect: NSRect(x: 150, y: 250, width: 724, height: 300), xRadius: 46, yRadius: 46); frontStroke.lineWidth = 3; frontStroke.stroke()

// ---- Reading glasses (lower-right) ----
NSGraphicsContext.current!.saveGraphicsState()
softShadow(14, -6, 0.30)
glass.setStroke()
func lens(_ x: CGFloat, _ y: CGFloat) {
    let l = rounded(x, y, 150, 120, 52); l.lineWidth = 26; l.stroke()
}
lens(560, 150)
lens(730, 150)
// bridge
let bridge = NSBezierPath(); bridge.move(to: NSPoint(x: 710, y: 214)); bridge.line(to: NSPoint(x: 730, y: 214))
bridge.lineWidth = 22; bridge.lineCapStyle = .round; bridge.stroke()
// temple arms (angled outward like a resting pair of glasses)
let armL = NSBezierPath(); armL.move(to: NSPoint(x: 566, y: 205)); armL.line(to: NSPoint(x: 496, y: 250))
armL.lineWidth = 22; armL.lineCapStyle = .round; armL.stroke()
let armR = NSBezierPath(); armR.move(to: NSPoint(x: 874, y: 205)); armR.line(to: NSPoint(x: 944, y: 250))
armR.lineWidth = 22; armR.lineCapStyle = .round; armR.stroke()
NSGraphicsContext.current!.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let out = "/private/tmp/claude-504/-Users-cp1/2101182a-47e6-459b-923f-1b15cb11c35a/scratchpad/icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
