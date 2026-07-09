import SwiftUI

/// A token/chip tag entry field with autocomplete drawn from the Finder tags currently in
/// use on the system (via `SystemTagsProvider`). Commit a tag with Return, comma, or by
/// clicking a suggestion; remove with the chip's ✕.
struct TagInputField: View {
    @Binding var tags: [String]
    var placeholder: String = "Add tag…"

    @State private var input: String = ""
    @FocusState private var focused: Bool
    @ObservedObject private var provider = SystemTagsProvider.shared

    private var suggestions: [String] {
        guard focused, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return provider.suggestions(prefix: input, excluding: tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(text: tag) { remove(tag) }
                }
                TextField(tags.isEmpty ? placeholder : "", text: $input)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 90)
                    .focused($focused)
                    .onSubmit { commit(input) }
                    .onChange(of: input) { _, newValue in
                        if newValue.contains(",") {
                            for part in newValue.split(separator: ",") { commit(String(part)) }
                            input = ""
                        }
                    }
            }
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 1.5 : 1)
            )

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            commit(s)
                        } label: {
                            HStack {
                                Image(systemName: "tag")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(s).font(.caption)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            }
        }
    }

    private func commit(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        guard !t.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        tags.append(t)
        provider.register([t])
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }
}

struct TagChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// Simple wrapping (flow) layout for tag chips + input field. Uses the macOS 14 Layout protocol.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalWidth = (maxWidth == .infinity) ? x : maxWidth
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
