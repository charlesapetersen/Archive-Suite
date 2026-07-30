import SwiftUI

// MARK: - Shared status badge (Files SF-symbol set ⇄ Live colored dot)

/// Leading status indicator, driven by the shared `ItemState`. `.icon` renders the Process-Files
/// SF-Symbol set; `.dot` renders the Live-Capture colored dot. Both derive from the same state, so the
/// two panes stay visually in sync. `succeededNoText` is amber (a warning), never red.
struct StatusBadge: View {
    enum Style { case icon, dot }
    let state: ItemState
    var style: Style = .icon

    var body: some View {
        switch style {
        case .icon: iconBody
        case .dot:
            Circle().fill(color).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var iconBody: some View {
        switch state {
        case .processing:
            ProgressView().scaleEffect(0.6)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .succeededNoText:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
        case .succeededPlaceholderImage:
            // Filed, but the scan is missing from the PDF (W23.h5) — a photo-shaped amber warning.
            Image(systemName: "photo.badge.exclamationmark.fill").foregroundStyle(.orange).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .removed:
            Image(systemName: "trash.circle.fill").foregroundStyle(.secondary).font(.caption)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        }
    }

    /// Dot color (Live style). Mirrors the old `phaseColor` mapping, plus amber for `succeededNoText`.
    var color: Color {
        switch state {
        case .pending: return .secondary
        case .processing(let label): return label.hasPrefix("Tag") ? .blue : .orange
        case .succeeded: return .green
        case .succeededNoText, .succeededPlaceholderImage: return .orange
        case .failed: return .red
        case .removed: return .secondary
        }
    }
}

// MARK: - Closure-backed action handler

/// Lets a pane supply its action handler as a closure instead of conforming a class to the protocol.
struct ItemActionHandler: ProcessableItemActions {
    let handler: @MainActor (ItemAction, String) -> Void
    func perform(_ action: ItemAction, on itemID: String) { handler(action, itemID) }
}

// MARK: - Shared row (the union of the two panes' rows)

/// One compact row rendering any `ProcessableItem`. Collapsed by default so the common case stays small;
/// expands inline (on selection) to an OCR-text preview + an action-button row built from
/// `availableActions`. Preserves the Files pane's red failure-reason line and adds an amber line for
/// `succeededNoText` / `succeededPlaceholderImage`, now available to both panes.
struct ProcessableItemRow: View {
    let item: any ProcessableItem
    var badgeStyle: StatusBadge.Style = .icon
    var isExpanded: Bool = false
    var isFocused: Bool = false
    /// Files pane: when true, applied tags render as a capsule list below the row (final-review layout);
    /// when false, up to two applied tags render inline after the classification capsule.
    var showTagsList: Bool = false
    let actions: ProcessableItemActions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StatusBadge(state: item.state, style: badgeStyle)
                    .frame(width: 14, alignment: .center)
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let rotation = item.rotationDegrees, rotation != 0 {
                    Text("\(rotation)°")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if let classification = item.classification {
                    Text(classification.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(classificationColor(classification).opacity(0.15))
                        .foregroundStyle(classificationColor(classification))
                        .clipShape(Capsule())
                }
                if !showTagsList, !item.appliedTags.isEmpty {
                    Text(item.appliedTags.prefix(2).joined(separator: " \u{00B7} "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            // Applied-tags capsule list (Files final-review layout).
            if showTagsList, !item.appliedTags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.appliedTags.filter { $0 != "Red" && $0 != "Purple" }, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.leading, 22)
            }

            // Secondary line: subtitle (page count / classification name) + provider·model.
            if item.subtitle != nil || item.providerModel != nil {
                HStack(spacing: 6) {
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.subtitle != nil && item.providerModel != nil {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let pm = item.providerModel {
                        Text(pm).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
            }

            // Failure reason (red) or the image-only warning (amber). Wraps rather than truncates so
            // it's legible in a narrow panel.
            if case .failed = item.state, let msg = failureText {
                Text(msg)
                    .font(.caption2).foregroundStyle(.red)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .succeededNoText = item.state {
                Text("Filed as image-only — no OCR text.")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .succeededPlaceholderImage = item.state {
                Text("Filed, but the original scan could NOT be embedded — the PDF has a placeholder image page. The source photo was KEPT in the Backup Folder; re-run the page to get the image into the archive.")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded { expandedDetail }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(classificationBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        )
    }

    // MARK: Expanded detail (OCR text preview + action buttons)

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = item.ocrText, !text.isEmpty {
                GroupBox {
                    ScrollView {
                        Text(String(text.prefix(500)))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
            }
            if !item.availableActions.isEmpty {
                let id = item.itemID
                FlowLayout(spacing: 6) {
                    ForEach(item.availableActions, id: \.self) { action in
                        Button {
                            actions.perform(action, on: id)
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    // MARK: Styling helpers (shared with the old FileRowView)

    /// The failure line text: prefer the OCR error message (+ code), else the failure-kind label.
    private var failureText: String? {
        if let msg = item.errorMessage, !msg.isEmpty {
            if let code = item.errorCode, !code.isEmpty { return "\(msg) (\(code))" }
            return msg
        }
        if case .failed(let kind) = item.state { return kind.label }
        return nil
    }

    private var classificationBackground: Color {
        guard let classification = item.classification else { return .clear }
        switch classification {
        case .documentStart: return .blue.opacity(0.06)
        case .documentContinuation: return .green.opacity(0.06)
        case .boxLabel: return .red.opacity(0.06)
        case .folderLabel: return .purple.opacity(0.06)
        }
    }

    private func classificationColor(_ c: DocumentClassification) -> Color {
        switch c {
        case .boxLabel: return .red
        case .folderLabel: return .purple
        case .documentStart: return .blue
        case .documentContinuation: return .gray
        }
    }
}
