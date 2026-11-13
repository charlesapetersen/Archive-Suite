import CoreGraphics
import Foundation

// MARK: - Improve OCR: proving a candidate kept the original (W44.reocr-processor)

/// Checks a re-read candidate against the file it replaces, independently of whatever wrote it
/// (`execution-plans/reocr/00-plan.md` §5). A candidate passes only when:
///
/// 1. it holds the entire original byte for byte as its prefix, followed by an incremental revision;
/// 2. both open, neither is encrypted, and they have the same number of pages;
/// 3. every page not being replaced has the same **active** object graph as before, read through Quartz with every
///    indirect reference resolved: the same dictionaries, arrays, names, numbers and strings, and every stream's
///    encoded bytes and dictionary, with the page-tree link `/Parent` the only key left out. A later revision that
///    overrides an original object therefore fails even though the prefix is intact;
/// 4. the same pages report the same boxes and rotation and render to the same pixels;
/// 5. the catalog is unchanged apart from its `/Pages` link.
///
/// The pages being replaced are checked by the caller against the new text. Empty `problems` means the candidate
/// may go to review; any problem stops publication.
enum ReOCRPreservationCheck {
    static func problems(original: Data, candidate: Data, replacing: Set<Int>) -> [String] {
        var out: [String] = []
        guard candidate.count > original.count, candidate.prefix(original.count) == original else {
            return ["the candidate does not begin with the original file byte for byte"]
        }
        guard let oldDoc = document(original), let newDoc = document(candidate) else {
            return ["the original or the candidate does not open as a PDF"]
        }
        if oldDoc.isEncrypted || newDoc.isEncrypted { return ["an encrypted PDF cannot be checked"] }
        guard oldDoc.numberOfPages == newDoc.numberOfPages else {
            return ["the page count changed from \(oldDoc.numberOfPages) to \(newDoc.numberOfPages)"]
        }
        // Only the page tree may change at document level: the catalog's other entries (actions, forms, optional
        // content, outlines, metadata) must be the same objects as before.
        if let ca = oldDoc.catalog, let cb = newDoc.catalog {
            var compare = GraphCompare()
            if let diff = compare.dictionaries(ca, cb, path: "catalog", skip: ["Pages"]) { out.append(diff) }
        } else {
            out.append("the catalog cannot be read")
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
            var compare = GraphCompare()
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
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
            where a.getBoxRect(box) != b.getBoxRect(box) {
                out.append("page \(i + 1): its \(box) changed")
            }
            if a.rotationAngle != b.rotationAngle { out.append("page \(i + 1): its rotation changed") }
            if render(a) != render(b) { out.append("page \(i + 1): it renders differently") }
        }
        return out
    }

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// The page drawn into an RGBA bitmap at up to 600 px on its long side; nil when it cannot be drawn.
    static func render(_ page: CGPDFPage) -> Data? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, 600 / max(box.width, box.height))
        let w = max(1, Int((box.width * scale).rounded())), h = max(1, Int((box.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: box.size), rotate: 0,
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
        private var seen = Set<[Int]>()

        mutating func dictionaries(_ a: CGPDFDictionaryRef, _ b: CGPDFDictionaryRef, path: String,
                                   skip: Set<String> = [], depth: Int = 0) -> String? {
            if depth > Self.maxDepth { return "\(path): too deep to check" }
            guard seen.insert([unsafeBitCast(a, to: Int.self), unsafeBitCast(b, to: Int.self)]).inserted else { return nil }
            let ka = keys(a).subtracting(skip).subtracting(Self.pageTreeLink)
            let kb = keys(b).subtracting(skip).subtracting(Self.pageTreeLink)
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
                return x == y ? nil : "\(path): changed"
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

        private func keys(_ d: CGPDFDictionaryRef) -> Set<String> {
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
