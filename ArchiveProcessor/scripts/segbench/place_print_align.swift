// W46.place-print — the Vision OCR lab's own `Recogniser.alignedReading`, driven from a JSON of jobs (F-placement
// test 3: a position-free reader's text aligned onto Vision's lines).
//
// Compiled against the lab's sources rather than a replica of them, as place_geom_writer.swift is:
//
//     mkdir -p /tmp/ppa && cp place_print_align.swift /tmp/ppa/main.swift
//     swiftc -O -o /tmp/place_print_align -target "$(uname -m)-apple-macos13.0" \
//       $(ls ~/Claude/vision-ocr/Sources/*.swift | grep -v App.swift) /tmp/ppa/main.swift
//
//     place_print_align <jobs.json> <out.json>
//
// jobs.json: [{"id", "aspect" (height / width), "reading" (the model's whole-page text), "lines": [{"text", "box":
// [x, y, w, h]}]}], Vision's lines normalised with a top-left origin. The reading goes through the lab's
// `modelWords` (its Markdown, tags and table rules stripped) and then `alignedReading`, as `Recogniser` does on a
// page read by a model reader (arrangement b). out.json: [{"id", "words": the model words, "lines": [{"text",
// "box"}]}], the lines in the order given, each with its text as aligned (Vision's where the line was not rewritten).

import Foundation

struct Job: Decodable {
    struct Line: Decodable { let text: String; let box: [Double] }
    let id: String
    let aspect: Double
    let reading: String
    let lines: [Line]
}

let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]),
      let jobs = try? JSONDecoder().decode([Job].self, from: data) else {
    FileHandle.standardError.write("usage: place_print_align <jobs.json> <out.json>\n".data(using: .utf8)!)
    exit(2)
}
var out: [[String: Any]] = []
for job in jobs {
    let obs = job.lines.compactMap { l -> SearchableWriter.Observation? in
        guard l.box.count == 4, l.box[2] > 0, l.box[3] > 0 else { return nil }
        return SearchableWriter.Observation(
            boundingBox: .init(x: l.box[0], y: l.box[1], width: l.box[2], height: l.box[3]),
            text: l.text, confidence: 1)
    }
    let words = Recogniser.modelWords(job.reading)
    let aligned = Recogniser.alignedReading(of: obs, from: words, aspect: job.aspect)
    out.append(["id": job.id, "words": words,
                "lines": aligned.map { o -> [String: Any] in
                    ["text": o.text, "box": [o.boundingBox.x, o.boundingBox.y, o.boundingBox.width, o.boundingBox.height]]
                }])
}
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))
print("{\"jobs\": \(jobs.count)}")
