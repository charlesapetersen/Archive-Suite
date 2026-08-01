import Foundation

/// **Provider response-shape contract for the three paid batch clients** (W16.bat1) — headless, $0,
/// no network, no keys. Every fixture below is a literal body of the kind Anthropic / Gemini / Mistral
/// return, fed to the pure parse seams in `BatchOCR.swift`.
///
/// Why this exists: the batch path is the only code in the app that spends real money, and until now
/// its *reading* of provider responses had no test at all. A provider changing a key, nesting a field
/// one level deeper, or renaming a state would not fail loudly — it would report a finished batch as
/// unfinished, or hand back an empty result set that the pipeline then marks consumed. The pages are
/// paid for either way. These checks pin the shapes the clients actually accept, including every
/// alternative spelling, so a divergence shows up here instead of in a bill.
///
/// Run from `BatchResumeTestDriver` (section 12) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`. Pure functions in, booleans out — no I/O, no state, no GUI.
enum BatchParseContract {

    static func run(check: (String, Bool) -> Void) {
        anthropicStatus(check)
        anthropicResults(check)
        geminiStatus(check)
        geminiInlinedResponses(check)
        geminiResultFileLocation(check)
        geminiResultFileJSONL(check)
        mistralStatus(check)
        mistralResults(check)
        errorBodies(check)
    }

    private static func bytes(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Anthropic: status

    private static func anthropicStatus(_ check: (String, Bool) -> Void) {
        let ended = try? AnthropicBatchClient.parseStatusBody(bytes("""
        {"id":"msgbatch_1","processing_status":"ended",
         "request_counts":{"processing":0,"succeeded":4,"errored":1,"expired":0,"canceled":0},
         "results_url":"https://api.anthropic.com/v1/messages/batches/msgbatch_1/results"}
        """))
        check("anthropic: `processing_status: ended` is the completion signal",
              ended?.isComplete == true)
        check("anthropic: per-state request counts are read, and total/completed derive from them",
              ended?.succeeded == 4 && ended?.errored == 1 && ended?.total == 5 && ended?.completed == 5)
        check("anthropic: the results URL is carried out of the status body",
              ended?.resultsURL?.hasSuffix("/results") == true)

        let inProgress = try? AnthropicBatchClient.parseStatusBody(bytes("""
        {"id":"msgbatch_1","processing_status":"in_progress",
         "request_counts":{"processing":3,"succeeded":2,"errored":0,"expired":0,"canceled":0}}
        """))
        check("anthropic: any status other than `ended` is still running (no premature retrieve)",
              inProgress?.isComplete == false && inProgress?.processing == 3)
        check("anthropic: a running batch has no results URL yet",
              inProgress?.resultsURL == nil)

        let bare = try? AnthropicBatchClient.parseStatusBody(bytes(#"{"id":"msgbatch_1"}"#))
        check("anthropic: a status body with no state and no counts reads as running with zeros",
              bare?.isComplete == false && bare?.total == 0)

        // Counts are read as JSON numbers only. Pinned as fact: were the provider to start quoting
        // them, the run would still finish correctly (isComplete drives the flow) but the progress
        // display would read 0 — a cosmetic, not a data, failure.
        let quotedCounts = try? AnthropicBatchClient.parseStatusBody(bytes("""
        {"processing_status":"ended","request_counts":{"succeeded":"4"}}
        """))
        check("anthropic: string-quoted counts read as 0 while completion still parses (display-only)",
              quotedCounts?.isComplete == true && quotedCounts?.succeeded == 0)

        var threw = false
        do { _ = try AnthropicBatchClient.parseStatusBody(bytes("not json at all")) } catch { threw = true }
        check("anthropic: a non-JSON status body throws instead of reporting a false state", threw)

        var threwOnArray = false
        do { _ = try AnthropicBatchClient.parseStatusBody(bytes("[1,2,3]")) } catch { threwOnArray = true }
        check("anthropic: a JSON array where an object belongs throws", threwOnArray)
    }

    // MARK: - Anthropic: results JSONL

    private static func anthropicResults(_ check: (String, Bool) -> Void) {
        let succeeded = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"[document_start]\\n[rotate_90]\\nDear Sir,"}]}}}
        """)
        check("anthropic: a succeeded line keys its result by the custom_id the app submitted",
              succeeded.count == 1 && succeeded["file-0"] != nil)
        check("anthropic: a succeeded line's tags are parsed off the text, not left in it",
              succeeded["file-0"]?.classification == .documentStart
              && succeeded["file-0"]?.rotationDegrees == 90
              && succeeded["file-0"]?.text == "Dear Sir,")
        check("anthropic: a succeeded line carries no error", succeeded["file-0"]?.errorMessage == nil)

        // Thinking mode returns a thinking block alongside the text block. Blocks are selected by
        // `type`, not by whether they happen to carry a `text` field — the second block below carries
        // one and must still be excluded, which is the whole point of filtering on type.
        let thinking = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[{"type":"thinking","thinking":"the page looks upside down"},{"type":"thinking","text":"internal reasoning"},{"type":"text","text":"page one"},{"type":"text","text":"page one continued"}]}}}
        """)
        check("anthropic: a non-text block is excluded by TYPE even when it carries a text field; text blocks join in order",
              thinking["file-0"]?.text == "page one\npage one continued")

        let errored = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-1","result":{"type":"errored","error":{"type":"invalid_request_error","message":"image exceeds 5 MB"}}}
        """)
        check("anthropic: an errored line becomes a failed result carrying the provider's message",
              errored["file-1"]?.text == nil && errored["file-1"]?.errorMessage == "image exceeds 5 MB")

        let noMessage = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-2","result":{"type":"expired"}}
        """)
        check("anthropic: an expired/unknown result type fails the page with a stated fallback reason",
              noMessage["file-2"]?.errorMessage == "Batch request failed")

        let noResult = AnthropicBatchClient.parseResultsJSONL(#"{"custom_id":"file-3"}"#)
        check("anthropic: a line with no `result` object fails that page rather than dropping it",
              noResult["file-3"]?.errorMessage == "Batch request failed")

        // One unreadable line must not cost the other paid pages in the same file.
        let mixed = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"first"}]}}}
        {"this line is not json

        {"result":{"type":"succeeded"}}
        {"custom_id":"file-2","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"third"}]}}}
        """)
        check("anthropic: a malformed line, a blank line and a line with no custom_id are skipped — the readable pages survive",
              mixed.count == 2 && mixed["file-0"]?.text == "first" && mixed["file-2"]?.text == "third")

        check("anthropic: an empty results body yields no results (and does not crash)",
              AnthropicBatchClient.parseResultsJSONL("").isEmpty)

        let untagged = AnthropicBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"plain transcription"}]}}}
        """)
        check("anthropic: text with no classification tag keeps its transcription and no rotation",
              untagged["file-0"]?.text == "plain transcription"
              && untagged["file-0"]?.classification == nil
              && untagged["file-0"]?.rotationDegrees == 0)
    }

    // MARK: - Gemini: status state + inline gating

    private static func geminiStatus(_ check: (String, Bool) -> Void) {
        let topLevel = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"name":"batches/abc","state":"BATCH_STATE_SUCCEEDED"}
        """))
        check("gemini: a top-level `state` is read", topLevel?.state == "BATCH_STATE_SUCCEEDED" && topLevel?.isComplete == true)

        let nested = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"name":"batches/abc","metadata":{"state":"JOB_STATE_SUCCEEDED"}}
        """))
        check("gemini: a `metadata.state` is read (the same batch under the other envelope)",
              nested?.state == "JOB_STATE_SUCCEEDED" && nested?.isComplete == true)

        let both = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_RUNNING","metadata":{"state":"JOB_STATE_SUCCEEDED"}}
        """))
        check("gemini: when both envelopes carry a state, `metadata` wins (documented precedence)",
              both?.state == "JOB_STATE_SUCCEEDED")

        let completed = ["BATCH_STATE_SUCCEEDED", "BATCH_STATE_FAILED", "BATCH_STATE_CANCELLED",
                         "BATCH_STATE_EXPIRED", "JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED",
                         "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED"]
        let allComplete = completed.allSatisfy { state in
            (try? GeminiBatchClient.parseStatusBody(bytes(#"{"state":"\#(state)"}"#)))?.isComplete == true
        }
        check("gemini: all eight terminal states (BATCH_ and JOB_ vocabularies) end the poll", allComplete)

        let running = ["JOB_STATE_RUNNING", "JOB_STATE_PENDING", "BATCH_STATE_PENDING", "JOB_STATE_UNSPECIFIED"]
        let noneComplete = running.allSatisfy { state in
            (try? GeminiBatchClient.parseStatusBody(bytes(#"{"state":"\#(state)"}"#)))?.isComplete == false
        }
        check("gemini: in-flight states do not end the poll", noneComplete)

        let stateless = try? GeminiBatchClient.parseStatusBody(bytes(#"{"name":"batches/abc"}"#))
        check("gemini: a state-less body reads as empty-and-running, never as done",
              stateless?.state == "" && stateless?.isComplete == false)

        // Inline results are only read once the batch is terminal — a mid-flight partial must not be
        // mistaken for the finished set.
        let runningWithInline = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_RUNNING","response":{"inlinedResponses":{"inlinedResponses":[
          {"metadata":{"key":"0"},"response":{"candidates":[{"content":{"parts":[{"text":"half a batch"}]}}]}}]}}}
        """))
        check("gemini: inline results present on a RUNNING batch are ignored until it is terminal",
              runningWithInline?.inlineResults == nil)

        let responseEnvelope = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_SUCCEEDED","response":{"inlinedResponses":{"inlinedResponses":[
          {"metadata":{"key":"0"},"response":{"candidates":[{"content":{"parts":[{"text":"from response"}]}}]}}]}}}
        """))
        check("gemini: inline results under `response.inlinedResponses.inlinedResponses` are read",
              responseEnvelope?.inlineResults?["file-0"]?.text == "from response")

        let metadataEnvelope = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"metadata":{"state":"BATCH_STATE_SUCCEEDED","output":{"inlinedResponses":{"inlinedResponses":[
          {"metadata":{"key":"0"},"response":{"candidates":[{"content":{"parts":[{"text":"from metadata"}]}}]}}]}}}}
        """))
        check("gemini: inline results under `metadata.output.inlinedResponses.inlinedResponses` are read",
              metadataEnvelope?.inlineResults?["file-0"]?.text == "from metadata")

        let bothEnvelopes = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_SUCCEEDED",
         "response":{"inlinedResponses":{"inlinedResponses":[
           {"metadata":{"key":"0"},"response":{"candidates":[{"content":{"parts":[{"text":"from response"}]}}]}}]}},
         "metadata":{"output":{"inlinedResponses":{"inlinedResponses":[
           {"metadata":{"key":"0"},"response":{"candidates":[{"content":{"parts":[{"text":"from metadata"}]}}]}}]}}}}
        """))
        check("gemini: when both inline envelopes are present, `response` wins (documented precedence)",
              bothEnvelopes?.inlineResults?["file-0"]?.text == "from response")

        let noInline = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_SUCCEEDED","metadata":{"dest":{"fileName":"files/out-1"}}}
        """))
        check("gemini: a terminal batch with no inline container leaves inlineResults nil so the result FILE is fetched",
              noInline?.inlineResults == nil && noInline?.resultFileName == "files/out-1")

        // ⚠️ Pinned hazard, not an endorsement: an EMPTY inlined container parses to a non-nil empty
        // dictionary, and the poll's `if let inline = status.inlineResults { … } else if let file = …`
        // then skips the result-file fallback and marks the paid chunk consumed with zero pages.
        // Filed as W16.bat1-fu — this check exists so the behaviour cannot change unnoticed either way.
        let emptyInline = try? GeminiBatchClient.parseStatusBody(bytes("""
        {"state":"JOB_STATE_SUCCEEDED","response":{"inlinedResponses":{"inlinedResponses":[]}},
         "metadata":{"dest":{"fileName":"files/out-1"}}}
        """))
        check("gemini: an EMPTY inline container parses to a non-nil empty set — shadowing the result file (W16.bat1-fu)",
              emptyInline?.inlineResults != nil && emptyInline?.inlineResults?.isEmpty == true)

        var threw = false
        do { _ = try GeminiBatchClient.parseStatusBody(bytes("<html>502 Bad Gateway</html>")) } catch { threw = true }
        check("gemini: an HTML error page where JSON belongs throws instead of reading as running", threw)
    }

    // MARK: - Gemini: inlined response entries

    private static func geminiInlinedResponses(_ check: (String, Bool) -> Void) {
        let numericKey = GeminiBatchClient.parseInlinedResponses([
            ["metadata": ["key": "0"],
             "response": ["candidates": [["content": ["parts": [["text": "[box_label]\nBox 12"]]]]]]]
        ])
        check("gemini: a bare numeric key is normalized to the app's `file-N` identity",
              numericKey["file-0"]?.text == "Box 12" && numericKey["file-0"]?.classification == .boxLabel)

        let prefixedKey = GeminiBatchClient.parseInlinedResponses([
            ["metadata": ["key": "file-3"],
             "response": ["candidates": [["content": ["parts": [["text": "already prefixed"]]]]]]]
        ])
        check("gemini: an already-prefixed key is left alone (no `file-file-3`)",
              prefixedKey["file-3"]?.text == "already prefixed" && prefixedKey.count == 1)

        let keyless = GeminiBatchClient.parseInlinedResponses([
            ["response": ["candidates": [["content": ["parts": [["text": "orphan"]]]]]]],
            ["metadata": ["key": ""], "response": ["candidates": []]],
            ["metadata": ["key": "1"], "response": ["candidates": [["content": ["parts": [["text": "kept"]]]]]]]
        ])
        check("gemini: entries with a missing or empty key are dropped — an unattributable page is never misfiled onto another",
              keyless.count == 1 && keyless["file-1"]?.text == "kept")

        let errorEntry = GeminiBatchClient.parseInlinedResponses([
            ["metadata": ["key": "2"], "error": ["code": 429, "message": "Resource has been exhausted"]]
        ])
        check("gemini: an entry-level error becomes a failed page with the provider's message and numeric code",
              errorEntry["file-2"]?.errorMessage == "Resource has been exhausted"
              && errorEntry["file-2"]?.errorCode == "429"
              && errorEntry["file-2"]?.text == nil)

        let codelessError = GeminiBatchClient.parseInlinedResponses([
            ["metadata": ["key": "2"], "error": ["message": "unspecified"]],
            ["metadata": ["key": "3"], "error": ["code": "RESOURCE_EXHAUSTED"]]
        ])
        check("gemini: an error with no code, and a non-numeric code, both still fail the page",
              codelessError["file-2"]?.errorCode == nil
              && codelessError["file-3"]?.errorMessage == "Batch request failed"
              && codelessError["file-3"]?.errorCode == nil)

        let noResponse = GeminiBatchClient.parseInlinedResponses([["metadata": ["key": "4"]]])
        check("gemini: an entry with neither error nor response fails that page explicitly",
              noResponse["file-4"]?.errorMessage == "No response in batch entry")

        check("gemini: an empty inlined array parses to an empty set",
              GeminiBatchClient.parseInlinedResponses([]).isEmpty)

        // parseSingleResponse — the shape both the inline and the file path funnel through.
        let blocked = GeminiBatchClient.parseSingleResponse(
            ["promptFeedback": ["blockReason": "SAFETY"], "candidates": [["content": ["parts": [["text": "ignored"]]]]]])
        check("gemini: a prompt-level blockReason wins over any candidate text and names the reason",
              blocked.text == nil && blocked.errorCode == "SAFETY"
              && blocked.errorMessage == "Content blocked by Gemini: SAFETY")

        let recitation = GeminiBatchClient.parseSingleResponse(
            ["candidates": [["finishReason": "RECITATION"]]])
        check("gemini: a RECITATION finish is reported as a refusal, not as an empty transcription",
              recitation.text == nil && recitation.errorCode == "Recitation"
              && recitation.errorMessage?.contains("Recitation") == true)

        let otherFinish = GeminiBatchClient.parseSingleResponse(
            ["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "truncated page"]]]]]])
        check("gemini: a non-RECITATION finish reason keeps whatever text was returned",
              otherFinish.text == "truncated page" && otherFinish.errorMessage == nil)

        check("gemini: a response with no candidates fails the page explicitly",
              GeminiBatchClient.parseSingleResponse(["candidates": []]).errorMessage == "No candidates in response")
        check("gemini: a candidate with no content parts fails the page explicitly",
              GeminiBatchClient.parseSingleResponse(["candidates": [["finishReason": "STOP"]]]).errorMessage
                == "No content parts in response")

        let multiPart = GeminiBatchClient.parseSingleResponse(
            ["candidates": [["content": ["parts": [["text": "[document_continuation]"], ["text": "line one"], ["inlineData": ["mimeType": "image/png"]], ["text": "line two"]]]]]])
        check("gemini: multiple text parts join in order, non-text parts are skipped, and the tag is stripped",
              multiPart.classification == .documentContinuation && multiPart.text == "line one\nline two")
    }

    // MARK: - Gemini: the six result-file spellings

    private static func geminiResultFileLocation(_ check: (String, Bool) -> Void) {
        func fileName(_ body: String) -> String? {
            (try? GeminiBatchClient.parseStatusBody(bytes(body)))?.resultFileName
        }
        let spellings: [(String, String)] = [
            ("metadata.dest.file_name",
             #"{"state":"JOB_STATE_SUCCEEDED","metadata":{"dest":{"file_name":"files/out"}}}"#),
            ("metadata.dest.fileName",
             #"{"state":"JOB_STATE_SUCCEEDED","metadata":{"dest":{"fileName":"files/out"}}}"#),
            ("metadata.outputConfig.file_name",
             #"{"state":"JOB_STATE_SUCCEEDED","metadata":{"outputConfig":{"file_name":"files/out"}}}"#),
            ("metadata.outputConfig.fileName",
             #"{"state":"JOB_STATE_SUCCEEDED","metadata":{"outputConfig":{"fileName":"files/out"}}}"#),
            ("dest.file_name",
             #"{"state":"JOB_STATE_SUCCEEDED","dest":{"file_name":"files/out"}}"#),
            ("dest.fileName",
             #"{"state":"JOB_STATE_SUCCEEDED","dest":{"fileName":"files/out"}}"#)
        ]
        for (label, body) in spellings {
            check("gemini: the result file is found at \(label)", fileName(body) == "files/out")
        }
        check("gemini: all six result-file spellings are covered above", spellings.count == 6)

        // Precedence, walked down the whole ladder: each rung is only consulted once every rung above
        // it is absent. A body carrying several spellings must resolve to exactly one file.
        let allSix = fileName("""
        {"state":"JOB_STATE_SUCCEEDED","dest":{"file_name":"5th","fileName":"6th"},
         "metadata":{"dest":{"file_name":"1st","fileName":"2nd"},
                     "outputConfig":{"file_name":"3rd","fileName":"4th"}}}
        """)
        let withoutFirst = fileName("""
        {"state":"JOB_STATE_SUCCEEDED","dest":{"file_name":"5th","fileName":"6th"},
         "metadata":{"dest":{"fileName":"2nd"},"outputConfig":{"file_name":"3rd","fileName":"4th"}}}
        """)
        let withoutMetaDest = fileName("""
        {"state":"JOB_STATE_SUCCEEDED","dest":{"file_name":"5th","fileName":"6th"},
         "metadata":{"outputConfig":{"file_name":"3rd","fileName":"4th"}}}
        """)
        let onlyTopLevel = fileName(#"{"state":"JOB_STATE_SUCCEEDED","dest":{"file_name":"5th","fileName":"6th"}}"#)
        check("gemini: the six spellings resolve in a fixed order — metadata.dest, then outputConfig, then top-level dest",
              allSix == "1st" && withoutFirst == "2nd" && withoutMetaDest == "3rd" && onlyTopLevel == "5th")
        check("gemini: a terminal batch with neither inline results nor any file spelling reports no file (rather than a wrong one)",
              fileName(#"{"state":"JOB_STATE_SUCCEEDED"}"#) == nil)
    }

    // MARK: - Gemini: downloaded result file (JSONL)

    private static func geminiResultFileJSONL(_ check: (String, Bool) -> Void) {
        let ok = GeminiBatchClient.parseResultsJSONL("""
        {"key":"0","response":{"candidates":[{"content":{"parts":[{"text":"[folder_label]\\nCorrespondence"}]}}]}}
        {"key":"file-1","response":{"candidates":[{"content":{"parts":[{"text":"second page"}]}}]}}
        """)
        check("gemini file: both key forms normalize to the app's identity, and tags are parsed",
              ok.count == 2 && ok["file-0"]?.classification == .folderLabel
              && ok["file-0"]?.text == "Correspondence" && ok["file-1"]?.text == "second page")

        // The download path also accepts a line that IS the response (no "response" wrapper).
        let unwrapped = GeminiBatchClient.parseResultsJSONL("""
        {"key":"0","candidates":[{"content":{"parts":[{"text":"unwrapped"}]}}]}
        """)
        check("gemini file: a line with no `response` wrapper is parsed as the response itself",
              unwrapped["file-0"]?.text == "unwrapped")

        let errored = GeminiBatchClient.parseResultsJSONL("""
        {"key":"2","error":{"code":400,"message":"invalid image"}}
        """)
        check("gemini file: a line-level error becomes a failed page with message and code",
              errored["file-2"]?.errorMessage == "invalid image" && errored["file-2"]?.errorCode == "400")

        let mixed = GeminiBatchClient.parseResultsJSONL("""
        {"key":"0","response":{"candidates":[{"content":{"parts":[{"text":"first"}]}}]}}
        {"response":{"candidates":[]}}
        {"key":"","response":{"candidates":[]}}
        {oh dear

        {"key":"3","response":{"candidates":[{"content":{"parts":[{"text":"fourth"}]}}]}}
        """)
        check("gemini file: keyless, empty-keyed, malformed and blank lines are skipped — the rest of the paid file survives",
              mixed.count == 2 && mixed["file-0"]?.text == "first" && mixed["file-3"]?.text == "fourth")

        check("gemini file: an empty download yields no results",
              GeminiBatchClient.parseResultsJSONL("").isEmpty)

        let blockedInFile = GeminiBatchClient.parseResultsJSONL("""
        {"key":"0","response":{"promptFeedback":{"blockReason":"OTHER"}}}
        """)
        check("gemini file: a blocked page in the download reports the block, not an empty transcription",
              blockedInFile["file-0"]?.errorCode == "OTHER" && blockedInFile["file-0"]?.text == nil)
    }

    // MARK: - Mistral: status

    private static func mistralStatus(_ check: (String, Bool) -> Void) {
        let success = try? MistralBatchClient.parseStatusBody(bytes("""
        {"id":"job-1","status":"SUCCESS","total_requests":5,"completed_requests":5,
         "succeeded_requests":4,"failed_requests":1,"output_file":"file-out-1"}
        """))
        check("mistral: SUCCESS ends the poll and the output file id is carried out",
              success?.isComplete == true && success?.outputFileId == "file-out-1")
        check("mistral: the four request counters are read",
              success?.totalRequests == 5 && success?.completedRequests == 5
              && success?.succeededRequests == 4 && success?.failedRequests == 1)

        let terminal = ["SUCCESS", "FAILED", "TIMEOUT_EXCEEDED", "CANCELLATION_REQUESTED", "CANCELLED"]
        let allTerminal = terminal.allSatisfy { status in
            (try? MistralBatchClient.parseStatusBody(bytes(#"{"status":"\#(status)"}"#)))?.isComplete == true
        }
        check("mistral: all five terminal statuses end the poll", allTerminal)

        let live = ["QUEUED", "RUNNING", "success", ""]
        let noneTerminal = live.allSatisfy { status in
            (try? MistralBatchClient.parseStatusBody(bytes(#"{"status":"\#(status)"}"#)))?.isComplete == false
        }
        check("mistral: queued/running — and a case-shifted `success` — do not end the poll", noneTerminal)

        let bare = try? MistralBatchClient.parseStatusBody(bytes(#"{"id":"job-1"}"#))
        check("mistral: a status-less body reads as running with zero counts and no output file",
              bare?.isComplete == false && bare?.status == "" && bare?.totalRequests == 0
              && bare?.outputFileId == nil)

        var threw = false
        do { _ = try MistralBatchClient.parseStatusBody(bytes("")) } catch { threw = true }
        check("mistral: an empty status body throws instead of reading as running", threw)
    }

    // MARK: - Mistral: results JSONL

    private static func mistralResults(_ check: (String, Bool) -> Void) {
        let pages = MistralBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","response":{"status_code":200,"body":{"pages":[{"markdown":"Box No. 12, Record Group 59"},{"markdown":"second page"}]}}}
        """)
        check("mistral: a 200 line joins every page's markdown (blank line between pages)",
              pages["file-0"]?.text == "Box No. 12, Record Group 59\n\nsecond page")
        check("mistral: a 200 line is classified heuristically (the OCR endpoint returns no tag) with no rotation",
              pages["file-0"]?.classification == .boxLabel && pages["file-0"]?.rotationDegrees == 0
              && pages["file-0"]?.errorMessage == nil)

        let textBody = MistralBatchClient.parseResultsJSONL("""
        {"custom_id":"file-1","response":{"status_code":200,"body":{"text":"plain body text"}}}
        """)
        check("mistral: a body with `text` instead of `pages` is accepted (fallback shape)",
              textBody["file-1"]?.text == "plain body text")

        let emptyPages = MistralBatchClient.parseResultsJSONL("""
        {"custom_id":"file-2","response":{"status_code":200,"body":{"pages":[]}}}
        {"custom_id":"file-3","response":{"status_code":200,"body":{"pages":[{"markdown":""}]}}}
        """)
        check("mistral: a 200 with no page text yields nil text rather than an empty transcription",
              emptyPages["file-2"]?.text == nil && emptyPages["file-3"]?.text == nil
              && emptyPages["file-2"]?.classification == .documentStart)

        let errors = MistralBatchClient.parseResultsJSONL("""
        {"custom_id":"file-4","response":{"status_code":422,"body":{"message":"unprocessable image"}}}
        {"custom_id":"file-5","response":{"status_code":500,"body":{"error":{"message":"internal"}}}}
        {"custom_id":"file-6","response":{"status_code":429,"body":{}}}
        """)
        check("mistral: a non-200 line reads a top-level message, then a nested error.message, then a stated fallback",
              errors["file-4"]?.errorMessage == "unprocessable image"
              && errors["file-5"]?.errorMessage == "internal"
              && errors["file-6"]?.errorMessage == "Batch request failed")
        check("mistral: a non-200 line carries the HTTP status as the error code and no text",
              errors["file-4"]?.errorCode == "422" && errors["file-5"]?.errorCode == "500"
              && errors["file-4"]?.text == nil)

        let noResponse = MistralBatchClient.parseResultsJSONL(#"{"custom_id":"file-7"}"#)
        check("mistral: a line with no response object fails that page with no status code",
              noResponse["file-7"]?.errorMessage == "Batch request failed"
              && noResponse["file-7"]?.errorCode == nil)

        let mixed = MistralBatchClient.parseResultsJSONL("""
        {"custom_id":"file-0","response":{"status_code":200,"body":{"pages":[{"markdown":"first"}]}}}
        {"response":{"status_code":200,"body":{"pages":[{"markdown":"orphan"}]}}}
        {"custom_id":

        {"custom_id":"file-2","response":{"status_code":200,"body":{"pages":[{"markdown":"third"}]}}}
        """)
        check("mistral: keyless, malformed and blank lines are skipped — the readable paid pages survive",
              mixed.count == 2 && mixed["file-0"]?.text == "first" && mixed["file-2"]?.text == "third")

        check("mistral: an empty output file yields no results",
              MistralBatchClient.parseResultsJSONL("").isEmpty)
    }

    // MARK: - Shared HTTP error body

    private static func errorBodies(_ check: (String, Bool) -> Void) {
        check("error body: Mistral's top-level `message` is used",
              parseBatchErrorBody(data: bytes(#"{"message":"Invalid API key"}"#), statusCode: 401)
                == "Invalid API key")
        check("error body: Anthropic/Gemini's nested `error.message` is used",
              parseBatchErrorBody(data: bytes(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
                                  statusCode: 401) == "invalid x-api-key")
        check("error body: a top-level message wins over a nested one (documented precedence)",
              parseBatchErrorBody(data: bytes(#"{"message":"top","error":{"message":"nested"}}"#), statusCode: 400)
                == "top")
        check("error body: an unrecognized JSON shape falls back to the status code, never to silence",
              parseBatchErrorBody(data: bytes(#"{"detail":[{"loc":"body"}]}"#), statusCode: 422)
                == "API error (422)")
        check("error body: a non-JSON body (HTML gateway page) falls back to the status code",
              parseBatchErrorBody(data: bytes("<html>503 Service Unavailable</html>"), statusCode: 503)
                == "API error (503)")
        check("error body: an empty body falls back to the status code",
              parseBatchErrorBody(data: Data(), statusCode: 500) == "API error (500)")
    }
}
