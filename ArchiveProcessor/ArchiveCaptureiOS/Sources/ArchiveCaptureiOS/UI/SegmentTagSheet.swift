import SwiftUI

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// Minimal on-phone tagging shown when a document segment is finished: quality + date. Subjects are
/// intentionally NOT here — the Mac handles those. Mirrors the Android SegmentTagSheet.
struct SegmentTagSheet: View {
    let recentYears: [Int]
    let onApply: (_ quality: String?, _ year: Int?, _ month: Int?) -> Void
    /// End segment was a mistake — close without ending the segment (keep shooting the same document).
    let onCancel: () -> Void

    @State private var quality: Int?
    @State private var year: Int?
    @State private var month: Int?
    @State private var customYear = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tag this document").font(.title2).bold()

                Text("Quality").font(.headline)
                HStack(spacing: 8) {
                    ForEach(0...3, id: \.self) { q in
                        chip(q == 0 ? "0 · Unrated" : "Q\(q)", selected: quality == q) {
                            quality = (quality == q) ? nil : q
                        }
                    }
                }

                Text("Year").font(.headline)
                if !recentYears.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(recentYears, id: \.self) { y in
                            chip(String(y), selected: year == y && customYear.isEmpty) {
                                if year == y { year = nil } else { year = y; customYear = "" }
                            }
                        }
                    }
                }
                TextField("Specific year", text: $customYear)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customYear) { _, s in
                        let digits = String(s.filter(\.isNumber).prefix(4))
                        if digits != s { customYear = digits }
                        year = Int(digits)
                    }

                Text("Month").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(Array(months.enumerated()), id: \.offset) { i, name in
                        chip(name, selected: month == i + 1) { month = (month == i + 1) ? nil : i + 1 }
                    }
                }

                HStack(spacing: 12) {
                    Button("Skip (tag on Mac)") { onApply(nil, nil, nil) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Button("Apply & continue") { onApply(quality.flatMap { $0 == 0 ? nil : "Q\($0)" }, year, month) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                // Escape hatch for an accidental End-segment tap: keep the current document open (does NOT end it).
                Button("Cancel — keep shooting", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
