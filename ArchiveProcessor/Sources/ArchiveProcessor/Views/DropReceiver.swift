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
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onDropCallback?(urls)
        return true
    }
}
