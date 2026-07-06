import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Resolution Drop Sheet

struct ResolutionDropSheet: View {
    let onSelect: (URL) -> Void
    let onDismiss: () -> Void
    @State private var isTargeted = false

    private let dropTypes: [UTType] = [.fileURL]
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Image for Resolution Test")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(isTargeted ? .blue : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isTargeted ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05))
                    )

                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Drop an image here")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("JPEG, PNG, TIFF, or HEIC")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 160)
            .onDrop(of: dropTypes, isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true),
                          imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { onSelect(url) }
                }
                return true
            }

            HStack {
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]
                    panel.allowsMultipleSelection = false
                    panel.message = "Select an image to test OCR at different resolutions"
                    if panel.runModal() == .OK, let url = panel.url {
                        onSelect(url)
                    }
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

