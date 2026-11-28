import CoreGraphics
import Foundation

// MARK: - Improve OCR: proving a candidate kept the original (W44.reocr-processor)

/// Checks a re-read candidate against the file it replaces, independently of whatever wrote it
/// (`SPEC/improve-ocr.md` §5). A candidate passes only when:
///
/// 1. an incremental candidate holds the entire original byte for byte as its prefix;
/// 2. both open, neither is encrypted, and they have the same number of pages;
/// 3. every page not being replaced has the same **active** object graph as before, read through Quartz with every
///    indirect reference resolved: the same dictionaries, arrays, names, numbers and strings, and every stream's
///    encoded bytes and dictionary, with the page-tree link `/Parent` the only key left out. A later revision that
///    overrides an original object therefore fails even though the prefix is intact;
/// 4. the same pages report the same boxes and rotation and render to the same pixels;
/// 5. the catalog is unchanged apart from its `/Pages` link, and the document information dictionary is unchanged
///    apart from `/Producer` naming the editor.
///
/// The pages being replaced are checked by the caller against the new text. Empty `problems` means the candidate
/// may go to review; any problem stops publication.
enum ReOCRPreservationCheck {
    static func problems(original: Data, candidate: Data, replacing: Set<Int>, editingLayers: Set<Int> = [],
                         requiresOriginalPrefix: Bool = true, catalogueMetadata: Data? = nil) -> [String] {
        var out: [String] = []
        if requiresOriginalPrefix && (candidate.count <= original.count || candidate.prefix(original.count) != original) {
            return ["the candidate does not begin with the original file byte for byte"]
        }
        guard let oldDoc = document(original), let newDoc = document(candidate) else {
            return ["the original or the candidate does not open as a PDF"]
        }
        defer { withExtendedLifetime((oldDoc, newDoc)) {} }
        if oldDoc.isEncrypted || newDoc.isEncrypted { return ["an encrypted PDF cannot be checked"] }
        guard oldDoc.numberOfPages == newDoc.numberOfPages else {
            return ["the page count changed from \(oldDoc.numberOfPages) to \(newDoc.numberOfPages)"]
        }
        // An outline, link or annotation can lead back to an edited page. Give the same narrow exception there,
        // and only for the exact corresponding page dictionaries.
        let layerPages = editingLayers.compactMap { i -> [Int]? in
            guard let old = oldDoc.page(at: i + 1)?.dictionary, let new = newDoc.page(at: i + 1)?.dictionary else { return nil }
            return [unsafeBitCast(old, to: Int.self), unsafeBitCast(new, to: Int.self)]
        }
        let layerDictionaries = Set(layerPages)
        // Improve OCR may change the page tree. Preparing a catalogue derivative instead allows only
        // the verified XMP packet to change, and compares the complete active page tree.
        if let ca = oldDoc.catalog, let cb = newDoc.catalog {
            var compare = GraphCompare(layerPages: layerDictionaries, compareParentLinks: catalogueMetadata != nil)
            let skipped: Set<String> = catalogueMetadata == nil ? ["Pages"] : ["Metadata"]
            if let diff = compare.dictionaries(ca, cb, path: "catalog", skip: skipped) { out.append(diff) }
            if let catalogueMetadata, metadata(of: newDoc) != catalogueMetadata {
                out.append("catalog/Metadata: the intended XMP did not read back exactly")
            }
        } else {
            out.append("the catalog cannot be read")
        }
        // The document information dictionary (title, author, dates) is not the revision's to change either, with one
        // measured exception: PDFium's page import sets `/Producer` to "PDFium" whenever it adds a page (2026-11-12,
        // pdfium-lib 8046d), as an editor that saves a file does. That value, and only it, is allowed.
        switch (oldDoc.info, newDoc.info) {
        case (nil, nil): break
        case let (ia?, ib?):
            var compare = GraphCompare(layerPages: layerDictionaries, compareParentLinks: catalogueMetadata != nil)
            let skipped: Set<String> = catalogueMetadata == nil ? ["Producer"] : []
            if let diff = compare.dictionaries(ia, ib, path: "document information", skip: skipped) {
                out.append(diff)
            }
            let pa = Self.text(ia, "Producer"), pb = Self.text(ib, "Producer")
            if pa != pb && pb != Data(Self.editorProducer.utf8) {
                out.append("document information/Producer: changed to something other than \(Self.editorProducer)")
            }
        default: out.append("the document information dictionary was added or removed")
        }
        let count = oldDoc.numberOfPages
        if let bad = replacing.first(where: { $0 < 0 || $0 >= count }) {
            return ["page \(bad + 1) to replace is not in the file"]
        }
        for i in 0..<count where !replacing.contains(i) {
            guard let a = oldDoc.page(at: i + 1), let b = newDoc.page(at: i + 1),
                  let da = a.dictionary, let db = b.dictionary else {
                out.append("page \(i + 1) cannot be read")
                continue
            }
            var compare = GraphCompare(layerPages: layerDictionaries)
            if let diff = compare.dictionaries(da, db, path: "page \(i + 1)") {
                out.append(diff)
                continue
            }
            // `/Parent` is left out above, so what the page inherits through it is compared here: the nearest
            // ancestor's value for each inheritable key the page itself lacks.
            if let diff = compare.inherited(da, db, path: "page \(i + 1)") {
                out.append(diff)
                continue
            }
            if editingLayers.contains(i), let diff = compare.layerResources(da, db, path: "page \(i + 1)") {
                out.append(diff)
            }
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
            where !sameRect(a.getBoxRect(box), b.getBoxRect(box)) {
                out.append("page \(i + 1): its \(box) changed")
            }
            if a.rotationAngle != b.rotationAngle { out.append("page \(i + 1): its rotation changed") }
            if editingLayers.contains(i) {
                let boxes: [CGPDFBox] = a.getBoxRect(.cropBox) == a.getBoxRect(.mediaBox) ? [.cropBox] : [.cropBox, .mediaBox]
                for box in boxes {
                    if let before = render(a, box: box), before == render(b, box: box) { continue }
                    out.append("page \(i + 1): its \(box) could not be verified to render identically")
                }
            } else if catalogueMetadata != nil {
                if let before = render(a), before == render(b) { continue }
                out.append("page \(i + 1): it could not be verified to render identically")
            } else if render(a) != render(b) {
                out.append("page \(i + 1): it renders differently")
            }
        }
        return out
    }

    /// Whether `got` is the page `want`, moved: the same graph apart from the page-tree link, the same effective
    /// inheritable attributes wherever they are held, the same boxes, rotation and pixels. For a replaced page, which
    /// comes from another document; nil when it is the same.
    static func samePage(_ want: CGPDFPage, _ got: CGPDFPage, path: String) -> String? {
        guard let da = want.dictionary, let db = got.dictionary else { return "\(path): cannot be read" }
        var compare = GraphCompare()
        if let diff = compare.dictionaries(da, db, path: path, skip: Set(GraphCompare.inheritable)) { return diff }
        if let diff = compare.effective(da, db, path: path) { return diff }
        for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        where !sameRect(want.getBoxRect(box), got.getBoxRect(box)) {
            return "\(path): its \(box) differs"
        }
        if want.rotationAngle != got.rotationAngle { return "\(path): its rotation differs" }
        if render(want) != render(got) { return "\(path): it renders differently" }
        return nil
    }

    /// Whether two reals Quartz read are the same written number. Quartz reads one number to different doubles
    /// depending on the byte after it: `636.05]` and `636.05 ]` differ in the last bits, and qpdf writes arrays with
    /// spaces, so an unchanged box in a real archive PDF read as changed (W49.storage-pilot: 15 of 55). Values that
    /// agree to one part in 10^9 are that number; any edit a writer makes changes far more, and pixels are still compared.
    static func sameReal(_ x: CGFloat, _ y: CGFloat) -> Bool {
        guard x.isFinite, y.isFinite else { return x == y }   // an infinite bound would accept any number
        return x == y || abs(x - y) <= 1e-9 * max(1, abs(x), abs(y))
    }

    static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        sameReal(a.origin.x, b.origin.x) && sameReal(a.origin.y, b.origin.y)
            && sameReal(a.width, b.width) && sameReal(a.height, b.height)
    }

    /// The one value a revision may give the information dictionary's `/Producer` (see `problems`).
    static let editorProducer = "PDFium"

    static func metadata(of document: CGPDFDocument, requireKnownStreamKeys: Bool = false) -> Data? {
        var stream: CGPDFStreamRef?
        guard let catalog = document.catalog,
              CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        if requireKnownStreamKeys {
            guard let dictionary = CGPDFStreamGetDictionary(stream),
                  GraphCompare().keys(dictionary).isSubset(of: ["Type", "Subtype", "Length", "Filter", "DecodeParms"])
            else { return nil }
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return data as Data
    }

    private static func text(_ d: CGPDFDictionaryRef, _ key: String) -> Data? {
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s, let p = CGPDFStringGetBytePtr(s) else { return nil }
        return Data(bytes: p, count: CGPDFStringGetLength(s))
    }

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// The page drawn into an RGBA bitmap at up to 600 px on its long side; nil when it cannot be drawn.
    static func render(_ page: CGPDFPage) -> Data? { render(page, box: .cropBox) }

    static func render(_ page: CGPDFPage, box: CGPDFBox) -> Data? {
        let rect = page.getBoxRect(box)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        let size = page.rotationAngle % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
        let scale = min(1, 600 / max(size.width, size.height))
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(box, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let bytes = ctx.data else { return nil }
        return Data(bytes: bytes, count: w * h * 4)
    }

    /// A walk over two object graphs at once. Pairs already being compared are taken as equal, which ends a cycle
    /// (an annotation's `/P` back to its page); a graph deeper than `maxDepth` is a problem, not a pass. `/Parent` is
    /// left out at every depth: it leads into the page tree, which is the one thing allowed to change, and every kept
    /// page is compared on its own (a destination or outline entry that names a page reaches it through here too).
    struct GraphCompare {
        static let maxDepth = 64
        static let pageTreeLink: Set<String> = ["Parent"]
        let layerPages: Set<[Int]>
        let compareParentLinks: Bool
        private var seen = Set<[Int]>()

        init(layerPages: Set<[Int]> = [], compareParentLinks: Bool = false) {
            self.layerPages = layerPages
            self.compareParentLinks = compareParentLinks
        }

        mutating func dictionaries(_ a: CGPDFDictionaryRef, _ b: CGPDFDictionaryRef, path: String,
                                   skip: Set<String> = [], depth: Int = 0) -> String? {
            if depth > Self.maxDepth { return "\(path): too deep to check" }
            let pair = [unsafeBitCast(a, to: Int.self), unsafeBitCast(b, to: Int.self)]
            guard seen.insert(pair).inserted else { return nil }
            // PDFium writes geometry numbers without trailing decimal zeroes. The page loop compares all of the
            // effective boxes and the rotation independently of that storage representation.
            let excluded = layerPages.contains(pair)
                ? skip.union(["Contents", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate"])
                : skip
            let skipped = compareParentLinks ? excluded : excluded.union(Self.pageTreeLink)
            let ka = keys(a).subtracting(skipped)
            let kb = keys(b).subtracting(skipped)
            if ka != kb { return "\(path): its keys changed (\(ka.symmetricDifference(kb).sorted().joined(separator: ", ")))" }
            for key in ka.sorted() {
                var oa: CGPDFObjectRef?, ob: CGPDFObjectRef?
                guard CGPDFDictionaryGetObject(a, key, &oa), CGPDFDictionaryGetObject(b, key, &ob),
                      let oa, let ob else { return "\(path)/\(key): cannot be read" }
                if let d = objects(oa, ob, path: "\(path)/\(key)", depth: depth + 1) { return d }
            }
            return nil
        }

        mutating func objects(_ a: CGPDFObjectRef, _ b: CGPDFObjectRef, path: String, depth: Int) -> String? {
            let ta = CGPDFObjectGetType(a), tb = CGPDFObjectGetType(b)
            guard ta == tb else { return "\(path): its type changed" }
            switch ta {
            case .null: return nil
            case .boolean:
                var x: CGPDFBoolean = 0, y: CGPDFBoolean = 0
                _ = CGPDFObjectGetValue(a, .boolean, &x); _ = CGPDFObjectGetValue(b, .boolean, &y)
                return x == y ? nil : "\(path): changed"
            case .integer:
                var x: CGPDFInteger = 0, y: CGPDFInteger = 0
                _ = CGPDFObjectGetValue(a, .integer, &x); _ = CGPDFObjectGetValue(b, .integer, &y)
                return x == y ? nil : "\(path): changed"
            case .real:
                var x: CGPDFReal = 0, y: CGPDFReal = 0
                _ = CGPDFObjectGetValue(a, .real, &x); _ = CGPDFObjectGetValue(b, .real, &y)
                return ReOCRPreservationCheck.sameReal(x, y) ? nil : "\(path): changed"
            case .name:
                var x: UnsafePointer<CChar>?, y: UnsafePointer<CChar>?
                _ = CGPDFObjectGetValue(a, .name, &x); _ = CGPDFObjectGetValue(b, .name, &y)
                guard let x, let y else { return "\(path): cannot be read" }
                return strcmp(x, y) == 0 ? nil : "\(path): changed"
            case .string:
                var x: CGPDFStringRef?, y: CGPDFStringRef?
                _ = CGPDFObjectGetValue(a, .string, &x); _ = CGPDFObjectGetValue(b, .string, &y)
                guard let x, let y else { return "\(path): cannot be read" }
                return bytes(x) == bytes(y) ? nil : "\(path): changed"
            case .array:
                var x: CGPDFArrayRef?, y: CGPDFArrayRef?
                _ = CGPDFObjectGetValue(a, .array, &x); _ = CGPDFObjectGetValue(b, .array, &y)
                guard let x, let y else { return "\(path): cannot be read" }
                if depth > Self.maxDepth { return "\(path): too deep to check" }
                guard CGPDFArrayGetCount(x) == CGPDFArrayGetCount(y) else { return "\(path): its length changed" }
                for i in 0..<CGPDFArrayGetCount(x) {
                    var ea: CGPDFObjectRef?, eb: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(x, i, &ea), CGPDFArrayGetObject(y, i, &eb), let ea, let eb else {
                        return "\(path)[\(i)]: cannot be read"
                    }
                    if let d = objects(ea, eb, path: "\(path)[\(i)]", depth: depth + 1) { return d }
                }
                return nil
            case .dictionary:
                var x: CGPDFDictionaryRef?, y: CGPDFDictionaryRef?
                _ = CGPDFObjectGetValue(a, .dictionary, &x); _ = CGPDFObjectGetValue(b, .dictionary, &y)
                guard let x, let y else { return "\(path): cannot be read" }
                return dictionaries(x, y, path: path, depth: depth)
            case .stream:
                var x: CGPDFStreamRef?, y: CGPDFStreamRef?
                _ = CGPDFObjectGetValue(a, .stream, &x); _ = CGPDFObjectGetValue(b, .stream, &y)
                guard let x, let y else { return "\(path): cannot be read" }
                // The encoded bytes as stored, not a decoded copy: a recompressed image fails here.
                var fa = CGPDFDataFormat.raw, fb = CGPDFDataFormat.raw
                let ba = CGPDFStreamCopyData(x, &fa) as Data?, bb = CGPDFStreamCopyData(y, &fb) as Data?
                guard let ba, let bb else { return "\(path): its stream cannot be read" }
                if fa != fb || ba != bb { return "\(path): its stream bytes changed" }
                guard let sa = CGPDFStreamGetDictionary(x), let sb = CGPDFStreamGetDictionary(y) else {
                    return "\(path): its stream dictionary cannot be read"
                }
                return dictionaries(sa, sb, path: path, depth: depth)
            @unknown default:
                return "\(path): an object of an unknown type"
            }
        }

        static let inheritable = ["Resources", "MediaBox", "CropBox", "Rotate"]

        mutating func inherited(_ a: CGPDFDictionaryRef, _ b: CGPDFDictionaryRef, path: String) -> String? {
            for key in Self.inheritable where !keys(a).contains(key) {
                if layerPages.contains([unsafeBitCast(a, to: Int.self), unsafeBitCast(b, to: Int.self)]) { continue }
                let oa = ancestorValue(a, key), ob = ancestorValue(b, key)
                switch (oa, ob) {
                case (nil, nil): continue
                case let (x?, y?):
                    if let d = objects(x, y, path: "\(path) (inherited)/\(key)", depth: 1) { return d }
                default: return "\(path): its inherited \(key) changed"
                }
            }
            return nil
        }

        /// Each inheritable key's effective value, the page's own or else its nearest ancestor's, compared whether it
        /// is held by the page or inherited: a page moved into another tree may carry what it used to inherit.
        mutating func effective(_ a: CGPDFDictionaryRef, _ b: CGPDFDictionaryRef, path: String) -> String? {
            for key in Self.inheritable {
                var own: CGPDFObjectRef?
                let oa = CGPDFDictionaryGetObject(a, key, &own) ? own : ancestorValue(a, key)
                let ob = CGPDFDictionaryGetObject(b, key, &own) ? own : ancestorValue(b, key)
                switch (oa, ob) {
                case (nil, nil): continue
                case let (x?, y?):
                    if let d = objects(x, y, path: "\(path)/\(key)", depth: 1) { return d }
                default: return "\(path): its \(key) changed"
                }
            }
            return nil
        }

        /// Layer edits may change fonts and form entries. Verify that original image streams and other appearance
        /// resources survive, independently of the bitmap comparison.
        mutating func layerResources(_ a: CGPDFDictionaryRef, _ b: CGPDFDictionaryRef, path: String) -> String? {
            func resources(_ d: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
                var own: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(d, "Resources", &own) { return own }
                guard let inherited = ancestorValue(d, "Resources"),
                      CGPDFObjectGetValue(inherited, .dictionary, &own) else { return nil }
                return own
            }
            guard let after = resources(b) else { return "\(path): its updated resources cannot be read" }
            guard let before = resources(a) else {
                guard let newObjects = resourcesForLayerCheck(after), newObjects.images.isEmpty else {
                    return "\(path): its image resources changed"
                }
                return nil
            }
            if let diff = dictionaries(before, after, path: "\(path)/Resources", skip: ["Font", "XObject", "ExtGState", "ProcSet"]) {
                return diff
            }
            guard let oldObjects = resourcesForLayerCheck(before), let newObjects = resourcesForLayerCheck(after) else {
                return "\(path): its image and font resources could not be checked"
            }
            if oldObjects.hasType3 {
                return "\(path): a Type 3 font can paint even in an invisible text object"
            }
            guard oldObjects.images.count == newObjects.images.count else { return "\(path): its image resources changed" }
            var remaining = newObjects.images
            for old in oldObjects.images {
                guard let index = remaining.firstIndex(where: { new in
                    var check = GraphCompare()
                    return check.objects(old, new, path: path, depth: 0) == nil
                }) else { return "\(path): an original image stream or its dictionary changed" }
                remaining.remove(at: index)
            }
            return nil
        }

        private func resourcesForLayerCheck(_ resources: CGPDFDictionaryRef, depth: Int = 0)
            -> (images: [CGPDFObjectRef], hasType3: Bool)? {
            guard depth < Self.maxDepth else { return nil }
            var hasType3 = false
            var fonts: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
                for name in keys(fonts) {
                    var font: CGPDFDictionaryRef?
                    var subtype: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetDictionary(fonts, name, &font), let font,
                          CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype else { return nil }
                    if String(cString: subtype) == "Type3" { hasType3 = true }
                }
            }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return ([], hasType3) }
            var result: [CGPDFObjectRef] = []
            for name in keys(xObjects) {
                var object: CGPDFObjectRef?
                var stream: CGPDFStreamRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetObject(xObjects, name, &object), let object,
                      CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream),
                      CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return nil }
                if String(cString: subtype) == "Image" { result.append(object) }
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    guard let found = resourcesForLayerCheck(nested, depth: depth + 1) else { return nil }
                    result.append(contentsOf: found.images)
                    hasType3 = hasType3 || found.hasType3
                }
            }
            return (result, hasType3)
        }

        /// The nearest ancestor's `key`, following `/Parent` at most `maxDepth` times.
        private func ancestorValue(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            var node = d
            for _ in 0..<Self.maxDepth {
                var parent: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else { return nil }
                var o: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(parent, key, &o), let o { return o }
                node = parent
            }
            return nil
        }

        fileprivate func keys(_ d: CGPDFDictionaryRef) -> Set<String> {
            final class Box { var keys = Set<String>() }
            let box = Box()
            CGPDFDictionaryApplyBlock(d, { key, _, info in
                Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().keys.insert(String(cString: key))
                return true
            }, Unmanaged.passUnretained(box).toOpaque())
            return box.keys
        }

        private func bytes(_ s: CGPDFStringRef) -> Data {
            guard let p = CGPDFStringGetBytePtr(s) else { return Data() }
            return Data(bytes: p, count: CGPDFStringGetLength(s))
        }
    }
}
