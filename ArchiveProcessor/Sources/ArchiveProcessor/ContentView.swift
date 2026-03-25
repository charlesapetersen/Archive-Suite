import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .ocr

    enum AppTab: String, CaseIterable {
        case ocr = "OCR"
        case tagging = "Tagging"

        var icon: String {
            switch self {
            case .ocr: return "doc.text.viewfinder"
            case .tagging: return "tag"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            OCRView()
                .tabItem {
                    Label("OCR", systemImage: "doc.text.viewfinder")
                }
                .tag(AppTab.ocr)

            TaggingView()
                .tabItem {
                    Label("Tagging", systemImage: "tag")
                }
                .tag(AppTab.tagging)
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}
