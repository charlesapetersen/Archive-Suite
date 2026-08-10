// scale-corpus.swift — build, fingerprint and diff a SCRATCH corpus for the W26.verify scale lane.
//
// Why a standalone tool rather than test code: `execution-plans/despotlight.md` §7a.7 established that
// the no-write assertion cannot be taken by the process under test — pointing the app at a folder WRITES
// (`.archive-suite-root.json`), and a subject that both walks and observes cannot prove it did not write.
// So the observer is a separate program, run before and after, and it records the two stat fields that
// change on ANY mutation: `mtime` (content) and `ctime` (metadata, including every xattr write). Paths
// are recorded too, so a created marker file or a deleted entry is caught as an added/removed row rather
// than needing a field of its own.
//
// Compiled on demand by `ops/scale/run-scale-verify.sh` (`swiftc -O`); it has no package dependencies so
// it can run before, and independently of, any app build.
//
// SAFETY. `build` and `wipe` refuse any root that is not plainly a scratch corpus: the leaf component
// must start with `scale-corpus`, and a path mentioning the real corpus is rejected outright. `manifest`
// is read-only by construction (lstat + listxattr + getxattr) and is the only subcommand pointed at
// anything but a scratch tree.

import Foundation

// MARK: - Deterministic PRNG (so a rerun builds the byte-identical tree)

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
}

// MARK: - Fatal / usage

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("scale-corpus: " + message + "\n").utf8))
    exit(2)
}

func usage() -> Never {
    let text = """
    usage:
      scale-corpus build    --root DIR --files N [--seed S] [--dirs D]
      scale-corpus manifest --root DIR --out FILE
      scale-corpus compare  --before FILE --after FILE
      scale-corpus wipe     --root DIR

    build     creates a scratch corpus shaped like the owner's real one (see the shape table in the
              source): ragged tree to depth 7, ~83% PDFs, ~77% carrying a Read/Unread tag, a tail of
              other-tag-only and untagged files, and a handful of deliberately hostile entries.
    manifest  read-only: one line per path — type, inode, size, mtime, ctime, xattr digest.
    compare   diffs two manifests; exit 1 (with examples) on ANY added, removed or changed path.
    wipe      removes a scratch corpus built by `build` (refuses anything it did not build).
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
guard let subcommand = args.first else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func requiredOption(_ name: String) -> String {
    guard let value = option(name) else { die("missing --\(name)") }
    return value
}
func requiredInt(_ name: String) -> Int {
    guard let value = Int(requiredOption(name)) else { die("--\(name) must be an integer") }
    return value
}

// MARK: - Scratch-root guard

/// The scratch-only gate. Two independent conditions, both required, so a typo cannot aim this at data
/// that matters: the leaf must be named like a scratch corpus, and the path must not mention the real one.
func assertScratchRoot(_ path: String) {
    let standardized = (path as NSString).standardizingPath
    let leaf = (standardized as NSString).lastPathComponent
    if !leaf.hasPrefix("scale-corpus") {
        die("refusing to write to \(standardized): the leaf directory must be named scale-corpus*")
    }
    for forbidden in ["Archival Photos", "Google Drive"] where standardized.contains(forbidden) {
        die("refusing to touch \(standardized): it names the real corpus")
    }
}

// MARK: - xattr helpers

let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"

/// Finder's on-disk form for a tag set: a binary plist array of `Name` or `Name\ncolorIndex` strings.
/// Serialized once per distinct set and then `setxattr`'d verbatim, which is ~8× cheaper per file than
/// `setResourceValue(_:forKey:.tagNamesKey)` and byte-identical to what Finder writes.
func tagPlist(_ entries: [String]) -> Data {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: entries,
                                                        format: .binary, options: 0) else {
        die("could not serialize tag plist for \(entries)")
    }
    return data
}

func writeTags(_ path: String, _ plist: Data) {
    let ok = path.withCString { raw -> Bool in
        plist.withUnsafeBytes { bytes in
            setxattr(raw, finderTagsXattr, bytes.baseAddress, bytes.count, 0, 0) == 0
        }
    }
    if !ok { die("setxattr failed on \(path): errno \(errno)") }
}

// MARK: - build

func build() {
    let root = (requiredOption("root") as NSString).standardizingPath
    assertScratchRoot(root)
    let fileCount = requiredInt("files")
    let seed = UInt64(option("seed") ?? "20260810") ?? 20260810
    let dirCount = Int(option("dirs") ?? "650") ?? 650
    var rng = SplitMix64(seed: seed)

    let fm = FileManager.default
    if fm.fileExists(atPath: root) { die("\(root) already exists — `wipe` it first, or point elsewhere") }
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

    // ── The tree. A ragged random walk to depth ≤ 7, matching the measured real shape
    // (123,028 files / 535 dirs / maxDepth 7 → ~230 files per directory, very unevenly spread).
    var dirsByDepth: [[String]] = [[root]]
    var allDirs: [String] = []
    for i in 0..<dirCount {
        let depth = 1 + rng.int(7)                       // 1…7
        let parentDepth = min(depth - 1, dirsByDepth.count - 1)
        let candidates = dirsByDepth[parentDepth]
        let parent = candidates[rng.int(candidates.count)]
        // Names deliberately include a space, an em dash and a non-breaking space — §2 of the plan
        // records those as present in the real corpus and round-tripping fine; a scale corpus that
        // quietly used ASCII-only names would not exercise the byte-exact path identity the index keys on.
        let name = i % 17 == 0 ? "Box \(i) — folder\u{00A0}\(i)" : "Folder \(i)"
        let path = parent + "/" + name
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        let realDepth = parentDepth + 1
        while dirsByDepth.count <= realDepth { dirsByDepth.append([]) }
        dirsByDepth[realDepth].append(path)
        allDirs.append(path)
    }

    // ── Weighted file distribution, so a few directories hold thousands and most hold a handful.
    var weights = allDirs.map { _ in 1 + rng.int(40) }
    let totalWeight = weights.reduce(0, +)
    var quotas = weights.map { fileCount * $0 / totalWeight }
    var shortfall = fileCount - quotas.reduce(0, +)
    var cursor = 0
    while shortfall > 0 { quotas[cursor % quotas.count] += 1; cursor += 1; shortfall -= 1 }
    weights = []

    // ── Tag sets. Proportions from the measured corpus: 95,201/123,028 = 77.4% Read-or-Unread tagged,
    // and the remainder is a mix of other-tag-only and untagged files.
    let readTags       = tagPlist(["Read"])
    let unreadTags     = tagPlist(["Unread"])
    let richReadTags   = tagPlist(["Read", "Box 12", "Correspondence", "P3\n6"])
    let richUnreadTags = tagPlist(["Unread", "Box 12", "Memoranda", "Y1971", "M03", "D14", "1970s"])
    let subjectOnly    = tagPlist(["Correspondence", "Box 12"])
    let emptyResidue   = tagPlist([String]())   // the 42-byte empty-array residue: 51 such files, measured

    // A minimal, structurally valid PDF, so the tree is honest about what a corpus holds. Discovery
    // never opens it (that is `ContentIndexer`'s cost, explicitly out of this lane's scope).
    let pdfBytes = Data("""
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
    """.utf8)
    let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x20, count: 512) + [0xFF, 0xD9])

    var written = 0, tracked = 0, taggedAtAll = 0, pdfs = 0
    let started = Date()
    for (dirIndex, dir) in allDirs.enumerated() {
        for n in 0..<quotas[dirIndex] {
            let roll = rng.int(1000)
            let isPDF = roll < 830
            let ext = isPDF ? "pdf" : (roll < 960 ? "jpg" : "txt")
            let path = "\(dir)/Doc \(dirIndex)-\(n).\(ext)"
            let bytes = isPDF ? pdfBytes : jpegBytes
            let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
            if fd < 0 { die("open failed on \(path): errno \(errno)") }
            bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            close(fd)
            if isPDF { pdfs += 1 }

            let tagRoll = rng.int(1000)
            switch tagRoll {
            case ..<300:  writeTags(path, unreadTags);     tracked += 1; taggedAtAll += 1
            case ..<560:  writeTags(path, readTags);       tracked += 1; taggedAtAll += 1
            case ..<680:  writeTags(path, richUnreadTags); tracked += 1; taggedAtAll += 1
            case ..<774:  writeTags(path, richReadTags);   tracked += 1; taggedAtAll += 1
            case ..<900:  writeTags(path, subjectOnly);    taggedAtAll += 1
            case ..<910:  writeTags(path, emptyResidue)                  // readable-but-empty
            default:      break                                         // genuinely untagged
            }
            written += 1
        }
    }

    // ── Hostile entries, in their own directory so a lane can point at either tree.
    // They are what makes `isClean == false` reachable at scale, and they are the shapes §4a of the plan
    // proved are misread as "no tags" rather than "could not read".
    let hostile = root + "/zz-hostile"
    try? fm.createDirectory(atPath: hostile, withIntermediateDirectories: true)
    let denied = hostile + "/tag-read-denied.pdf"
    let fd = denied.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    pdfBytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    close(fd)
    writeTags(denied, richUnreadTags)
    _ = denied.withCString { chmod($0, 0o000) }              // tagged, unreadable xattrs → EACCES
    let sealed = hostile + "/sealed-dir"
    try? fm.createDirectory(atPath: sealed, withIntermediateDirectories: true)
    let inside = sealed + "/inside.pdf"
    let fd2 = inside.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    pdfBytes.withUnsafeBytes { _ = write(fd2, $0.baseAddress, $0.count) }
    close(fd2)
    writeTags(inside, readTags)
    _ = sealed.withCString { chmod($0, 0o000) }              // directory error, not a file error
    let link = hostile + "/dangling.pdf"
    _ = link.withCString { l in "/nonexistent/target.pdf".withCString { t in symlink(t, l) } }

    let elapsed = Date().timeIntervalSince(started)
    let meta: [String: Any] = [
        "root": root, "files": written, "dirs": allDirs.count + 2, "pdfs": pdfs,
        "trackedByReadState": tracked, "taggedAtAll": taggedAtAll, "seed": Int(seed),
        "buildSeconds": elapsed, "hostileDir": hostile,
    ]
    let metaData = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
    try? metaData.write(to: URL(fileURLWithPath: root + ".meta.json"))
    print(String(data: metaData, encoding: .utf8)!)
}

// MARK: - manifest (read-only)

func manifest() {
    let root = (requiredOption("root") as NSString).standardizingPath
    let out = requiredOption("out")
    if !FileManager.default.fileExists(atPath: out) {
        FileManager.default.createFile(atPath: out, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: out) else {
        die("cannot open \(out) for writing")
    }
    handle.truncateFile(atOffset: 0)

    var buffer = Data()
    var rows = 0
    func emit(_ line: String) {
        buffer.append(contentsOf: line.utf8)
        buffer.append(0x0A)
        rows += 1
        if buffer.count > 1 << 20 { handle.write(buffer); buffer.removeAll(keepingCapacity: true) }
    }

    /// FNV-1a over every extended attribute (name + value), so an xattr ADDED, removed or edited shows
    /// up even in the impossible case that it left ctime alone.
    func xattrDigest(_ path: String) -> String {
        path.withCString { raw -> String in
            let size = listxattr(raw, nil, 0, XATTR_NOFOLLOW)
            if size <= 0 { return "-" }
            var names = [CChar](repeating: 0, count: size)
            guard listxattr(raw, &names, size, XATTR_NOFOLLOW) == size else { return "?" }
            var hash: UInt64 = 0xCBF29CE484222325
            func mix(_ bytes: UnsafeRawBufferPointer) {
                for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001B3 }
            }
            var index = 0
            while index < size {
                let name = String(cString: Array(names[index...]))
                index += name.utf8.count + 1
                if name.isEmpty { continue }
                name.utf8.withContiguousStorageIfAvailable { mix(UnsafeRawBufferPointer($0)) }
                let valueSize = getxattr(raw, name, nil, 0, 0, XATTR_NOFOLLOW)
                if valueSize > 0 {
                    var value = [UInt8](repeating: 0, count: valueSize)
                    if getxattr(raw, name, &value, valueSize, 0, XATTR_NOFOLLOW) == valueSize {
                        value.withUnsafeBytes { mix($0) }
                    }
                }
            }
            return String(hash, radix: 16)
        }
    }

    // `enumerator(at:)` with an errorHandler, per the write-surface lint's rule 3 — a walk that cannot
    // report what it failed to read is exactly the silent-truncation bug this wave exists to remove.
    // A sealed directory is EXPECTED here (the hostile tree plants one), so a failure is noted, not fatal:
    // what matters is that the same set is unreadable before and after, which the digest of this file
    // covers because an unreadable subtree contributes the same (absent) rows in both passes.
    var unreadable = 0
    let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in unreadable += 1; return true })
    guard let enumerator else { die("cannot enumerate \(root)") }

    for case let url as URL in enumerator {
        let path = url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) ?? url.path }
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { unreadable += 1; continue }
        let kind: String
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = "d"
        case S_IFLNK: kind = "l"
        case S_IFREG: kind = "f"
        default:      kind = "o"
        }
        // ctime is the field that moves on ANY metadata write, including every xattr set — it is the
        // real subject of the no-write assertion. mtime covers content. atime is deliberately NOT
        // recorded: reading a tree legitimately updates it, and a manifest that flagged that would be
        // a guard nobody could keep green.
        emit([kind, path, String(st.st_ino), String(st.st_size),
              "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)",
              "\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)",
              kind == "d" ? "-" : xattrDigest(path)].joined(separator: "\t"))
    }
    if !buffer.isEmpty { handle.write(buffer) }
    handle.closeFile()
    print("manifest rows=\(rows) unreadableDuringWalk=\(unreadable) out=\(out)")
}

// MARK: - compare

func compare() {
    let beforePath = requiredOption("before")
    let afterPath = requiredOption("after")

    func load(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            die("cannot read manifest \(path)")
        }
        var map: [String: String] = [:]
        map.reserveCapacity(200_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7 else { continue }
            map[String(fields[1])] = fields.enumerated()
                .filter { $0.offset != 1 }.map { String($0.element) }.joined(separator: "\t")
        }
        return map
    }

    let before = load(beforePath), after = load(afterPath)
    var added: [String] = [], removed: [String] = [], changed: [String] = []
    for (path, row) in after {
        guard let old = before[path] else { added.append(path); continue }
        if old != row { changed.append("\(path)\n    before: \(old)\n    after:  \(row)") }
    }
    for path in before.keys where after[path] == nil { removed.append(path) }

    print("compare before=\(before.count) after=\(after.count) "
          + "added=\(added.count) removed=\(removed.count) changed=\(changed.count)")
    func show(_ label: String, _ items: [String]) {
        guard !items.isEmpty else { return }
        print("  \(label):")
        for item in items.sorted().prefix(20) { print("    \(item)") }
        if items.count > 20 { print("    … and \(items.count - 20) more") }
    }
    show("ADDED", added); show("REMOVED", removed); show("CHANGED", changed)
    if added.isEmpty && removed.isEmpty && changed.isEmpty {
        print("✓ no writes: every path, inode, size, mtime, ctime and xattr digest is identical")
        exit(0)
    }
    exit(1)
}

// MARK: - wipe

func wipe() {
    let root = (requiredOption("root") as NSString).standardizingPath
    assertScratchRoot(root)
    let meta = root + ".meta.json"
    guard FileManager.default.fileExists(atPath: meta) else {
        die("refusing to remove \(root): no sibling \(meta), so this tool did not build it")
    }
    // The hostile tree contains a 0o000 directory, which defeats removeItem — reopen it first rather
    // than reaching for `rm -rf` (a force past a refusal is exactly what the prime directives forbid).
    _ = (root + "/zz-hostile/sealed-dir").withCString { chmod($0, 0o755) }
    _ = (root + "/zz-hostile/tag-read-denied.pdf").withCString { chmod($0, 0o644) }
    do {
        try FileManager.default.removeItem(atPath: root)
        try FileManager.default.removeItem(atPath: meta)
        print("wiped \(root)")
    } catch { die("could not wipe \(root): \(error.localizedDescription)") }
}

switch subcommand {
case "build":    build()
case "manifest": manifest()
case "compare":  compare()
case "wipe":     wipe()
default:         usage()
}
