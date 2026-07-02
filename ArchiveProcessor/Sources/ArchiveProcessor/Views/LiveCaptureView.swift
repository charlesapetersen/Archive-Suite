import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Receiving end of Live Capture: advertises the Mac, shows a pairing QR for the phone, and
/// displays photos streaming in — grouped exactly as marked on the phone. "Process" stages the
/// ordered, pre-grouped photos into the main Files view for the normal OCR run.
struct LiveCaptureView: View {
    @ObservedObject var session: CaptureSession
    @ObservedObject var processor: OCRProcessor
    /// Switch the app back to the Files tab after staging captured photos for processing.
    var onProcess: () -> Void

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 300, maxWidth: 360)
                .padding()
            capturePanel
                .padding()
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1", !session.serverRunning {
                session.start()
            }
        }
        .onDisappear { /* keep the session/server running across tab switches */ }
    }

    // MARK: Left — connection / pairing

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Live Capture")
                    .font(.title).fontWeight(.bold)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(session.serverRunning ? .green : .secondary).frame(width: 8, height: 8)
                            Text(session.serverRunning ? "Listening" : "Stopped").font(.callout)
                            Spacer()
                            if session.serverRunning {
                                Button("Stop") { session.stop() }
                            } else {
                                Button("Start") { session.start() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        Text(session.statusMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                if session.serverRunning, let payload = pairingPayload {
                    GroupBox("Pair the phone") {
                        VStack(spacing: 8) {
                            if let qr = Self.qrImage(from: payload) {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 200, height: 200)
                            }
                            Text("Scan in the Archive Capture app").font(.caption).foregroundStyle(.secondary)
                            if let ip = Self.primaryIPv4() {
                                Text("\(ip):\(session.listenPort)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// JSON pairing payload encoded in the QR: host / port / token / name.
    private var pairingPayload: String? {
        guard session.serverRunning, let ip = Self.primaryIPv4() else { return nil }
        let dict: [String: Any] = [
            "host": ip,
            "port": Int(session.listenPort),
            "token": session.token,
            "name": Host.current().localizedName ?? "Mac"
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Right — live grouped photos

    private var capturePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captured")
                    .font(.headline)
                Text("\(session.photos.count) photo\(session.photos.count == 1 ? "" : "s") · \(session.groups.count) group\(session.groups.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !session.photos.isEmpty {
                    Button("Clear") { session.clear() }
                    Button("Process \(session.photos.count) →") { stageForProcessing() }
                        .buttonStyle(.borderedProminent)
                        .disabled(processor.isProcessing)
                }
            }
            .padding(.bottom, 8)

            Divider()

            if session.photos.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "camera.badge.clock").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(session.serverRunning ? "Waiting for photos…\nShoot on the phone; they'll appear here grouped."
                                               : "Start the server, then pair the phone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(session.groups.enumerated()), id: \.element.id) { idx, group in
                            groupSection(index: idx + 1, group: group)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func groupSection(index: Int, group: CaptureGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let color = group.type.colorTag {
                    Circle().fill(color == "Red" ? .red : .purple).frame(width: 8, height: 8)
                }
                Text("Group \(index) · \(group.type.rawValue.capitalized)")
                    .font(.subheadline).fontWeight(.medium)
                Text("\(group.photos.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(group.photos) { photo in
                    ArchiveThumbnail(url: photo.url, maxSize: 300)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .overlay(alignment: .topTrailing) {
                            Button { session.removePhoto(photo) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .buttonStyle(.plain).padding(4)
                        }
                }
            }
        }
        .padding(10)
        .background(
            group.type == .box ? Color.red.opacity(0.06) :
            group.type == .folder ? Color.purple.opacity(0.06) : Color.gray.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Handoff

    private func stageForProcessing() {
        let (files, boundaries, types, priorities, years, months) = session.orderedFilesAndGroups()
        guard !files.isEmpty else { return }
        processor.stagedCaptureFiles = files
        processor.stagedCaptureBoundaries = boundaries
        processor.stagedCaptureTypes = types
        processor.stagedCapturePriorities = priorities
        processor.stagedCaptureYears = years
        processor.stagedCaptureMonths = months
        onProcess()
    }

    // MARK: Helpers

    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    /// Primary LAN IPv4 (prefers en0/en1) for the pairing payload.
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            if name == "en0" { break }   // prefer Wi-Fi/primary
        }
        return address
    }
}
