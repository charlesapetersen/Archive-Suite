// makeicon.swift — regenerates the Archive Processor app icon (and, on request, its sibling).
//
// Archive Processor and Archive Reader ship as a coordinated, deliberately-distinguishable PAIR
// so they are never confused in the macOS app switcher / Dock:
//   • Processor = cool BLUE tile + manila folder + magnifying glass (OCR / scan)
//   • Reader    = warm AMBER tile + espresso folder + reading glasses (read / triage)
// Both are drawn from the SAME code below (only the palette + tool differ) so the pair never
// drifts. Pure CoreGraphics + ImageIO — no SVG rasterizer / Pillow / ImageMagick required.
//
// Regenerate THIS app's icon (writes all 10 sizes straight into the AppIcon.appiconset):
//   swift scripts/makeicon.swift
// Render the sibling or a one-off preview:
//   swift scripts/makeicon.swift reader /path/to/AppIcon.appiconset   # all sizes into a dir
//   swift scripts/makeicon.swift processor 512 /tmp/preview.png       # single size → file
// Then rebuild so the .app picks it up:  cd ArchiveProcessor && xcodegen generate && xcodebuild …
//
// This repo's default when run with no arguments:
let defaultKind = "processor"

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r/255), CGFloat(g/255), CGFloat(b/255), CGFloat(a)])!
}

struct Palette {
    let tileTop: CGColor, tileBottom: CGColor
    let folderBack: CGColor, folderFront: CGColor, tab: CGColor
    let page: CGColor, line: CGColor
    let toolMain: CGColor, toolAccent: CGColor
}

// Processor = cool BLUE tile, warm manila folder, magnifying glass (OCR / scan)
let processor = Palette(
    tileTop:    rgb(91, 124, 250),
    tileBottom: rgb(36,  64, 176),
    folderBack: rgb(236, 210, 150),
    folderFront:rgb(216, 184, 116),
    tab:        rgb(224, 196, 132),
    page:       rgb(255, 255, 255),
    line:       rgb(150, 164, 190),
    toolMain:   rgb(255, 255, 255),
    toolAccent: rgb(219, 231, 252, 0.9)
)

// Reader = warm AMBER tile, espresso folder, reading glasses (read / triage)
let reader = Palette(
    tileTop:    rgb(247, 186, 66),
    tileBottom: rgb(214, 102, 18),
    folderBack: rgb(96,  68, 46),
    folderFront:rgb(74,  50, 32),
    tab:        rgb(108, 78, 54),
    page:       rgb(248, 240, 222),
    line:       rgb(176, 142, 100),
    toolMain:   rgb(46,  32, 20),
    toolAccent: rgb(255, 255, 255, 0.16)
)

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func fill(_ ctx: CGContext, _ path: CGPath, _ c: CGColor) {
    ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath()
}
func withShadow(_ ctx: CGContext, dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: rgb(0, 0, 0, alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func drawPage(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, angleDeg: CGFloat, p: Palette) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: angleDeg * .pi / 180)
    fill(ctx, rr(-w/2, -h/2, w, h, 22), p.page)
    ctx.setFillColor(p.line)
    let left = -w/2 + 36
    let lineW = w - 72
    let startY = -h/2 + 62
    let gap: CGFloat = 46
    let lineH: CGFloat = 16
    for i in 0..<6 {
        let yy = startY + CGFloat(i) * gap
        let ww = (i == 5) ? lineW * 0.55 : lineW
        ctx.addPath(rr(left, yy, ww, lineH, 8)); ctx.fillPath()
    }
    ctx.restoreGState()
}

func drawMagnifier(_ ctx: CGContext, p: Palette) {
    let cx: CGFloat = 712, cy: CGFloat = 704, outer: CGFloat = 108, stroke: CGFloat = 40
    let d: CGFloat = 0.70710678
    let start = CGPoint(x: cx + (outer - 4) * d, y: cy + (outer - 4) * d)
    let end = CGPoint(x: start.x + 118 * d, y: start.y + 118 * d)
    // handle
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(48)
    ctx.setStrokeColor(p.toolMain)
    ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
    ctx.restoreGState()
    // glass fill
    let inner = outer - stroke
    fill(ctx, CGPath(ellipseIn: CGRect(x: cx - inner, y: cy - inner, width: inner*2, height: inner*2), transform: nil), p.toolAccent)
    // ring
    let ringR = outer - stroke/2
    ctx.saveGState()
    ctx.setLineWidth(stroke)
    ctx.setStrokeColor(p.toolMain)
    ctx.addEllipse(in: CGRect(x: cx - ringR, y: cy - ringR, width: ringR*2, height: ringR*2))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawGlasses(_ ctx: CGContext, p: Palette) {
    let cyL: CGFloat = 724
    let lx: CGFloat = 646, rx: CGFloat = 806
    let outer: CGFloat = 80, stroke: CGFloat = 30
    let inner = outer - stroke
    // lens tint
    for cx in [lx, rx] {
        fill(ctx, CGPath(ellipseIn: CGRect(x: cx - inner, y: cyL - inner, width: inner*2, height: inner*2), transform: nil), p.toolAccent)
    }
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(stroke)
    ctx.setStrokeColor(p.toolMain)
    let ringR = outer - stroke/2
    // lenses
    for cx in [lx, rx] {
        ctx.addEllipse(in: CGRect(x: cx - ringR, y: cyL - ringR, width: ringR*2, height: ringR*2))
        ctx.strokePath()
    }
    // bridge (bowed up)
    ctx.move(to: CGPoint(x: lx + ringR - 6, y: cyL - 8))
    ctx.addQuadCurve(to: CGPoint(x: rx - ringR + 6, y: cyL - 8), control: CGPoint(x: (lx + rx)/2, y: cyL - 46))
    ctx.strokePath()
    // temple arms
    ctx.move(to: CGPoint(x: lx - ringR + 8, y: cyL - 22)); ctx.addLine(to: CGPoint(x: lx - ringR - 54, y: cyL - 50)); ctx.strokePath()
    ctx.move(to: CGPoint(x: rx + ringR - 8, y: cyL - 22)); ctx.addLine(to: CGPoint(x: rx + ringR + 54, y: cyL - 50)); ctx.strokePath()
    ctx.restoreGState()
}

func draw(_ ctx: CGContext, size: CGFloat, kind: String, _ p: Palette) {
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let s = size / 1024
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: s, y: s)

    // tile
    let tile = rr(100, 100, 824, 824, 184)
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [p.tileTop, p.tileBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // soft top highlight
    let hl = CGGradient(colorsSpace: cs, colors: [rgb(255,255,255,0.16), rgb(255,255,255,0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    ctx.restoreGState()

    // folder back + tab (behind pages)
    withShadow(ctx, dy: 14, blur: 34, alpha: 0.30) {
        fill(ctx, rr(250, 392, 214, 84, 34), p.tab)
        fill(ctx, rr(250, 430, 524, 350, 46), p.folderBack)
    }
    // pages
    withShadow(ctx, dy: 10, blur: 24, alpha: 0.18) {
        drawPage(ctx, cx: 452, cy: 378, w: 300, h: 378, angleDeg: -7, p: p)
        drawPage(ctx, cx: 592, cy: 366, w: 300, h: 378, angleDeg: 6, p: p)
    }
    // folder front pocket (in front of pages)
    withShadow(ctx, dy: 8, blur: 20, alpha: 0.20) {
        fill(ctx, rr(234, 486, 556, 316, 52), p.folderFront)
    }
    // tool
    withShadow(ctx, dy: 10, blur: 22, alpha: 0.30) {
        if kind == "processor" { drawMagnifier(ctx, p: p) } else { drawGlasses(ctx, p: p) }
    }
}

func render(kind: String, size: Int, path: String, _ p: Palette) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, size: CGFloat(size), kind: kind, p)
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// The 10 sizes an Xcode macOS AppIcon.appiconset expects.
let sizeMap: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

// This repo's own AppIcon.appiconset, resolved relative to THIS script file (repoRoot = ../).
func defaultAppiconset(for kind: String) -> String {
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
    let sub = (kind == "processor")
        ? "ArchiveProcessor/Sources/ArchiveProcessor/Assets.xcassets/AppIcon.appiconset"
        : "ArchiveReader/Sources/ArchiveReader/Assets.xcassets/AppIcon.appiconset"
    return "\(repoRoot)/\(sub)"
}

func palette(for kind: String) -> Palette { kind == "processor" ? processor : reader }

func writeAll(kind: String, into dir: String) {
    let p = palette(for: kind)
    for (name, px) in sizeMap { render(kind: kind, size: px, path: "\(dir)/\(name)", p) }
    print("wrote 10 sizes for \(kind) → \(dir)")
}

// ---- CLI ----
let args = CommandLine.arguments
switch args.count {
case 1:
    // No args: regenerate this repo's own icon into its appiconset.
    writeAll(kind: defaultKind, into: defaultAppiconset(for: defaultKind))
case 2:
    // <kind>: regenerate that app's icon; only valid when its appiconset lives in this repo.
    let kind = args[1]
    if kind == defaultKind { writeAll(kind: kind, into: defaultAppiconset(for: kind)) }
    else { FileHandle.standardError.write("This repo holds the \(defaultKind) appiconset; pass an explicit outDir to render \(kind).\n".data(using: .utf8)!); exit(2) }
case 3 where Int(args[1]) == nil:
    // <kind> <outDir>: all sizes into an explicit directory.
    writeAll(kind: args[1], into: args[2])
case 4 where Int(args[2]) != nil:
    // <kind> <size> <file>: a single-size preview.
    render(kind: args[1], size: Int(args[2])!, path: args[3], palette(for: args[1]))
    print("wrote \(args[2])px \(args[1]) → \(args[3])")
default:
    FileHandle.standardError.write("usage: swift makeicon.swift [processor|reader] [outDir | <size> <file>]\n".data(using: .utf8)!); exit(1)
}
