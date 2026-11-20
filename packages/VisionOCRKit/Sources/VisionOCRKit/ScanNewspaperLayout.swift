// ScanNewspaperLayout.swift — newspaper-ocr's DocLayout-YOLO route for scanned newspapers (W47.wh-yolo-scans), the
// detector W46.layout-pair-newspapers measured 4.6 points (1.1 to 8.0) above PP-DocLayoutV3 on the 15 L9 scans. The
// app owns the choice, the kind gate and everything after the regions, as with `NewspaperLayout`, whose `Region` this
// returns. Two steps, each as the measured run took it: newspaper-ocr 0.11.0's default checkpoint (imgsz1280-2501, conf
// 0.2), converted to Core ML (`ops/convert-scan-layout.py`) and run here on the CPU with ultralytics' letterbox and
// selection; then the library's own LayoutProcessor (vendored unchanged, MIT, `npo_layout.py`) and the bench arm's
// region filter, in the shared runtime (`order-scan-newspaper.py`). The weights are AGPL-3.0, so they are a separate
// optional download (owner, call 12), never bundled; nothing of DocLayout-YOLO's code is shipped or run.

import CoreGraphics
import CoreML
import Foundation

public enum ScanNewspaperLayout {
    /// The weights' licence, shown with the download (call 12).
    public static let licence = "AGPL-3.0"
    static let side = 1280
    static let confidence: Float = 0.2

    private static let items: [ModelDownloads.Item] = [.runtime, .scanNewspaperLayout]

    /// Whether both the shared runtime and this detector's model are in place.
    public static func isInstalled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        items.allSatisfy { $0.installed(environment) }
    }

    /// The currently missing downloads in decimal MB, including the shared runtime when it is absent.
    public static var downloadMB: Int { downloadMB(environment: ProcessInfo.processInfo.environment) }

    public static func downloadMB(environment: [String: String]) -> Int {
        let bytes = items.filter { !$0.installed(environment) }.reduce(Int64(0)) { $0 + $1.plan.bytes }
        return Int((Double(bytes) / 1_000_000).rounded(.up))
    }

    /// Fetches and checks the missing pieces, installing each whole.
    public static func download(environment: [String: String] = ProcessInfo.processInfo.environment,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let missing = items.filter { !$0.installed(environment) }
        let total = Double(max(missing.reduce(Int64(0)) { $0 + $1.plan.bytes }, 1))
        var done: Int64 = 0
        for item in missing {
            try Task.checkCancellation()
            let previous = done
            try await ModelDownloads.install(item.plan, home: ModelRuntime.home(environment), source: .current(environment)) {
                progress(min(1, Double(previous + $0) / total))
            }
            done += item.plan.bytes
        }
        progress(1)
    }

    static func modelURL(_ environment: [String: String]) -> URL {
        ModelRuntime.home(environment).appendingPathComponent(ModelDownloads.Item.scanNewspaperLayout.plan.destination)
    }

    private static let lock = NSLock()
    private static var loaded: (path: String, model: MLModel)?

    /// Loaded once a process, on the CPU only, as `LayoutModel` is (Core ML's GPU compiler rejects this graph).
    static func model(_ environment: [String: String]) throws -> MLModel {
        let url = modelURL(environment)
        lock.lock(); defer { lock.unlock() }
        if let loaded, loaded.path == url.path { return loaded.model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            loaded = (url.path, model)
            return model
        } catch {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector could not be loaded (\(error.localizedDescription))")
        }
    }

    /// One detector box as newspaper-ocr's `DocLayoutYoloDetector.detect` makes it: page pixels, truncated and
    /// clipped, the label with its spaces as underscores.
    public struct Detection: Equatable, Codable, Sendable {
        public let label: String
        public let confidence: Float
        public let box: [Int]
    }

    /// cv2's `INTER_LINEAR` resize of one 8-bit channel, as ultralytics' `LetterBox` calls it: cv2's coefficient
    /// tables (11-bit weights, edges clamped) and the arithmetic of its NEON vertical pass.
    static func linearResize(_ src: [UInt8], width w: Int, height h: Int, to dw: Int, _ dh: Int) -> [UInt8] {
        func coefficient(_ v: Float) -> Int32 { Int32((v * 2048).rounded(.toNearestOrEven)) }
        func table(_ s: Int, _ d: Int, clampFraction: Bool) -> [(Int, Int32, Int32)] {
            let scale = 1 / (Double(d) / Double(s))
            return (0..<d).map { i in
                let position = Float((Double(i) + 0.5) * scale - 0.5)
                var p = Int(position.rounded(.down)), f = position - Float(p)
                if clampFraction {
                    if p < 0 { f = 0; p = 0 }
                    if p >= s - 1 { f = 0; p = s - 1 }
                }
                return (p, coefficient(1 - f), coefficient(f))
            }
        }
        let xs = table(w, dw, clampFraction: true), ys = table(h, dh, clampFraction: false)
        func row(_ y: Int) -> [Int32] {
            let base = y * w
            return xs.map { sx, a0, a1 in
                Int32(src[base + sx]) * a0 + (sx + 1 < w ? Int32(src[base + sx + 1]) * a1 : 0)
            }
        }
        var cache: [Int: [Int32]] = [:]
        var dst = [UInt8](repeating: 0, count: dw * dh)
        for (dy, (sy, b0, b1)) in ys.enumerated() {
            let r0 = min(max(sy, 0), h - 1), r1 = min(max(sy + 1, 0), h - 1)
            if cache[r0] == nil { cache[r0] = row(r0) }
            if cache[r1] == nil { cache[r1] = row(r1) }
            if cache.count > 4 { cache = cache.filter { $0.key >= r0 } }
            let s0 = cache[r0]!, s1 = cache[r1]!
            for dx in 0..<dw {
                let v = ((Int32(Int16(truncatingIfNeeded: s0[dx] >> 4)) * b0) >> 16)
                    + ((Int32(Int16(truncatingIfNeeded: s1[dx] >> 4)) * b1) >> 16)
                dst[dy * dw + dx] = UInt8(max(0, min(255, (v + 2) >> 2)))
            }
        }
        return dst
    }

    /// The page's detections: ultralytics' `LetterBox` (auto, stride 32, grey 114, the page RGB), the model, the
    /// one-to-one head's top-300 selection (`LayoutModel.decode`), the 0.2 cut and `scale_boxes`.
    static func detections(of image: CGImage, environment: [String: String]) throws -> [Detection] {
        let model = try model(environment)
        guard let bgr = LayoutModel.channels(of: image) else {
            throw NewspaperLayout.Failure.failed("the page could not be drawn for the scanned-newspaper detector")
        }
        let w = image.width, h = image.height
        let box = LayoutModel.Letterbox.of(width: w, height: h, side: side)
        let rw = Int((Double(w) * box.scale).rounded(.toNearestOrEven)), rh = Int((Double(h) * box.scale).rounded(.toNearestOrEven))
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: box.height), NSNumber(value: box.width)], dataType: .float32)
        let plane = box.width * box.height
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            for i in 0..<(3 * plane) { p[i] = 114 / 255 }
            for (c, src) in [bgr[2], bgr[1], bgr[0]].enumerated() {
                let sized = rw == w && rh == h ? src : linearResize(src, width: w, height: h, to: rw, rh)
                for y in 0..<min(rh, box.height - box.top) {
                    for x in 0..<min(rw, box.width - box.left) {
                        p[c * plane + (y + box.top) * box.width + x + box.left] = Float(sized[y * rw + x]) / 255
                    }
                }
            }
        }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        } catch {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector failed (\(error.localizedDescription))")
        }
        guard let raw = output.featureValue(for: "raw")?.multiArrayValue else {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector wrote no regions")
        }
        var values = [Float](repeating: 0, count: raw.count)
        raw.withUnsafeBufferPointer(ofType: Float.self) { p in
            let n = raw.shape[2].intValue, rs = raw.strides[1].intValue, cs = raw.strides[2].intValue
            for row in 0..<raw.shape[1].intValue { for a in 0..<n { values[row * n + a] = p[row * rs + a * cs] } }
        }
        guard let decoded = LayoutModel.decode(values, width: box.width, height: box.height) else {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector wrote \(values.count) values, not its regions' shape")
        }
        // ultralytics' scale_boxes, from the padded input back to the page; Python's round is half to even.
        let gain = min(Double(box.height) / Double(h), Double(box.width) / Double(w))
        let padX = ((Double(box.width) - Double(w) * gain) / 2 - 0.1).rounded(.toNearestOrEven)
        let padY = ((Double(box.height) - Double(h) * gain) / 2 - 0.1).rounded(.toNearestOrEven)
        return decoded.filter { $0.score > confidence }.compactMap { d in
            func page(_ v: Double, _ pad: Double, _ limit: Int) -> Int {
                Int(min(max((v - pad) / gain, 0), Double(limit)).rounded(.towardZero))
            }
            let x0 = page(d.x0, padX, w), y0 = page(d.y0, padY, h), x1 = page(d.x1, padX, w), y1 = page(d.y1, padY, h)
            guard x1 > x0, y1 > y0 else { return nil }
            return Detection(label: LayoutModel.labels[d.label].replacingOccurrences(of: " ", with: "_"),
                             confidence: d.score, box: [x0, y0, x1, y1])
        }
    }

    static func script(_ environment: [String: String]) -> URL? {
        if let path = environment["VISIONOCR_SCAN_NEWSPAPER_SCRIPT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("order-scan-newspaper.py")
        #if SWIFT_PACKAGE
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return Bundle.module.url(forResource: "order-scan-newspaper", withExtension: "py") ?? bundled
        #else
        return bundled
        #endif
    }

    /// The page's regions in newspaper-ocr's reading order, pictures and nested boxes left out as the measured arm
    /// left them. Synchronous: call off the main thread. The caller reads whole when this throws.
    public static func detect(image: CGImage, memoryGB: Double = 3,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              isCancelled: () -> Bool = { false }) throws -> [NewspaperLayout.Region] {
        try ordered(detections(image: image, environment: environment, isCancelled: isCancelled),
                    width: image.width, height: image.height, memoryGB: memoryGB, environment: environment,
                    isCancelled: isCancelled)
    }

    /// The first step alone, for the parity check (`scan_layout_parity.py`).
    public static func detections(image: CGImage, environment: [String: String] = ProcessInfo.processInfo.environment,
                                  isCancelled: () -> Bool = { false }) throws -> [Detection] {
        assert(!Thread.isMainThread, "ScanNewspaperLayout.detect on the main thread")
        if isCancelled() { throw CancellationError() }
        guard isInstalled(environment) else { throw NewspaperLayout.Failure.notInstalled }
        let found = try detections(of: image, environment: environment)
        if isCancelled() { throw CancellationError() }
        return found
    }

    /// newspaper-ocr's layout processing of `found` and the bench arm's filter, run in the shared runtime.
    public static func ordered(_ found: [Detection], width: Int, height: Int, memoryGB: Double = 3,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               isCancelled: () -> Bool = { false }) throws -> [NewspaperLayout.Region] {
        guard !found.isEmpty else { return [] }
        guard let script = script(environment), FileManager.default.fileExists(atPath: script.path) else {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector's script is not in this build")
        }
        struct Input: Encodable { let width: Int, height: Int, detections: [Detection] }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("visionocr-scan-newspaper-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("detections.json"), out = dir.appendingPathComponent("regions.json")
        try JSONEncoder().encode(Input(width: width, height: height, detections: found)).write(to: inURL)
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"]
        for key in ["HOME", "TMPDIR"] { env[key] = environment[key] }
        let command = NewspaperLayout.Command(
            executable: ModelRuntime.home(environment).appendingPathComponent("Runtime/bin/python3"),
            arguments: ["-I", script.path, inURL.path, out.path], environment: env)
        try NewspaperLayout.run(command, memoryGB: memoryGB, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        guard let data = try? Data(contentsOf: out) else { throw NewspaperLayout.Failure.failed("the scanned-newspaper detector wrote nothing") }
        return try decode(data)
    }

    /// The script's regions, in its order; a malformed reply is a failed page, a degenerate box is skipped.
    static func decode(_ data: Data) throws -> [NewspaperLayout.Region] {
        struct Row: Decodable { let label: String; let score: Double; let box: [Double] }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw NewspaperLayout.Failure.failed("the scanned-newspaper detector's output could not be read")
        }
        return rows.enumerated().compactMap { i, row in
            guard row.box.count == 4, row.box.allSatisfy(\.isFinite), row.score.isFinite else { return nil }
            let x0 = max(0, row.box[0]), y0 = max(0, row.box[1]), x1 = min(1, row.box[2]), y1 = min(1, row.box[3])
            guard x1 > x0, y1 > y0 else { return nil }
            return NewspaperLayout.Region(box: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                                          order: i + 1, label: row.label, score: row.score)
        }
    }
}
