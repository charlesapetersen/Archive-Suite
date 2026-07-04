import Foundation
import UserNotifications

extension OCRProcessor {
    /// Rebuild `segments` from current job classifications, excluding user-removed files.
    func rebuildSegments(files: [URL]) {
        let segmenter = DocumentSegmenter()
        var activeFiles: [URL] = []
        var classifications: [DocumentClassification?] = []
        var texts: [String] = []
        for (i, url) in files.enumerated() {
            if removedSourceURLs.contains(url) { continue }
            activeFiles.append(url)
            classifications.append(i < jobs.count ? jobs[i].result?.classification : nil)
            texts.append(i < jobs.count ? (jobs[i].result?.text ?? "") : "")
        }
        segments = segmenter.segment(files: activeFiles, classifications: classifications, texts: texts)
    }
    /// Apply Live-Capture group boundaries/types to job classifications, so segmentation uses
    /// the phone's grouping instead of the LLM. Boundaries → documentStart/continuation;
    /// box/folder types → the corresponding label classification.
    func applyPreGroupedClassifications(files: [URL]) {
        for i in files.indices where i < jobs.count {
            let type = i < preGroupedTypes.count ? preGroupedTypes[i] : .document
            let isStart = i < preGroupedBoundaries.count ? preGroupedBoundaries[i] : true
            let cls: DocumentClassification
            switch type {
            case .box: cls = .boxLabel
            case .folder: cls = .folderLabel
            case .document: cls = isStart ? .documentStart : .documentContinuation
            }
            jobs[i].classification = cls
            if let r = jobs[i].result {
                jobs[i].result = OCRResult(text: r.text, classification: cls,
                                           rotationDegrees: r.rotationDegrees,
                                           errorMessage: r.errorMessage, errorCode: nil)
            }
        }
    }
    func performCollectionSegmentation(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        confirmBeforeOrganizing: Bool = false,
        reviewDocumentSegmentation: Bool = false
    ) async {
        statusMessage = "Identifying collections from box labels…"

        let classifications = jobs.map { $0.result?.classification }
        let texts = jobs.map { $0.result?.text ?? "" }

        let segmenter = CollectionSegmenter()
        collectionSegments = await segmenter.segment(
            files: files,
            classifications: classifications,
            texts: texts,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            gatewayConfig: currentGateway,
            onStatus: { [weak self] msg in
                self?.statusMessage = msg
            }
        )

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        // If confirmation is requested, build review items and wait for user
        if confirmBeforeOrganizing {
            let hasBoxes = classifications.contains(where: { $0 == .boxLabel })
            buildReviewItems(files: files, classifications: classifications)
            if !hasBoxes {
                noBoxCollectionName = collectionSegments.first?.collectionName ?? "Uncategorized"
            }
            statusMessage = "Review collection names before proceeding."
            awaitingCollectionConfirmation = true

            // Suspend until the user confirms
            await withCheckedContinuation { continuation in
                collectionConfirmationContinuation = continuation
            }

            guard !Task.isCancelled else { return }

            if !hasBoxes {
                // No boxes — apply user-provided collection name
                let name = noBoxCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                collectionSegments = [CollectionSegment(collectionName: name.isEmpty ? "Uncategorized" : name, fileURLs: files)]
            } else {
                // Apply user edits: rebuild collectionSegments from reviewItems
                applyReviewEdits(files: files)
            }
        }

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        // Document segmentation review: present per-collection dialogs sequentially
        if reviewDocumentSegmentation {
            await performDocumentSegmentationReview(files: files, outputDirectory: outputDirectory)
            guard !Task.isCancelled else { return }
        }

    }
    /// Build review items from current classifications and collection segments.
    /// Only includes box labels — segmentation is already finalized at this point.
    private func buildReviewItems(files: [URL], classifications: [DocumentClassification?]) {
        // Build a map from file URL to collection name using the current segments
        var fileToCollection: [URL: String] = [:]
        for segment in collectionSegments {
            for url in segment.fileURLs {
                fileToCollection[url] = segment.collectionName
            }
        }

        // Only include box labels for collection name review
        collectionReviewItems = files.enumerated().compactMap { (index, url) in
            let cls = index < classifications.count ? classifications[index] : nil
            guard cls == .boxLabel else { return nil }
            let collection = fileToCollection[url] ?? "Uncategorized"
            return CollectionReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                collectionName: collection,
                isBoxLabel: true
            )
        }
    }
    /// Apply user edits from review items back into collectionSegments.
    /// Rebuilds segmentation from scratch using the confirmed box/folder identifications.
    /// Also updates macOS Finder tags to reflect reclassifications.
    private func applyReviewEdits(files: [URL]) {
        // Build a lookup from file index to the reviewed item
        var reviewByIndex: [Int: CollectionReviewItem] = [:]
        for item in collectionReviewItems {
            reviewByIndex[item.fileIndex] = item
        }

        // Update job classifications and re-tag files whose classification changed
        for item in collectionReviewItems {
            if item.fileIndex < jobs.count {
                let oldClassification = jobs[item.fileIndex].classification
                let newClassification = item.classification
                jobs[item.fileIndex].classification = newClassification
                if let existingResult = jobs[item.fileIndex].result {
                    jobs[item.fileIndex].result = OCRResult(
                        text: existingResult.text,
                        classification: newClassification,
                        rotationDegrees: existingResult.rotationDegrees,
                        errorMessage: existingResult.errorMessage,
                        errorCode: nil
                    )
                }

                // Re-tag the output file if classification changed
                if oldClassification != newClassification,
                   let outputURL = outputURLMap[item.fileURL] {
                    let colorTag: String? = {
                        switch newClassification {
                        case .boxLabel: return "Red"
                        case .folderLabel: return "Purple"
                        default: return nil
                        }
                    }()
                    // Build updated tags: keep existing non-color tags, replace color
                    var existingTags = jobs[item.fileIndex].appliedTags
                    existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
                    if let color = colorTag {
                        existingTags.append(color)
                    }
                    if newClassification == .boxLabel {
                        if !existingTags.contains("Box") { existingTags.insert("Box", at: 0) }
                    } else if newClassification == .folderLabel {
                        if !existingTags.contains("Folder") { existingTags.insert("Folder", at: 0) }
                    }
                    try? MacOSTagger.applyTags(existingTags, to: outputURL)
                    jobs[item.fileIndex].appliedTags = existingTags
                }
            }
        }

        // Find box labels in order (user may have reclassified some)
        let boxIndices = collectionReviewItems
            .filter { $0.classification == .boxLabel }
            .sorted { $0.fileIndex < $1.fileIndex }

        guard !boxIndices.isEmpty else {
            // No boxes left — put everything in one collection
            collectionSegments = [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
            return
        }

        // Walk all files, assigning each to the collection of the preceding box label
        var currentCollection = boxIndices[0].collectionName
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for i in 0..<files.count {
            if let reviewed = reviewByIndex[i], reviewed.classification == .boxLabel {
                currentCollection = reviewed.collectionName
            }
            if collectionFiles[currentCollection] == nil {
                collectionOrder.append(currentCollection)
                collectionFiles[currentCollection] = []
            }
            collectionFiles[currentCollection]!.append(files[i])
        }

        collectionSegments = collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }
    /// Called by the UI when the user confirms the collection review.
    func confirmCollectionReview() {
        awaitingCollectionConfirmation = false
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
    }
    /// Present document segmentation review dialogs for each collection sequentially.
    private func performDocumentSegmentationReview(files: [URL], outputDirectory: URL) async {
        var needsCollectionRebuild = false

        // Iterate over a snapshot of collections (may change if user reclassifies)
        let collectionsSnapshot = collectionSegments

        for collection in collectionsSnapshot {
            guard !Task.isCancelled else { return }

            let classifications = jobs.map { $0.result?.classification }

            // Build review items for all files in this collection (skip box/folder labels)
            let items: [DocumentReviewItem] = collection.fileURLs.compactMap { url in
                guard let idx = files.firstIndex(of: url) else { return nil }
                let cls = idx < classifications.count ? classifications[idx] : nil
                guard cls != .boxLabel && cls != .folderLabel else { return nil }
                let rot = idx < jobs.count ? (jobs[idx].result?.rotationDegrees ?? 0) : 0
                return DocumentReviewItem(
                    fileIndex: idx,
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    classification: cls,
                    rotationDegrees: rot
                )
            }

            guard !items.isEmpty else { continue }

            documentReviewItems = items.sorted { $0.fileIndex < $1.fileIndex }
            reviewRotationOnly = false
            currentReviewCollectionName = collection.collectionName
            statusMessage = "Review document segmentation for \"\(collection.collectionName)\"."
            awaitingDocumentReview = true

            await withCheckedContinuation { continuation in
                documentReviewContinuation = continuation
            }

            guard !Task.isCancelled else { return }

            // Apply changes from review
            let changed = applyDocumentReviewEdits(outputDirectory: outputDirectory)
            if changed { needsCollectionRebuild = true }
        }

        // If any files were reclassified as box/folder, rebuild collection segments
        if needsCollectionRebuild {
            rebuildCollectionSegments(files: files)
        }
    }
    /// Called by the UI when the user confirms document segmentation review for a collection.
    func confirmDocumentReview() {
        awaitingDocumentReview = false
        documentReviewContinuation?.resume()
        documentReviewContinuation = nil
    }
    /// Called by the UI when the user completes the final review.
    func confirmFinalReview() {
        awaitingFinalReview = false
        finalReviewContinuation?.resume(returning: .complete)
        finalReviewContinuation = nil
    }
    /// Called by the UI when the user wants to redo segmentation and tagging.
    func redoTagging() {
        awaitingFinalReview = false
        finalReviewContinuation?.resume(returning: .redoTagging)
        finalReviewContinuation = nil
    }
    /// Update classification for a single file (used by inline editing from the file pane).
    func updateClassification(at index: Int, to newClassification: DocumentClassification) {
        guard index < jobs.count else { return }
        let oldClassification = jobs[index].classification
        jobs[index].classification = newClassification
        if let existingResult = jobs[index].result {
            jobs[index].result = OCRResult(
                text: existingResult.text,
                classification: newClassification,
                rotationDegrees: existingResult.rotationDegrees,
                errorMessage: existingResult.errorMessage,
                errorCode: nil
            )
        }
        // Update tags on the output file
        if oldClassification != newClassification,
           let outputURL = outputURLMap[jobs[index].sourceURL] {
            let colorTag: String? = {
                switch newClassification {
                case .boxLabel: return "Red"
                case .folderLabel: return "Purple"
                default: return nil
                }
            }()
            var existingTags = jobs[index].appliedTags
            existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
            if let color = colorTag { existingTags.append(color) }
            if newClassification == .boxLabel {
                if !existingTags.contains("Box") { existingTags.insert("Box", at: 0) }
            } else if newClassification == .folderLabel {
                if !existingTags.contains("Folder") { existingTags.insert("Folder", at: 0) }
            }
            try? MacOSTagger.applyTags(existingTags, to: outputURL)
            jobs[index].appliedTags = existingTags
        }
    }
    /// Dedicated, standalone rotation-review pass (separate from the tagging/segmentation review).
    /// Shows every page with a rotation control; on confirm, writes the chosen rotation into each job
    /// and regenerates the output PDF where it changed, so the exported JPG (written later) matches.
    func showRotationReview(files: [URL]) async {
        documentReviewItems = files.enumerated().map { (index, url) in
            let cls = index < jobs.count ? jobs[index].result?.classification : nil
            let rot = index < jobs.count ? (jobs[index].result?.rotationDegrees ?? 0) : 0
            return DocumentReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                rotationDegrees: rot
            )
        }

        reviewRotationOnly = true
        reviewShowsDocumentClasses = false
        currentReviewCollectionName = "All Files"
        statusMessage = "Review rotation."
        awaitingDocumentReview = true

        await withCheckedContinuation { continuation in
            documentReviewContinuation = continuation
        }
        reviewRotationOnly = false

        guard !Task.isCancelled else { return }

        // Apply rotation changes back to jobs and regenerate the affected output PDFs.
        for item in documentReviewItems {
            guard item.fileIndex < jobs.count else { continue }
            let newRot = item.rotationDegrees
            let oldRot = jobs[item.fileIndex].result?.rotationDegrees ?? 0
            guard newRot != oldRot, let existingResult = jobs[item.fileIndex].result else { continue }
            jobs[item.fileIndex].result = OCRResult(
                text: existingResult.text,
                classification: existingResult.classification,
                rotationDegrees: newRot,
                errorMessage: existingResult.errorMessage,
                errorCode: existingResult.errorCode
            )
            if let result = jobs[item.fileIndex].result,
               let outputURL = outputURLMap[jobs[item.fileIndex].sourceURL],
               let model = currentModel {
                let pdfGen = PDFGenerator()
                // Use the temp JPEG if this was a PDF input, otherwise the original file.
                let imageURL = pdfToImageMap[item.fileURL] ?? item.fileURL
                try? pdfGen.generate(
                    imageURL: imageURL,
                    result: result,
                    model: model,
                    outputURL: outputURL,
                    originalFileName: jobs[item.fileIndex].sourceURL.lastPathComponent,
                    gatewayDisplayName: currentGateway?.displayName,
                    pdfImageMB: Self.pdfImageMB
                )
                // Regenerating rewrites the file, dropping its Finder tags. In copy-source mode the
                // tags were applied during OCR and nothing re-applies them later, so restore them now.
                // (Other modes apply tags in the later tagging phase, so appliedTags is empty here.)
                if passSourceTags {
                    try? MacOSTagger.applyTags(jobs[item.fileIndex].appliedTags, to: outputURL)
                }
            }
        }
    }
    /// Show the document segmentation review dialog for all files at once.
    /// Populates documentReviewItems with every file and suspends until user confirms.
    /// Rotation is NOT edited here — it is a separate, earlier pass (`showRotationReview`); the
    /// already-chosen rotation is carried on each item purely so the thumbnails preview upright.
    func showFullSegmentationReview(files: [URL]) async {
        documentReviewItems = files.enumerated().map { (index, url) in
            let cls = index < jobs.count ? jobs[index].result?.classification : nil
            let rot = index < jobs.count ? (jobs[index].result?.rotationDegrees ?? 0) : 0
            return DocumentReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                rotationDegrees: rot
            )
        }

        // New-Document / Continuation options are only meaningful when merging or when an
        // LLM-segmented tagging mode is used. In manual-segmentation modes the dedicated
        // grouping UI owns segmentation, so the review shows only box/folder.
        reviewRotationOnly = false
        reviewShowsDocumentClasses = mergeDocuments || taggingMode.showsDocumentClassesInReview
        currentReviewCollectionName = "All Files"
        statusMessage = "Review document segmentation."
        awaitingDocumentReview = true

        await withCheckedContinuation { continuation in
            documentReviewContinuation = continuation
        }

        guard !Task.isCancelled else { return }

        // Apply classification and removal changes back to jobs (rotation is preserved as-is —
        // it was handled in the separate rotation-review pass).
        for item in documentReviewItems {
            guard item.fileIndex < jobs.count else { continue }

            // Removal: drop this photo from output, tagging, and segments
            if item.markedForRemoval {
                removedSourceURLs.insert(item.fileURL)
                if let outputURL = outputURLMap[jobs[item.fileIndex].sourceURL] {
                    try? FileManager.default.removeItem(at: outputURL)
                    let jsonURL = outputURL.deletingPathExtension().appendingPathExtension("json")
                    try? FileManager.default.removeItem(at: jsonURL)
                    outputURLMap[jobs[item.fileIndex].sourceURL] = nil
                }
                jobs[item.fileIndex].status = .removed
                continue
            }

            let newCls = item.classification
            jobs[item.fileIndex].classification = newCls
            if let existingResult = jobs[item.fileIndex].result {
                jobs[item.fileIndex].result = OCRResult(
                    text: existingResult.text,
                    classification: newCls,
                    rotationDegrees: existingResult.rotationDegrees,
                    errorMessage: existingResult.errorMessage,
                    errorCode: existingResult.errorCode
                )
            }
        }
    }
    /// Present a final confirmation of every box/folder identification (after the rotation
    /// review). Reclassifications are written back into jobs, updating Red/Purple tags.
    func showBoxFolderConfirmation(files: [URL]) async {
        let items: [DocumentReviewItem] = files.enumerated().compactMap { (index, url) in
            guard !removedSourceURLs.contains(url), index < jobs.count else { return nil }
            let cls = jobs[index].result?.classification
            guard cls == .boxLabel || cls == .folderLabel else { return nil }
            return DocumentReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                rotationDegrees: jobs[index].result?.rotationDegrees ?? 0
            )
        }

        // Nothing to confirm — skip the sheet entirely.
        guard !items.isEmpty else { return }

        boxFolderConfirmItems = items
        statusMessage = "Confirm box and folder identifications."
        awaitingBoxFolderConfirmation = true

        await withCheckedContinuation { continuation in
            boxFolderConfirmContinuation = continuation
        }

        guard !Task.isCancelled else { return }

        // Apply any reclassifications (updateClassification handles Red/Purple tag updates).
        for item in boxFolderConfirmItems where item.fileIndex < jobs.count {
            let newCls = item.classification ?? .documentStart
            if jobs[item.fileIndex].classification != newCls {
                updateClassification(at: item.fileIndex, to: newCls)
            }
        }
    }
    /// Called by the UI when the user confirms the box/folder review.
    func confirmBoxFolderReview() {
        awaitingBoxFolderConfirmation = false
        boxFolderConfirmContinuation?.resume()
        boxFolderConfirmContinuation = nil
    }
    /// Rebuild collection segments from current job classifications after document review changes.
    /// Reuses existing collection names from collectionSegments where available.
    private func rebuildCollectionSegments(files: [URL]) {
        let classifications = jobs.map { $0.result?.classification }

        // Build a map of file URL to existing collection name
        var existingFileToCollection: [URL: String] = [:]
        for segment in collectionSegments {
            for url in segment.fileURLs {
                existingFileToCollection[url] = segment.collectionName
            }
        }

        // Find box labels and their collection names
        var boxMap: [Int: String] = [:]
        for (i, cls) in classifications.enumerated() {
            if cls == .boxLabel {
                // Prefer existing collection name if available
                if let existing = existingFileToCollection[files[i]] {
                    boxMap[i] = existing
                } else {
                    let text = jobs[i].result?.text ?? ""
                    let name = CollectionSegmenter.normalizeCollectionName(
                        text.components(separatedBy: .newlines).first ?? "Uncategorized"
                    )
                    boxMap[i] = name.isEmpty ? "Uncategorized" : name
                }
            }
        }

        guard !boxMap.isEmpty else {
            collectionSegments = [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
            return
        }

        // Find the first box's collection name as the starting collection
        let sortedBoxIndices = boxMap.keys.sorted()
        var currentCollection = boxMap[sortedBoxIndices[0]]!
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for i in 0..<files.count {
            if let name = boxMap[i] {
                currentCollection = name
            }
            if collectionFiles[currentCollection] == nil {
                collectionOrder.append(currentCollection)
                collectionFiles[currentCollection] = []
            }
            collectionFiles[currentCollection]!.append(files[i])
        }

        collectionSegments = collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }
    /// Apply document segmentation review edits: update job classifications, re-tag, and rebuild collection segments if needed.
    /// Returns true if any files were reclassified as box or folder (requiring collection re-segmentation).
    @discardableResult
    private func applyDocumentReviewEdits(outputDirectory: URL) -> Bool {
        var collectionChanged = false

        for item in documentReviewItems {
            guard item.fileIndex < jobs.count else { continue }
            let oldClassification = jobs[item.fileIndex].classification
            let newClassification = item.classification

            jobs[item.fileIndex].classification = newClassification
            if let existingResult = jobs[item.fileIndex].result {
                jobs[item.fileIndex].result = OCRResult(
                    text: existingResult.text,
                    classification: newClassification,
                    rotationDegrees: item.rotationDegrees,
                    errorMessage: existingResult.errorMessage,
                    errorCode: nil
                )
            }

            if oldClassification != newClassification,
               let outputURL = outputURLMap[item.fileURL] {
                var existingTags = jobs[item.fileIndex].appliedTags
                // Remove old color/subject tags
                existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }
                // Apply new tags based on classification
                switch newClassification {
                case .boxLabel:
                    existingTags.append("Red")
                    existingTags.insert("Box", at: 0)
                case .folderLabel:
                    existingTags.append("Purple")
                    existingTags.insert("Folder", at: 0)
                default:
                    break
                }
                try? MacOSTagger.applyTags(existingTags, to: outputURL)
                jobs[item.fileIndex].appliedTags = existingTags
            }

            // Track if any file was reclassified to/from box/folder
            if oldClassification != newClassification &&
               (newClassification == .boxLabel || newClassification == .folderLabel ||
                oldClassification == .boxLabel || oldClassification == .folderLabel) {
                collectionChanged = true
            }
        }

        // Re-run document segmentation with updated classifications
        let allFiles = jobs.map { $0.sourceURL }
        let updatedClassifications = jobs.map { $0.result?.classification }
        let texts = jobs.map { $0.result?.text ?? "" }
        let segmenter = DocumentSegmenter()
        segments = segmenter.segment(files: allFiles, classifications: updatedClassifications, texts: texts)

        return collectionChanged
    }
}
