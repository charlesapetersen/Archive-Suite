import Foundation

/// Integer ranks for strings in `localizedStandardCompare` order, remembered across calls
/// (W40.fix-reader-list-recompute-at-size).
///
/// `LibrarySort` compares ranks instead of strings. Ranking a string costs `localizedStandardCompare`
/// calls only the first time it is seen: a cold list of n names pays the n·log n comparisons the old
/// comparator paid, and every later sort of the same names, after a tag edit or a sort change, pays
/// one dictionary lookup per row. A new string (a rename, a new tag set) is placed by binary search.
/// Strings that collate equal (`file1`, `file01`) share a rank, so a sort falls through to its next key
/// on them exactly as the comparator did.
///
/// Ranks from different calls are not comparable: an insertion renumbers. Locked, because the main
/// actor and tests may sort concurrently. Strings no longer in the library stay until the cache
/// passes `limit`, when it starts again from the strings of the call that crossed it.
final class CollationRanks: @unchecked Sendable {
    private let lock = NSLock()
    private var ordered: [String] = []        // ascending
    private var tiesPrevious: [Bool] = []     // ordered[i] collates equal to ordered[i - 1]
    private var rankOf: [UTF8Key: Int] = [:]
    private let limit: Int

    init(limit: Int = 600_000) { self.limit = limit }

    /// Number of distinct strings remembered.
    var count: Int { lock.withLock { ordered.count } }

    /// For each column, each string's rank; `nil` maps to `Int.max`. Ranks are comparable across the
    /// columns of one call.
    func ranks(for columns: [[String?]]) -> [[Int]] {
        lock.withLock {
            var fresh = Set<UTF8Key>()
            for column in columns {
                for case let s? in column where rankOf[UTF8Key(s)] == nil { fresh.insert(UTF8Key(s)) }
            }
            if !fresh.isEmpty {
                if ordered.count + fresh.count > limit {
                    ordered = []; tiesPrevious = []; rankOf = [:]
                    fresh = Set(columns.joined().compactMap { $0.map(UTF8Key.init) })
                }
                insert(fresh.map(\.string))
            }
            return columns.map { $0.map { s in s.map { rankOf[UTF8Key($0)]! } ?? Int.max } }
        }
    }

    private static func before(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedSame
    }

    private func insert(_ fresh: [String]) {
        let new = fresh.sorted(by: Self.before)
        if new.count <= 64 {
            // A few new strings: binary search each (log n comparisons), then mark its ties with the
            // neighbours on either side.
            for s in new {
                var lo = 0, hi = ordered.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if Self.before(ordered[mid], s) { lo = mid + 1 } else { hi = mid }
                }
                ordered.insert(s, at: lo)
                tiesPrevious.insert(lo > 0 && Self.same(ordered[lo - 1], s), at: lo)
                if lo + 1 < ordered.count { tiesPrevious[lo + 1] = Self.same(s, ordered[lo + 1]) }
            }
        } else {
            // Many: merge the two sorted lists. A tie flag is reused where two neighbours were already
            // neighbours in their own list, and compared afresh only where the lists interleave.
            let newTies = new.indices.map { $0 > 0 && Self.same(new[$0 - 1], new[$0]) }
            var merged: [String] = [], mergedTies: [Bool] = []
            merged.reserveCapacity(ordered.count + new.count)
            mergedTies.reserveCapacity(ordered.count + new.count)
            var i = 0, j = 0
            var last: (fromNew: Bool, index: Int)? = nil
            while i < ordered.count || j < new.count {
                let takeNew = i == ordered.count || (j < new.count && Self.before(new[j], ordered[i]))
                let (value, index) = takeNew ? (new[j], j) : (ordered[i], i)
                let tie: Bool
                switch last {
                case nil: tie = false
                case let (fromNew, previous)? where fromNew == takeNew && previous == index - 1:
                    tie = takeNew ? newTies[index] : tiesPrevious[index]
                default: tie = Self.same(merged[merged.count - 1], value)
                }
                merged.append(value); mergedTies.append(tie)
                last = (takeNew, index)
                if takeNew { j += 1 } else { i += 1 }
            }
            ordered = merged
            tiesPrevious = mergedTies
        }
        rankOf.reserveCapacity(ordered.count)
        var rank = 0
        for (k, s) in ordered.enumerated() {
            if k > 0, !tiesPrevious[k] { rank += 1 }
            rankOf[UTF8Key(s)] = rank
        }
    }
}

/// A string compared and hashed by its UTF-8 bytes. `String` hashes and compares by canonical
/// equivalence, which normalizes any non-ASCII string on every hash: at 116k paths, 42% of them
/// non-ASCII, a dictionary or set of them cost 15–20 times what it does for ASCII. Byte identity is the
/// right test where the strings come from the same filesystem walk, and for `CollationRanks` two
/// canonically equal spellings simply hold two entries that collate equal and so share a rank.
struct UTF8Key: Hashable, Sendable {
    let string: String
    init(_ string: String) { self.string = string }

    static func == (a: UTF8Key, b: UTF8Key) -> Bool {
        var x = a.string, y = b.string
        return x.withUTF8 { p in
            y.withUTF8 { q in p.count == q.count && (p.isEmpty || memcmp(p.baseAddress!, q.baseAddress!, p.count) == 0) }
        }
    }

    func hash(into hasher: inout Hasher) {
        var s = string
        s.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
