import ArchiveCore
import SwiftUI

/// A field's check state (W40.reader-field-status): a symbol and a label in the state's colour, green when checked,
/// yellow when unchecked from a route that clears the fill rule, red when lower confidence. The label and the
/// symbol's shape carry the state without the colour. The tooltip says where the value came from and the measured
/// figure. Shared so item fields and container fields show it the same way (W47.ct-reader-view).
public struct FieldStatusBadge: View {
    let status: FieldStatus

    public init(_ status: FieldStatus) { self.status = status }

    public static func color(_ level: FieldCheckLevel) -> Color {
        switch level {
        case .checked: return .green
        case .unchecked: return .yellow
        case .lowerConfidence: return .red
        }
    }

    public var body: some View {
        Label {
            Text(status.level.label).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: status.level.symbol).foregroundStyle(Self.color(status.level))
        }
        .font(.caption)
        .help(status.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.level.label)
        .accessibilityValue(status.detail)
    }
}

/// One field as the Inspector lists it: its name, its value, its state, and a button that checks or unchecks it.
public struct FieldStatusRow: View {
    let name: String
    let value: String
    let status: FieldStatus
    let identifier: String
    let onToggle: (() -> Void)?

    /// - Parameter onToggle: checks the field, or unchecks it when it is checked; nil shows no button (a container
    ///   value is confirmed in its own editor).
    public init(name: String, value: String, status: FieldStatus, identifier: String, onToggle: (() -> Void)?) {
        self.name = name
        self.value = value
        self.status = status
        self.identifier = identifier
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                FieldStatusBadge(status).accessibilityIdentifier(identifier + ".status")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + ".value")
                Spacer(minLength: 8)
                if let onToggle {
                    let checked = status.level == .checked
                    Button(checked ? "Uncheck" : "Mark checked", action: onToggle)
                        .controlSize(.small)
                        .help(checked ? "Remove the check from \(name.lowercased())."
                                      : "Mark \(name.lowercased()) checked without changing it.")
                        .accessibilityIdentifier(identifier + ".check")
                }
            }
        }
    }
}
