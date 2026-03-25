import SwiftUI
import AppKit

// NSView-based drop target — more reliable than SwiftUI's onDrop on macOS
struct DropReceiver: NSViewRepresentable {
    var isTargeted: Binding<Bool>
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropReceiverView {
        let view = DropReceiverView()
        view.onDropCallback = onDrop
        view.isTargetedBinding = isTargeted
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: DropReceiverView, context: Context) {
        nsView.onDropCallback = onDrop
        nsView.isTargetedBinding = isTargeted
    }
}

class DropReceiverView: NSView {
    var onDropCallback: (([URL]) -> Void)?
    var isTargetedBinding: Binding<Bool>?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isTargetedBinding?.wrappedValue = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isTargetedBinding?.wrappedValue = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isTargetedBinding?.wrappedValue = false
        guard let pasteboard = sender.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let url = URL(string: pasteboard) else {
            // Try reading multiple URLs
            let urls = readURLsFromPasteboard(sender.draggingPasteboard)
            if !urls.isEmpty {
                onDropCallback?(urls)
                return true
            }
            return false
        }
        onDropCallback?([url])
        return true
    }

    private func readURLsFromPasteboard(_ pasteboard: NSPasteboard) -> [URL] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var urls: [URL] = []
        for item in items {
            if let data = item.string(forType: .fileURL),
               let url = URL(string: data) {
                urls.append(url)
            }
        }
        return urls
    }
}
