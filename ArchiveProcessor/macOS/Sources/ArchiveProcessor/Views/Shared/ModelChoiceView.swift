import SwiftUI

/// A retry can change its forced output rotation, but it must never change the run's OCR backend.
/// The owning run has already locked its provider/model, gateway or Local Agent configuration, and
/// replaying that configuration is what makes the retry's cost and authentication truthful.
struct RotationRetrySheet: View {
    let title: String
    let subtitle: String?
    let backendDescription: String
    let initialRotation: Int
    let onApply: (Int) -> Void
    let onCancel: () -> Void

    @State private var rotation: Int

    init(title: String, subtitle: String? = nil, backendDescription: String,
         initialRotation: Int = 0, onApply: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.backendDescription = backendDescription
        self.initialRotation = initialRotation
        self.onApply = onApply
        self.onCancel = onCancel
        _rotation = State(initialValue: ((initialRotation % 360) + 360) % 360)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2).fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("Uses the same backend: \(backendDescription)", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: $rotation, in: 0...270, step: 90) {
                    Text("Rotation: \(rotation)°")
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Re-run") { onApply(rotation) }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 560)
    }
}
