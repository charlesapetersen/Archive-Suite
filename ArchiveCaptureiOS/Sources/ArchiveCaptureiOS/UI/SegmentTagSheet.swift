import SwiftUI

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// Minimal on-phone tagging shown when a document segment is finished: priority + date. Subjects are
/// intentionally NOT here — the Mac handles those. Mirrors the Android SegmentTagSheet.
struct SegmentTagSheet: View {
    let recentYears: [Int]
    let onApply: (_ priority: String?, _ year: Int?, _ month: Int?) -> Void

    @State private var priority: String?
    @State private var year: Int?
    @State private var month: Int?
    @State private var customYear = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tag this document").font(.title2).bold()

                Text("Priority").font(.headline)
                HStack(spacing: 8) {
                    ForEach(["P10", "P9", "P8", "P7"], id: \.self) { p in
                        chip(p, selected: priority == p) { priority = (priority == p) ? nil : p }
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
                    Button("Skip") { onApply(nil, nil, nil) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Button("Apply & continue") { onApply(priority, year, month) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
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
