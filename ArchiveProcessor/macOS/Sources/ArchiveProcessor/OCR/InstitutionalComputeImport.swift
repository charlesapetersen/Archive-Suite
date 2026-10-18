import CryptoKit
import Foundation

/// W41.app-institutional-compute — take in the text an institutional-computing bulk run already read (`scripts/segbench/institutional-compute/README.md`
/// §Bulk), so a page the cluster answered is not bought again from the run's model.
///
/// A bulk run's output folder holds `<image>.txt` per answered page and `_meta/<image>.json` beside it; since this
/// item the kit writes the cluster's display name (`cluster`) into each `_meta`, with the input image's SHA-256,
/// the model, its preset and vLLM arguments
/// (the precision) and the Slurm job. A page is matched by the SHA-256 of the file the run is about to read, never
/// by its name: the bulk tree's paths are the cluster's, two boxes reuse names like `001.jpg`, and a name match could
/// put one photo's text under another. A `_meta` without a hash (a run from before this kit change, or the
/// pilot's neutral-named renders, which are not the corpus files' bytes anyway) matches nothing.
///
/// What a match gives the page: the cluster's text, its reader in the PDF header's provider/model positions
/// (`<cluster> · <model> (<precision>, job <id>)`, `SPEC/tag-format.md`), rotation 0 (the cluster read the file as
/// stored, and asking the run's provider for the rotation would be a paid call), and — because the panel prompt
/// the cluster reads with returns no document-start/continuation label — a text-only classification by the run's own
/// model, as the Apple Vision hybrid does. A page with no match (escalated, failed, never read, or not in the
/// folder) is read by the run's model as usual: the run's cost estimate already counts every page, so falling
/// through never spends more than the estimate said.
///
/// Read only: nothing here writes into the cluster folder or the input images. Applies where the page readers
/// do (a direct-provider, non-batch Process Files run); frozen with the run, and a resumed run reloads the folder.
struct InstitutionalComputeImport: Sendable {
    struct Page: Sendable, Equatable {
        /// The page's `<image>.txt`.
        let text: URL
        /// Its `_meta/<image>.json`, read again with the text so a folder replaced mid-run cannot pair a hash with
        /// another image's text.
        let meta: URL
        let reading: ImportedReading
    }

    let folder: URL
    /// By the input image's SHA-256 (lowercase hex).
    let pages: [String: Page]
    /// `_meta` files that matched nothing because their provenance is incomplete or their `.txt` is missing.
    let unmatchable: Int

    var count: Int { pages.count }

    enum LoadError: LocalizedError {
        case notABulkRun(URL)
        var errorDescription: String? {
            switch self {
            case .notABulkRun(let url):
                return "\(url.lastPathComponent) has no _meta folder, so it is not the output of an institutional-computing bulk run."
            }
        }
    }

    /// Reads every `_meta/**/*.json` under `folder`. Thousands of small files: call it off the main actor. Two `_meta`
    /// with one hash (the same image twice, or a folder mixing runs) are the same image, so either text is right; the
    /// later one walked names the reader.
    static func load(folder: URL) throws -> InstitutionalComputeImport {
        let fm = FileManager.default
        let meta = folder.appendingPathComponent("_meta", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: meta.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.notABulkRun(folder)
        }
        var pages: [String: Page] = [:]
        var unmatchable = 0
        // Paths relative to `_meta`, as strings: the URL enumerator may report a /private alias of the folder it was
        // given, so its URLs' components cannot be cut at the folder's count.
        let walker = fm.enumerator(atPath: meta.path)
        while let relPath = walker?.nextObject() as? String {
            guard relPath.hasSuffix(".json") else { continue }
            let url = meta.appendingPathComponent(relPath)
            // `_meta/box1/a.jpg.json` → `box1/a.jpg.txt` beside `_meta`.
            let rel = relPath.split(separator: "/").map(String.init)
            guard !rel.isEmpty, let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var parts = rel
            parts[parts.count - 1] = String(parts[parts.count - 1].dropLast(".json".count)) + ".txt"
            let text = parts.reduce(folder) { $0.appendingPathComponent($1) }
            guard let record = Self.record(object),
                  fm.fileExists(atPath: text.path) else {
                unmatchable += 1
                continue
            }
            pages[record.sha] = Page(text: text, meta: url, reading: record.reading)
        }
        return InstitutionalComputeImport(folder: folder, pages: pages, unmatchable: unmatchable)
    }

    /// The page's cluster reading, or nil to read it with the run's model: no match, changed provenance, or its
    /// text is gone or empty. Hashes the image (one read of the file).
    func result(for imageURL: URL) -> OCRResult? {
        guard !pages.isEmpty, let sha = Self.sha256(of: imageURL), let page = pages[sha],
              let data = try? Data(contentsOf: page.meta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = Self.record(object), record.sha == sha, record.reading == page.reading,
              let text = try? String(contentsOf: page.text, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return OCRResult(text: text, classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil,
                         imported: page.reading)
    }

    /// No implicit Stanford label: the kit must name the cluster that actually read this page. No migration is
    /// needed (no app output has been kept). A folder from the older kit must be read again before importing.
    private static func record(_ object: [String: Any]) -> (sha: String, reading: ImportedReading)? {
        guard let sha = (object["sha256"] as? String)?.lowercased(), sha.count == 64,
              sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let cluster = object["cluster"] as? String,
              !ImportedReading.headerComponent(cluster).isEmpty,
              let model = object["model"] as? String,
              !ImportedReading.headerComponent(model).isEmpty else { return nil }
        return (sha, ImportedReading(
            source: cluster, model: model, preset: object["preset"] as? String,
            precision: ImportedReading.precision(model: model, vllmArgs: object["vllm_args"] as? String),
            job: object["job"] as? String, kind: object["kind"] as? String))
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // nil (or empty) is the end of the file; a thrown error is a file that cannot be read.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Who read a page whose text came in from outside the run (W41.app-institutional-compute). `source`/`headerModel` fill
/// the PDF page-2 header's provider/model positions, as `SecondReader` does, without changing the header's shape.
struct ImportedReading: Codable, Equatable, Sendable {
    /// The human-readable cluster name from this page's `_meta.cluster`.
    let source: String
    /// The served model, as vLLM named it (the Hugging Face repo, e.g. `Qwen/Qwen3.6-27B-FP8`).
    let model: String
    /// The kit's preset (`models.sh`), e.g. `qwen3.6-27b`.
    let preset: String?
    /// The weights' and KV cache's precision, from the checkpoint name and the vLLM arguments.
    let precision: String?
    /// The Slurm job that read the page.
    let job: String?
    /// The model's own page-kind label (`typewritten`, `printed`, `mixed`, `handwritten`).
    let kind: String?

    var headerSource: String { Self.headerComponent(source) }

    /// Both free-form header positions must remain on one line and cannot introduce the contract's separator.
    static func headerComponent(_ value: String) -> String {
        value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .split(separator: "\u{00B7}").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The model position: `Qwen3.6-27B-FP8 (FP8 weights, fp8 KV cache, job 1849739)`. Never contains the
    /// header's ` · ` separator.
    var headerModel: String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        let details = [precision, job.map { "job \($0)" }].compactMap { $0 }
        let line = details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
        return Self.headerComponent(line)
    }

    /// `Qwen/Qwen3.6-27B-FP8` + `--kv-cache-dtype fp8` → `FP8 weights, fp8 KV cache`; bf16 weights quantised by
    /// vLLM (`--quantization fp8`, the `-dyn` preset) → `fp8 weights (quantised at load)`.
    static func precision(model: String, vllmArgs: String?) -> String? {
        // `--flag value` and `--flag=value` alike.
        let args = (vllmArgs ?? "").split(whereSeparator: \.isWhitespace)
            .flatMap { $0.hasPrefix("--") ? $0.split(separator: "=", maxSplits: 1) : [$0] }.map(String.init)
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        var parts: [String] = []
        if let quant = value("--quantization") {
            parts.append("\(quant) weights (quantised at load)")
        } else if let suffix = ["FP8", "AWQ", "GPTQ", "NVFP4", "BF16"].first(where: { model.uppercased().hasSuffix("-\($0)") }) {
            parts.append("\(suffix) weights")
        }
        if let kv = value("--kv-cache-dtype"), kv != "auto" { parts.append("\(kv) KV cache") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension OCRProcessor {
    /// A resumed run's import, read again from its folder. A folder that is gone or no longer a bulk run gives nil:
    /// its pages are then read by the run's model, which the run's estimate already counted.
    nonisolated static func reloadInstitutionalComputeImport(_ path: String) -> InstitutionalComputeImport? {
        try? InstitutionalComputeImport.load(folder: URL(fileURLWithPath: path, isDirectory: true))
    }
}
