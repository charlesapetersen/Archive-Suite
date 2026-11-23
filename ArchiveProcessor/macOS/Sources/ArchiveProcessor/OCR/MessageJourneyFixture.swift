#if DEBUG
import Foundation
import ImageIO

/// Off-screen scratch journeys. Only a headless UI-test launch can substitute these replies.
enum MessageJourneyFixture {
    private static let mode = ProcessInfo.processInfo.environment["AP_MESSAGE_JOURNEY"]

    static let isActive = ProcessorUITestConfiguration.isActive
        && ProcessInfo.processInfo.environment["ARCHIVEPROC_HEADLESS"] == "1"
        && mode != nil

    static var inputTree: URL? {
        guard isActive, let out = ProcessorUITestConfiguration.outputDirectory else { return nil }
        switch mode {
        case "duplicates", "tree-levels": return out.deletingLastPathComponent().appendingPathComponent("in", isDirectory: true)
        case "tree-depth": return out.deletingLastPathComponent().appendingPathComponent(".in", isDirectory: true)
        default: return nil
        }
    }

    static func resetKeyWizardIfRequested() {
        guard isActive, mode == "key" else { return }
        UserDefaults.standard.removeObject(forKey: "keyValidated_OpenAI")
        UserDefaults.standard.removeObject(forKey: "keySaveFailed_OpenAI")
    }

    static func reply(to request: URLRequest) throws -> (Data, URLResponse) {
        guard let mode,
              let output = ProcessorUITestConfiguration.outputDirectory,
              let url = request.url, url.host == "api.openai.com" else {
            throw URLError(.unsupportedURL)
        }
        if mode == "key", request.httpMethod == "GET", url.path == "/v1/models" {
            let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), reply)
        }
        guard request.httpMethod == "POST", url.path == "/v1/chat/completions",
              let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String else {
            throw URLError(.unsupportedURL)
        }

        let id = UUID().uuidString
        let messages = json["messages"] as? [[String: Any]] ?? []
        let imageCount = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "image_url" }.count
        let rotation = imageCount == 4
        let status: Int
        let payload: [String: Any]
        if mode == "duplicates" {
            // The two same-named inputs have different orientations. Identify the page in the
            // reply from the image actually sent so the test can check each path-reason pair.
            guard let imagePart = messages.compactMap({ $0["content"] as? [[String: Any]] })
                    .flatMap({ $0 }).first(where: { $0["type"] as? String == "image_url" }),
                  let dataURL = (imagePart["image_url"] as? [String: String])?["url"],
                  let encoded = dataURL.split(separator: ",", maxSplits: 1).last,
                  let data = Data(base64Encoded: String(encoded)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = props[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = props[kCGImagePropertyPixelHeight as String] as? Int,
                  width != height else { throw URLError(.cannotDecodeContentData) }
            status = 400
            let orientation = width < height ? "portrait" : "landscape"
            payload = ["error": ["message": "Scratch refusal for the \(orientation) page"]]
        } else if rotation && mode == "rotation-fail" {
            status = 500
            payload = ["error": ["message": "Scratch refusal \(id)"]]
        } else {
            status = 200
            let reading = rotation ? "D" : "[document_start]\nA synthetic archival page."
            payload = ["choices": [["message": ["content": reading], "finish_reason": "stop"]]]
        }
        let record: [String: Any] = [
            "url": url.absoluteString, "model": model, "status": status, "images": imageCount,
            "max_tokens": json["max_tokens"] ?? NSNull(),
            "max_completion_tokens": json["max_completion_tokens"] ?? NSNull(),
        ]
        let log = output.deletingLastPathComponent().appendingPathComponent("calls", isDirectory: true)
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: log.appendingPathComponent(id), options: .atomic)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}
#endif
