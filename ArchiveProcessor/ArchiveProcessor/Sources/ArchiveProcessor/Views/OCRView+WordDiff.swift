import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Word-level Diff Engine

enum WordDiff {
    enum Element {
        case equal(String)
        case inserted(String)
        case deleted(String)
        case changed(String, String) // (baseline, candidate)
        case whitespace(String)
    }

    struct DiffResult {
        let elements: [Element]
        let similarity: Double
        let missing: Int  // words in baseline but not candidate
        let added: Int    // words in candidate but not baseline
        let changed: Int  // words that differ between baseline and candidate
    }

    /// Tokenize text preserving whitespace as separate tokens
    private static func tokenize(_ text: String) -> [(word: String, isWhitespace: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inWhitespace = false

        for ch in text {
            let charIsWS = ch.isWhitespace || ch.isNewline
            if charIsWS != inWhitespace && !current.isEmpty {
                tokens.append((current, inWhitespace))
                current = ""
            }
            inWhitespace = charIsWS
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append((current, inWhitespace))
        }
        return tokens
    }

    /// Extract just the words (non-whitespace tokens) for LCS comparison
    private static func words(from tokens: [(word: String, isWhitespace: Bool)]) -> [String] {
        tokens.filter { !$0.isWhitespace }.map { $0.word }
    }

    /// Longest Common Subsequence returning aligned pairs: (baselineIndex?, candidateIndex?)
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int?, Int?)] {
        let m = a.count, n = b.count
        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            for j in 1...max(n, 1) {
                guard j <= n else { break }
                if a[i-1].lowercased() == b[j-1].lowercased() {
                    dp[i][j] = dp[i-1][j-1] + 1
                } else {
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
                }
            }
        }

        // Backtrack to get alignment
        var result: [(Int?, Int?)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i-1].lowercased() == b[j-1].lowercased() {
                result.append((i-1, j-1))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                result.append((nil, j-1))
                j -= 1
            } else {
                result.append((i-1, nil))
                i -= 1
            }
        }
        return result.reversed()
    }

    static func diff(baseline: String, candidate: String) -> DiffResult {
        let baseTokens = tokenize(baseline)
        let candTokens = tokenize(candidate)
        let baseWords = words(from: baseTokens)
        let candWords = words(from: candTokens)

        let aligned = lcs(baseWords, candWords)

        // Build a set of which candidate word indices are "equal" vs "inserted"
        // and reconstruct the display from the candidate's token stream
        var candWordStatus: [Int: (matched: Bool, baseIdx: Int?)] = [:]
        var missingCount = 0
        var addedCount = 0
        var changedCount = 0

        for (baseIdx, candIdx) in aligned {
            if let bi = baseIdx, let ci = candIdx {
                // Check if exact match or just case-insensitive match
                if baseWords[bi] == candWords[ci] {
                    candWordStatus[ci] = (matched: true, baseIdx: bi)
                } else {
                    candWordStatus[ci] = (matched: false, baseIdx: bi)
                    changedCount += 1
                }
            } else if baseIdx != nil {
                missingCount += 1
            } else if let ci = candIdx {
                candWordStatus[ci] = (matched: false, baseIdx: nil)
                addedCount += 1
            }
        }

        // Build display elements from candidate token stream, interleaving deleted words
        var elements: [Element] = []
        var candWordIdx = 0

        // Rebuild from candidate tokens, inserting deleted markers
        // First, build a map of "before candidate word index X, insert these deleted baseline words"
        var deletionsBeforeCandWord: [Int: [Int]] = [:]
        var pendingDeletions: [Int] = []
        for (bi, ci) in aligned {
            if let bi = bi, ci == nil {
                pendingDeletions.append(bi)
            } else if let ci = ci {
                if !pendingDeletions.isEmpty {
                    deletionsBeforeCandWord[ci] = pendingDeletions
                    pendingDeletions = []
                }
            }
        }
        // Any remaining deletions go at the end
        let trailingDeletions = pendingDeletions

        candWordIdx = 0
        for token in candTokens {
            if token.isWhitespace {
                elements.append(.whitespace(token.word))
            } else {
                // Insert any deletions that should appear before this candidate word
                if let dels = deletionsBeforeCandWord[candWordIdx] {
                    for di in dels {
                        elements.append(.deleted(baseWords[di]))
                        elements.append(.whitespace(" "))
                    }
                }

                if let status = candWordStatus[candWordIdx] {
                    if status.matched {
                        elements.append(.equal(token.word))
                    } else if let bi = status.baseIdx {
                        elements.append(.changed(baseWords[bi], token.word))
                    } else {
                        elements.append(.inserted(token.word))
                    }
                } else {
                    elements.append(.inserted(token.word))
                }
                candWordIdx += 1
            }
        }

        // Append trailing deletions
        for di in trailingDeletions {
            elements.append(.whitespace(" "))
            elements.append(.deleted(baseWords[di]))
        }

        let totalBaseWords = baseWords.count
        let matchedWords = totalBaseWords - missingCount - changedCount
        let similarity = totalBaseWords > 0 ? Double(max(0, matchedWords)) / Double(totalBaseWords) : 1.0

        return DiffResult(
            elements: elements,
            similarity: similarity,
            missing: missingCount,
            added: addedCount,
            changed: changedCount
        )
    }

    static func buildAttributedString(from elements: [Element]) -> AttributedString {
        var attributed = AttributedString()
        for element in elements {
            var part: AttributedString
            switch element {
            case .equal(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced)
            case .inserted(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced).bold()
                part.foregroundColor = .blue
                part.backgroundColor = Color.blue.opacity(0.12)
            case .deleted(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced).bold()
                part.foregroundColor = .red
                part.strikethroughStyle = .single
                part.backgroundColor = Color.red.opacity(0.12)
            case .changed(let from, let to):
                var fromPart = AttributedString(from)
                fromPart.font = .system(size: 10, design: .monospaced).bold()
                fromPart.foregroundColor = .red
                fromPart.strikethroughStyle = .single
                fromPart.backgroundColor = Color.red.opacity(0.12)
                var toPart = AttributedString(to)
                toPart.font = .system(size: 10, design: .monospaced).bold()
                toPart.foregroundColor = .orange
                toPart.backgroundColor = Color.orange.opacity(0.12)
                attributed.append(fromPart)
                part = toPart
            case .whitespace(let ws):
                part = AttributedString(ws)
                part.font = .system(size: 10, design: .monospaced)
            }
            attributed.append(part)
        }
        return attributed
    }
}

