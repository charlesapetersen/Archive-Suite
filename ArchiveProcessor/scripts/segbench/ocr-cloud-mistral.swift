// Standalone harness around the production MistralClient, ImageEncoding and NetworkSession.
// Dependency-only types: the app's model catalog/result store are not linked into this executable.
import Foundation
struct LLMModel { let id: String }
enum DocumentClassification: String, Codable { case boxLabel, folderLabel, documentStart, documentContinuation }
struct OCRResult: Codable {
    let text: String?
    let classification: DocumentClassification?
    let errorMessage: String?
    let errorCode: String?
}
enum OCRError: Error { case imageLoadFailed, networkError(String) }
enum OCRProcessor { static let batchResumeTestEnvKey = "BATCHRESUME_TEST" }

@main struct Pilot {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              ProcessInfo.processInfo.environment["VISIONHYBRID_TEST"] == "1" else {
            throw OCRError.networkError("requires input, output prefix, and explicit recording flag")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let prefix = CommandLine.arguments[2]
        let fixture = ProcessInfo.processInfo.environment["OCR_CLOUD_MISTRAL_FIXTURE"]
        let key: String
        if fixture != nil {
            key = "offline-fixture"
        } else {
            let proc = Process(); let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            proc.arguments = ["find-generic-password", "-s", "com.archiveprocessor.app", "-a", "Mistral", "-w"]
            proc.standardOutput = pipe; proc.standardError = Pipe()
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let found = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !found.isEmpty else { throw OCRError.networkError("Mistral key unavailable") }
            key = found
        }
        NetworkSession.testTransport = { request in
            guard request.url?.absoluteString == "https://api.mistral.ai/v1/ocr",
                  request.httpMethod == "POST" else { throw OCRError.networkError("unexpected endpoint") }
            let raw: Data
            let response: URLResponse
            if let fixture {
                raw = try Data(contentsOf: URL(fileURLWithPath: fixture))
                response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            } else {
                (raw, response) = try await NetworkSession.shared.data(for: request)
            }
            let http = response as? HTTPURLResponse
            let body = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
            let record: [String: Any] = ["http": http?.statusCode ?? 0, "body": body]
            let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try encoded.write(to: URL(fileURLWithPath: prefix + ".http-" + UUID().uuidString + ".json"), options: .atomic)
            return (raw, response)
        }
        let client = MistralClient(apiKey: key, model: LLMModel(id: "mistral-ocr-4-1"))
        let result = try await client.ocr(imageURL: input)
        let encoded = try JSONEncoder().encode(result)
        try encoded.write(to: URL(fileURLWithPath: prefix + ".json"), options: .atomic)
        print(result.text == nil ? "failed" : "completed")
    }
}
