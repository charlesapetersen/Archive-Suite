import Foundation

/// One find hit of a page pair: each pane's match ordinal for it, nil where that pane has no match for
/// this occurrence.
struct PairHit: Equatable, Sendable {
    var left: Int?
    var right: Int?
}

/// Pairs the image page's find matches with the OCR text page's by lining the two pages' words up
/// (W49.reader-find-word-align). The two texts come from different readers, so a word the image page's
/// text layer split, merged or missed would shift every later match by one if matches were paired by
/// ordinal. Here both pages are cut into normalised words (case, diacritics and width folded), the word
/// sequences are diffed (`CollectionDifference`), and a match is paired with the match on the word the
/// diff lines its own word up with, or failing that with the other page's next unpaired match in the same
/// stretch between two shared words. A match with no counterpart either way is a hit of its pane alone.
/// Pure and view-free; a page's text is only read, never changed.
enum FindWordAlignment {
    /// The k-th match of each pane as the k-th hit: the pairing when the pages cannot be aligned.
    static func ordinalHits(left: Int, right: Int) -> [PairHit] {
        (0..<max(left, right, 0)).map { PairHit(left: $0 < left ? $0 : nil, right: $0 < right ? $0 : nil) }
    }

    /// The pair's hits in reading order. `leftMatches` / `rightMatches` are each pane's matches as UTF-16
    /// offsets into its text, in the order the pane selects them (the k-th entry is ordinal k).
    static func pairHits(leftText: String, leftMatches: [Int], rightText: String, rightMatches: [Int]) -> [PairHit] {
        let leftWords = words(in: leftText), rightWords = words(in: rightText)
        // Intern the keys so the diff compares integers, not strings.
        var ids: [String: Int] = [:]
        func id(_ key: String) -> Int {
            if let known = ids[key] { return known }
            ids[key] = ids.count
            return ids.count - 1
        }
        let leftIDs = leftWords.map { id($0.key) }, rightIDs = rightWords.map { id($0.key) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in rightIDs.difference(from: leftIDs) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both word lists in step: a shared word gets one position for both pages and a partner; a
        // word only one page has gets a position of its own between its neighbours. Index `count` stands
        // for "after the last word" (a match in trailing non-word text).
        var leftPos = [Int](repeating: 0, count: leftWords.count + 1)
        var rightPos = [Int](repeating: 0, count: rightWords.count + 1)
        var partner = [Int?](repeating: nil, count: leftWords.count + 1)
        var a = 0, b = 0, step = 0
        while a < leftWords.count || b < rightWords.count {
            if a < leftWords.count && (removed.contains(a) || b == rightWords.count) {
                leftPos[a] = step; a += 1
            } else if b < rightWords.count && (inserted.contains(b) || a == leftWords.count) {
                rightPos[b] = step; b += 1
            } else {
                leftPos[a] = step; rightPos[b] = step; partner[a] = b; a += 1; b += 1
            }
            step += 1
        }
        leftPos[leftWords.count] = step
        rightPos[rightWords.count] = step
        partner[leftWords.count] = rightWords.count

        let leftAt = leftMatches.map { wordIndex(of: $0, in: leftWords) }
        let rightAt = rightMatches.map { wordIndex(of: $0, in: rightWords) }
        // The right page's matches per word, in order, so the n-th match on a word pairs with the n-th on
        // its partner (a short query can match more than once inside one word).
        var rightOnWord: [Int: [Int]] = [:]
        for (k, w) in rightAt.enumerated() { rightOnWord[w, default: []].append(k) }

        var placed: [(pos: Int, nth: Int, rightOnly: Int, hit: PairHit)] = []
        var usedRight = Set<Int>()
        var leftSeenOnWord: [Int: Int] = [:]
        for (k, w) in leftAt.enumerated() {
            let nth = leftSeenOnWord[w, default: 0]
            leftSeenOnWord[w] = nth + 1
            var hit = PairHit(left: k, right: nil)
            if let pw = partner[w], let onPartner = rightOnWord[pw], nth < onPartner.count {
                hit.right = onPartner[nth]
                usedRight.insert(onPartner[nth])
            }
            placed.append((leftPos[w], nth, 0, hit))
        }
        // A match on a word the diff could not line up (a misread "thee" for "the") still pairs with the
        // other page's unpaired match in the same stretch between two shared words, in order: that stretch
        // is the same passage on both pages.
        let leftGap = gaps(partnered: partner.map { $0 != nil }), rightGap = gaps(partnered: rightPartnered(partner, rightWords.count))
        var rightLeftoverInGap: [Int: [Int]] = [:]
        for (k, w) in rightAt.enumerated() where !usedRight.contains(k) {
            if let g = rightGap[w] { rightLeftoverInGap[g, default: []].append(k) }
        }
        for i in placed.indices where placed[i].hit.right == nil {
            guard let g = leftGap[leftAt[placed[i].hit.left!]], var leftover = rightLeftoverInGap[g], !leftover.isEmpty
            else { continue }
            placed[i].hit.right = leftover.removeFirst()
            usedRight.insert(placed[i].hit.right!)
            rightLeftoverInGap[g] = leftover
        }
        for (k, w) in rightAt.enumerated() where !usedRight.contains(k) {
            let nth = rightOnWord[w]?.firstIndex(of: k) ?? 0
            placed.append((rightPos[w], nth, 1, PairHit(left: nil, right: k)))
        }
        // Positions rise with the word index on each page, and `nth` with the offset inside a word, so the
        // sort keeps each pane's ordinals in order.
        placed.sort { ($0.pos, $0.nth, $0.rightOnly) < ($1.pos, $1.nth, $1.rightOnly) }
        return placed.map(\.hit)
    }

    /// For each word, nil if the diff lined it up with a word of the other page, else which stretch
    /// between shared words it sits in (the number of shared words before it). Shared words come in the
    /// same order on both pages, so the same number names the same stretch on each.
    private static func gaps(partnered: [Bool]) -> [Int?] {
        var shared = 0
        return partnered.map { isShared in
            if isShared { shared += 1; return nil }
            return shared
        }
    }

    /// Which of the right page's words (and its "after the last word" slot) have a partner.
    private static func rightPartnered(_ partner: [Int?], _ rightCount: Int) -> [Bool] {
        var result = [Bool](repeating: false, count: rightCount + 1)
        for case let b? in partner { result[b] = true }
        return result
    }

    struct Word: Equatable {
        var key: String       // the normalised word the diff compares
        var range: NSRange    // where it sits in the page's text, UTF-16
    }

    /// The text's words in order, by the system's word boundaries (punctuation and spaces are not words).
    static func words(in text: String) -> [Word] {
        var found: [Word] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            guard let word else { return }
            found.append(Word(key: word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                locale: nil),
                              range: range))
        }
        return found
    }

    /// The word a match at `offset` falls on: the word containing it, else the next word after it (a match
    /// that starts in a space or a punctuation mark), else `words.count`.
    static func wordIndex(of offset: Int, in words: [Word]) -> Int {
        // The first word that ends after `offset` either contains it or is the next one.
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(words[mid].range) <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
