#!/usr/bin/env swift
// make-app-icons.swift — draw the three Archive Suite app icons (W40.suite-app-icons).
// Usage:
//   swift release/make-app-icons.swift sheet <out.png>          candidate sheet: every set, big and at Dock size
//   swift release/make-app-icons.swift install <A|B|C> [repo]   write the chosen set into all three AppIcon.appiconsets
// Offscreen CoreGraphics + ImageIO only: it opens no window, so it is safe unattended.
// Each set is one family (same tile, same cream archival paper) told apart by hue and one glyph:
// Processor = capture/OCR/tag (blue), Reader = find/read (amber), Notes = write from a source (green).
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024   // design canvas; y runs DOWN (the context is flipped in render())

enum App: String, CaseIterable { case processor = "Processor", reader = "Reader", notes = "Notes" }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let paper = rgb(0xF8F2E4), paperEdge = rgb(0xD9CDB2), ink = rgb(0x8A7F6A)

struct Palette { let top: CGColor; let bottom: CGColor; let deep: CGColor; let accent: CGColor }
func palette(_ app: App) -> Palette {
    switch app {
    case .processor: return Palette(top: rgb(0x5A8CF5), bottom: rgb(0x2638B0), deep: rgb(0x1A2A80), accent: rgb(0x7FE7FF))
    case .reader:    return Palette(top: rgb(0xF8BF45), bottom: rgb(0xDB6410), deep: rgb(0x4E3322), accent: rgb(0xC8371E))
    case .notes:     return Palette(top: rgb(0x48C990), bottom: rgb(0x11735A), deep: rgb(0x173E33), accent: rgb(0x2B2B2B))
    }
}

// MARK: drawing helpers

func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

func vgrad(_ c: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor) {
    c.saveGState(); c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    let b = path.boundingBox
    c.drawLinearGradient(g, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
    c.restoreGState()
}

func fill(_ c: CGContext, _ path: CGPath, _ color: CGColor, shadow: CGFloat = 0) {
    c.saveGState()
    if shadow > 0 { c.setShadow(offset: CGSize(width: 0, height: -shadow * 0.5), blur: shadow, color: rgb(0x000000, 0.28)) }
    c.addPath(path); c.setFillColor(color); c.fillPath(); c.restoreGState()
}

func stroke(_ c: CGContext, _ path: CGPath, _ color: CGColor, _ w: CGFloat, cap: CGLineCap = .round) {
    c.saveGState(); c.addPath(path); c.setStrokeColor(color); c.setLineWidth(w); c.setLineCap(cap); c.setLineJoin(.round)
    c.strokePath(); c.restoreGState()
}

func line(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); return p }

func rotated(_ c: CGContext, around p: CGPoint, _ deg: CGFloat, _ body: () -> Void) {
    c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: deg * .pi / 180); c.translateBy(x: -p.x, y: -p.y)
    body(); c.restoreGState()
}

/// A sheet of archival paper with text lines; `lines` rows, the last one short.
func sheet(_ c: CGContext, _ r: CGRect, lines: Int, lineW: CGFloat = 16, shadow: CGFloat = 18) {
    fill(c, rr(r, r.width * 0.05), paper, shadow: shadow)
    stroke(c, rr(r, r.width * 0.05), paperEdge, 3)
    let pad = r.width * 0.16, gap = (r.height - 2 * pad) / CGFloat(max(lines, 1))
    for i in 0..<lines {
        let y = r.minY + pad + gap * (CGFloat(i) + 0.5)
        let end = i == lines - 1 ? r.minX + r.width * 0.55 : r.maxX - pad
        stroke(c, line([CGPoint(x: r.minX + pad, y: y), CGPoint(x: end, y: y)]), ink, lineW)
    }
}

/// The shared macOS tile: rounded square on the 824-pt grid with the app's gradient.
func tile(_ c: CGContext, _ p: Palette) {
    let body = rr(CGRect(x: 100, y: 100, width: 824, height: 824), 186)
    fill(c, body, p.bottom, shadow: 24)
    vgrad(c, body, p.top, p.bottom)
    // a faint top sheen so the tile does not read flat
    c.saveGState(); c.addPath(body); c.clip()
    fill(c, CGPath(ellipseIn: CGRect(x: -80, y: -520, width: 1184, height: 900), transform: nil), rgb(0xFFFFFF, 0.10))
    c.restoreGState()
}

// MARK: glyphs

func magnifier(_ c: CGContext, at o: CGPoint, r: CGFloat) {
    let ring = CGPath(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r), transform: nil)
    stroke(c, line([CGPoint(x: o.x + r * 0.7, y: o.y + r * 0.7), CGPoint(x: o.x + r * 1.75, y: o.y + r * 1.75)]), rgb(0x2B2B2B), r * 0.42)
    fill(c, ring, rgb(0xDDE6F5, 0.9), shadow: 14)
    stroke(c, ring, rgb(0x2B2B2B), r * 0.24)
}

func glasses(_ c: CGContext, at o: CGPoint, r: CGFloat, color: CGColor) {
    let l = CGRect(x: o.x - 2.15 * r, y: o.y - r, width: 2 * r, height: 2 * r)
    let rt = CGRect(x: o.x + 0.15 * r, y: o.y - r, width: 2 * r, height: 2 * r)
    for e in [l, rt] { fill(c, CGPath(ellipseIn: e, transform: nil), rgb(0xFFFFFF, 0.28)) }
    for e in [l, rt] { stroke(c, CGPath(ellipseIn: e, transform: nil), color, r * 0.28) }
    let bridge = CGMutablePath(); bridge.move(to: CGPoint(x: o.x - 0.2 * r, y: o.y - 0.25 * r))
    bridge.addQuadCurve(to: CGPoint(x: o.x + 0.2 * r, y: o.y - 0.25 * r), control: CGPoint(x: o.x, y: o.y - 0.6 * r))
    stroke(c, bridge, color, r * 0.24)
    stroke(c, line([CGPoint(x: l.minX, y: o.y - 0.3 * r), CGPoint(x: l.minX - 0.8 * r, y: o.y - 0.75 * r)]), color, r * 0.24)
    stroke(c, line([CGPoint(x: rt.maxX, y: o.y - 0.3 * r), CGPoint(x: rt.maxX + 0.8 * r, y: o.y - 0.75 * r)]), color, r * 0.24)
}

/// A luggage/price tag, the Processor's Finder-tag verb.
func tag(_ c: CGContext, at o: CGPoint, w: CGFloat, color: CGColor, deg: CGFloat = -35) {
    rotated(c, around: o, deg) {
        let h = w * 0.58
        let p = CGMutablePath()
        p.move(to: CGPoint(x: o.x - w / 2, y: o.y))
        p.addLine(to: CGPoint(x: o.x - w / 2 + h / 2, y: o.y - h / 2))
        p.addLine(to: CGPoint(x: o.x + w / 2, y: o.y - h / 2))
        p.addLine(to: CGPoint(x: o.x + w / 2, y: o.y + h / 2))
        p.addLine(to: CGPoint(x: o.x - w / 2 + h / 2, y: o.y + h / 2))
        p.closeSubpath()
        fill(c, p, color, shadow: 16)
        let hole = CGRect(x: o.x - w / 2 + h * 0.42, y: o.y - h * 0.11, width: h * 0.22, height: h * 0.22)
        fill(c, CGPath(ellipseIn: hole, transform: nil), rgb(0xFFFFFF, 0.95))
    }
}

/// A pencil from `tip` back along `deg`.
func pencil(_ c: CGContext, tip: CGPoint, len: CGFloat, deg: CGFloat, body: CGColor) {
    rotated(c, around: tip, deg) {
        let w = len * 0.17
        let cone = len * 0.2
        let shaft = CGRect(x: tip.x + cone, y: tip.y - w / 2, width: len - cone - w * 0.55, height: w)
        fill(c, rr(shaft, 4), body, shadow: 16)
        fill(c, CGPath(rect: CGRect(x: shaft.minX, y: shaft.minY, width: shaft.width, height: w * 0.34), transform: nil), rgb(0xFFFFFF, 0.18))
        fill(c, rr(CGRect(x: shaft.maxX - 6, y: tip.y - w / 2, width: w * 0.32, height: w), 3), rgb(0xC9CDD2))
        fill(c, rr(CGRect(x: shaft.maxX + w * 0.22, y: tip.y - w / 2, width: w * 0.42, height: w), w * 0.2), rgb(0xF08A9A))
        let wood = CGMutablePath()
        wood.move(to: tip); wood.addLine(to: CGPoint(x: tip.x + cone, y: tip.y - w / 2))
        wood.addLine(to: CGPoint(x: tip.x + cone, y: tip.y + w / 2)); wood.closeSubpath()
        fill(c, wood, rgb(0xEBC48F))
        let lead = CGMutablePath()
        lead.move(to: tip); lead.addLine(to: CGPoint(x: tip.x + cone * 0.36, y: tip.y - w * 0.18))
        lead.addLine(to: CGPoint(x: tip.x + cone * 0.36, y: tip.y + w * 0.18)); lead.closeSubpath()
        fill(c, lead, rgb(0x2B2B2B))
    }
}

func folder(_ c: CGContext, _ color: CGColor) {
    let back = CGMutablePath()
    back.addPath(rr(CGRect(x: 262, y: 392, width: 500, height: 360), 34))
    back.addPath(rr(CGRect(x: 262, y: 362, width: 180, height: 80), 26))
    fill(c, back, color.copy(alpha: 0.82)!, shadow: 12)
}

func folderFront(_ c: CGContext, _ color: CGColor) {
    fill(c, rr(CGRect(x: 244, y: 470, width: 536, height: 300), 38), color, shadow: 20)
}

// MARK: the three candidate sets

/// A — the current folder-of-papers, kept as the family, with a verb glyph per app.
func setA(_ c: CGContext, _ app: App) {
    let p = palette(app)
    tile(c, p)
    let folderColor: CGColor = app == .processor ? rgb(0xE3BC6A) : p.deep
    folder(c, folderColor)
    rotated(c, around: CGPoint(x: 450, y: 420), -9) { sheet(c, CGRect(x: 310, y: 230, width: 300, height: 380), lines: 6) }
    rotated(c, around: CGPoint(x: 560, y: 410), 7) { sheet(c, CGRect(x: 420, y: 210, width: 300, height: 380), lines: 6) }
    folderFront(c, folderColor)
    switch app {
    case .processor: tag(c, at: CGPoint(x: 700, y: 712), w: 270, color: rgb(0xF05A4A))
    case .reader:    glasses(c, at: CGPoint(x: 688, y: 720), r: 78, color: rgb(0x2A1C14))
    case .notes:     pencil(c, tip: CGPoint(x: 560, y: 812), len: 380, deg: -38, body: rgb(0xF4C430))
    }
}

/// B — one page per app, the glyph built into the page: a scanned page, an open book, a page being written.
func setB(_ c: CGContext, _ app: App) {
    let p = palette(app)
    tile(c, p)
    switch app {
    case .processor:
        let page = CGRect(x: 322, y: 222, width: 380, height: 520)
        sheet(c, page, lines: 7)
        // scan beam across the page
        c.saveGState(); c.addPath(rr(page, 19)); c.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [p.accent.copy(alpha: 0)!, p.accent.copy(alpha: 0.75)!, p.accent.copy(alpha: 0)!] as CFArray,
                           locations: [0, 0.5, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: 420), end: CGPoint(x: 0, y: 540), options: [])
        c.restoreGState()
        stroke(c, line([CGPoint(x: 290, y: 480), CGPoint(x: 734, y: 480)]), p.accent, 10)
        // viewfinder brackets
        let b: CGFloat = 92, m: CGFloat = 50
        let fr = page.insetBy(dx: -m, dy: -m)
        for (x, y, dx, dy) in [(fr.minX, fr.minY, 1.0, 1.0), (fr.maxX, fr.minY, -1.0, 1.0), (fr.minX, fr.maxY, 1.0, -1.0), (fr.maxX, fr.maxY, -1.0, -1.0)] {
            stroke(c, line([CGPoint(x: x, y: y + dy * b), CGPoint(x: x, y: y), CGPoint(x: x + dx * b, y: y)]), rgb(0xFFFFFF), 30)
        }
    case .reader:
        // open book: two pages meeting at a spine, slightly fanned
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 512, y: 330)); left.addQuadCurve(to: CGPoint(x: 212, y: 300), control: CGPoint(x: 360, y: 260))
        left.addLine(to: CGPoint(x: 212, y: 700)); left.addQuadCurve(to: CGPoint(x: 512, y: 740), control: CGPoint(x: 360, y: 660))
        left.closeSubpath()
        var flip = CGAffineTransform(translationX: 1024, y: 0).scaledBy(x: -1, y: 1)
        let right = left.copy(using: &flip)!
        fill(c, rr(CGRect(x: 196, y: 320, width: 632, height: 450), 30), p.deep, shadow: 18)   // cover
        fill(c, left, paper, shadow: 10); fill(c, right, paper, shadow: 10)
        stroke(c, line([CGPoint(x: 512, y: 330), CGPoint(x: 512, y: 740)]), paperEdge, 6)
        for i in 0..<5 {
            let y = 380 + CGFloat(i) * 62
            stroke(c, line([CGPoint(x: 262, y: y), CGPoint(x: 462, y: y + 22)]), ink, 14)
            stroke(c, line([CGPoint(x: 562, y: y + 22), CGPoint(x: i == 4 ? 680 : 762, y: y)]), ink, 14)
        }
        // bookmark ribbon
        let rib = CGMutablePath()
        rib.move(to: CGPoint(x: 660, y: 270)); rib.addLine(to: CGPoint(x: 720, y: 270)); rib.addLine(to: CGPoint(x: 720, y: 470))
        rib.addLine(to: CGPoint(x: 690, y: 440)); rib.addLine(to: CGPoint(x: 660, y: 470)); rib.closeSubpath()
        fill(c, rib, p.accent, shadow: 8)
    case .notes:
        let page = CGRect(x: 300, y: 212, width: 400, height: 540)
        fill(c, rr(page.offsetBy(dx: 26, dy: 22), 20), rgb(0xE8DEC6), shadow: 12)   // the source page behind
        sheet(c, page, lines: 0)
        // a quotation mark and a few written lines; the last is still being written
        let font = CTFontCreateWithName("Georgia-Bold" as CFString, 230, nil)
        c.saveGState(); c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let q = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{201C}", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): p.bottom]))
        c.textPosition = CGPoint(x: 340, y: 430); CTLineDraw(q, c); c.restoreGState()
        for i in 0..<3 {
            let y = 480 + CGFloat(i) * 64
            stroke(c, line([CGPoint(x: 364, y: y), CGPoint(x: 636, y: y)]), ink, 15)
        }
        let squiggle = CGMutablePath(); squiggle.move(to: CGPoint(x: 364, y: 672))
        squiggle.addCurve(to: CGPoint(x: 520, y: 672), control1: CGPoint(x: 410, y: 640), control2: CGPoint(x: 470, y: 704))
        stroke(c, squiggle, p.bottom, 15)
        pencil(c, tip: CGPoint(x: 526, y: 676), len: 400, deg: -40, body: rgb(0xF4C430))
    }
}

/// C — one cream page carrying the app's initial: the plainest, loudest at Dock size.
func setC(_ c: CGContext, _ app: App) {
    let p = palette(app)
    tile(c, p)
    let page = CGRect(x: 292, y: 212, width: 440, height: 580)
    sheet(c, page, lines: 0)
    let fold = CGMutablePath()   // dog-eared corner
    fold.move(to: CGPoint(x: page.maxX - 110, y: page.minY)); fold.addLine(to: CGPoint(x: page.maxX, y: page.minY + 110))
    fold.addLine(to: CGPoint(x: page.maxX - 110, y: page.minY + 110)); fold.closeSubpath()
    fill(c, fold, paperEdge)
    let font = CTFontCreateWithName("Georgia-Bold" as CFString, 400, nil)
    let s = CTLineCreateWithAttributedString(NSAttributedString(string: String(app.rawValue.prefix(1)), attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): p.bottom]))
    let bounds = CTLineGetBoundsWithOptions(s, .useGlyphPathBounds)
    c.saveGState(); c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    c.textPosition = CGPoint(x: page.midX - bounds.midX, y: page.midY + bounds.midY + 10)
    CTLineDraw(s, c); c.restoreGState()
    stroke(c, line([CGPoint(x: page.minX + 80, y: page.maxY - 90), CGPoint(x: page.maxX - 80, y: page.maxY - 90)]), ink, 14)
}

let sets: [String: (CGContext, App) -> Void] = ["A": setA, "B": setB, "C": setC]

// MARK: rendering

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func render(_ set: String, _ app: App, px: Int) -> CGImage {
    let big = context(1024, 1024)
    big.translateBy(x: 0, y: 1024); big.scaleBy(x: 1, y: -1)
    sets[set]!(big, app)
    let full = big.makeImage()!
    if px == 1024 { return full }
    let small = context(px, px); small.interpolationQuality = .high
    small.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
    return small.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("could not write \(url.path)") }
}

func label(_ c: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
    c.textPosition = CGPoint(x: x, y: y); CTLineDraw(l, c)
}

/// One row per set: each app at 256 px, then the three side by side at Dock sizes (64, 32) on light and dark.
func sheetImage() -> CGImage {
    let rowH = 330, W = 1500, H = 60 + rowH * sets.count
    let c = context(W, H)
    c.setFillColor(rgb(0xF4F4F6)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (i, key) in sets.keys.sorted().enumerated() {
        let top = CGFloat(H - 60 - rowH * i)          // CG y is up here
        label(c, "Set \(key)", x: 24, y: top - 34, size: 28, color: rgb(0x222222))
        for (j, app) in App.allCases.enumerated() {
            let x = CGFloat(24 + j * 280)
            c.draw(render(key, app, px: 256), in: CGRect(x: x, y: top - 300, width: 256, height: 256))
            label(c, app.rawValue, x: x + 90, y: top - 322, size: 18, color: rgb(0x555555))
        }
        // Dock-size strip
        for (k, dark) in [false, true].enumerated() {
            let sx = CGFloat(890), sy = top - 150 - CGFloat(k) * 140
            c.setFillColor(dark ? rgb(0x1E1E22) : rgb(0xFFFFFF))
            c.fill(CGRect(x: sx, y: sy - 10, width: 590, height: 104))
            for (j, app) in App.allCases.enumerated() {
                c.draw(render(key, app, px: 64), in: CGRect(x: sx + 16 + CGFloat(j) * 76, y: sy + 10, width: 64, height: 64))
                c.draw(render(key, app, px: 32), in: CGRect(x: sx + 280 + CGFloat(j) * 44, y: sy + 26, width: 32, height: 32))
                c.draw(render(key, app, px: 16), in: CGRect(x: sx + 440 + CGFloat(j) * 28, y: sy + 34, width: 16, height: 16))
            }
        }
    }
    return c.makeImage()!
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "sheet" where args.count == 3:
    writePNG(sheetImage(), URL(fileURLWithPath: args[2]))
case "install" where args.count >= 3 && sets[args[2]] != nil:
    let repo = URL(fileURLWithPath: args.count > 3 ? args[3] : FileManager.default.currentDirectoryPath)
    for app in App.allCases {
        let dir = repo.appendingPathComponent("Archive\(app.rawValue)/macOS/Sources/Archive\(app.rawValue)/Assets.xcassets/AppIcon.appiconset")
        guard FileManager.default.fileExists(atPath: dir.path) else { fatalError("no icon set at \(dir.path)") }
        for pt in [16, 32, 128, 256, 512] {
            writePNG(render(args[2], app, px: pt), dir.appendingPathComponent("icon_\(pt)x\(pt).png"))
            writePNG(render(args[2], app, px: pt * 2), dir.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
        }
        print("wrote set \(args[2]) into \(dir.path)")
    }
default:
    FileHandle.standardError.write("usage: make-app-icons.swift sheet <out.png> | install <A|B|C> [repo]\n".data(using: .utf8)!)
    exit(2)
}
