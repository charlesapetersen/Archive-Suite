import SwiftUI

struct ManagedGemmaBanner: View {
    @ObservedObject var reader: ManagedGemma
    static let termsURL = URL(string: "https://ai.google.dev/gemma/terms")!

    var body: some View {
        HStack(spacing: 14) {
            if reader.offerVisible {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Read box and folder labels with Gemma 3 12B on this Mac").font(.callout.weight(.medium))
                    Text(ManagedGemma.sizeNote + " Also available in Settings → Capture.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.gemma.requirements")
                }
                Spacer()
                Link("Gemma terms", destination: Self.termsURL)
                Button("Not Now") { reader.dismissOffer() }
                    .accessibilityIdentifier("ap.gemma.dismiss")
                Button("Download") { reader.download() }
                    .accessibilityIdentifier("ap.gemma.download")
            } else if let status = reader.installStatus {
                if reader.installing { ProgressView().controlSize(.small) }
                Text(status).font(.callout)
                Spacer()
                if reader.installing {
                    Button("Pause Download") { reader.pauseDownload() }
                } else {
                    Button("Dismiss") { reader.dismissStatus() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
