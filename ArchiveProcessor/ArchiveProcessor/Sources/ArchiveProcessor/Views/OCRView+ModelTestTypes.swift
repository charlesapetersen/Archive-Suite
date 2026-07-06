import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Model Test Data Types

struct ModelTestEntry: Identifiable {
    let id = UUID()
    let provider: LLMProvider
    let model: LLMModel
    let apiKey: String
}

struct ModelTestResult: Identifiable {
    let id = UUID()
    let provider: LLMProvider
    let model: LLMModel
    let text: String?
    let errorMessage: String?
}

