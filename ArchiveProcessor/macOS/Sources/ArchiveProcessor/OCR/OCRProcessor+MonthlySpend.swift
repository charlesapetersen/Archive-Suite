import Foundation

/// Preliminary checks for a page or stage. The paid request ledger reserves the individual
/// transport attempts, including those in flight.
struct ProcessFilesMonthlySpend {
    let limit: Double
    var pricedImages = 0

    struct ReadingDeclined: LocalizedError {
        var errorDescription: String? { "The monthly spending limit did not allow another reading." }
    }

    static func remaining(limit: Double, spent: Double) -> Double { max(0, limit - spent) }

    static func fits(_ cost: Double, remaining: Double) -> Bool {
        cost.isFinite && cost <= remaining + 1e-12
    }

    static func hasPrice(model: LLMModel, gateway: GatewayConfig?, localAgent: LocalAgentConfig?,
                         claudeBilling: ClaudeCLIBilling = .unknown) -> Bool {
        if let localAgent { return localAgent.tool != .claude || claudeBilling == .subscription }
        if gateway?.isLocalModel == true { return true }
        if let gateway {
            return [gateway.inputCostPer1M, gateway.outputCostPer1M].allSatisfy {
                guard let price = $0 else { return false }
                return price.isFinite && price >= 0
            }
        }
        return !OpenRouterRoute.isUnpriced(model)
    }
}

extension OCRProcessor {
    /// A resume reads today's budget and ledger even though its reader and other processing settings stay frozen.
    func beginMonthlySpend(outputDirectory: URL, pricedImages: Int = 0) {
        monthlyStopMessage = nil
        monthlySpend = SettingsLayerStore.shared.resolver(at: outputDirectory).monthlyLimitUSD.map {
            ProcessFilesMonthlySpend(limit: $0, pricedImages: pricedImages)
        }
        if monthlySpend != nil, let readings = activeRunHistory?.newspaperSpend {
            let id = readings.parentLedgerID
            readings.monthlyAdmission = { [weak self] price in
                guard let self, self.activeRunHistory?.newspaperSpend.parentLedgerID == id else { return false }
                return self.reserveMonthlySpend(price, for: "an additional page reading", whileReading: true)
            }
        }
    }

    func processPaidRequests(runID: UUID?, outputDirectory: URL) -> PaidRequests {
        let scopeID = UUID()
        let store = SettingsLayerStore.shared
        let scope = PaidRequests(id: scopeID, runID: runID ?? UUID(), outputDirectory: outputDirectory,
                                 limit: store.resolver(at: outputDirectory).monthlyLimitUSD) { [weak self] estimate in
            guard let self, self.isProcessing, self.paidRequestScope?.id == scopeID else { return }
            self.noteMonthlySpendDecline(estimate, for: "the next paid request",
                                         remaining: ProcessFilesMonthlySpend.remaining(limit: self.paidRequestScope?.limit ?? 0,
                                                                                         spent: store.spentThisMonthUSD()))
        }
        return scope
    }

    func reserveMonthlySpend(_ estimate: Double?, for work: String, whileReading: Bool = false) -> Bool {
        guard let spend = monthlySpend else { return true }
        guard monthlyStopMessage == nil, !Task.isCancelled else { return false }
        let remaining = ProcessFilesMonthlySpend.remaining(limit: spend.limit,
            spent: SettingsLayerStore.shared.spentThisMonthUSD())
        if let estimate, ProcessFilesMonthlySpend.fits(estimate, remaining: remaining) { return true }
        noteMonthlySpendDecline(estimate, for: work, remaining: remaining)
        if !ocrPhaseActive, !whileReading { cancel() }
        return false
    }

    private func noteMonthlySpendDecline(_ estimate: Double?, for work: String, remaining: Double) {
        if let estimate, estimate.isFinite {
            monthlyStopMessage = "Stopped at the monthly spending limit. There is about \(CostEstimate.money(remaining)) left, and \(work) needs about \(CostEstimate.money(estimate))."
        } else {
            monthlyStopMessage = "Stopped at the monthly spending limit. The price of \(work) is unknown."
        }
        if ocrPhaseActive {
            // Let already admitted pages finish and save. Unstarted pages stay unread in recovery.
            stopWhenPagesSaved = true
        }
    }

    func reserveMonthlyImage(_ image: URL, runConfig: SessionProcessingConfig?, retry: Bool = false) -> Bool {
        guard let spend = monthlySpend, let history = activeRunHistory else { return true }
        let n = spend.pricedImages
        let estimate = history.imageEstimate(count: retry ? 1 : n + 1)
        var cost = retry
            ? (estimate?.ocrCost ?? 0) + (estimate?.rotationCost ?? 0) + (estimate?.classificationCost ?? 0)
            : (estimate?.totalStandard ?? 0) - (history.imageEstimate(count: n)?.totalStandard ?? 0)
        if let config = runConfig, let entry = config.pageReaders.entry(for: image) {
            let reader = PageKindRouting.reader(entry, provider: history.provider, model: history.model,
                apiKey: config.apiKey, thinkingLevel: config.thinkingLevel, imageScale: history.imageScale,
                sendPreviousImage: !retry && history.sendPreviousImage,
                contextCharCount: retry ? 0 : history.contextCharCount)
            guard !OpenRouterRoute.isUnpriced(reader.model) else { return reserveMonthlySpend(nil, for: "the next page") }
            cost += (reader.record.estimatedCost ?? 0) - (reader.record.replacedCost ?? 0)
        }
        guard reserveMonthlySpend(max(0, cost), for: retry ? "another read of this page" : "reading and processing the next page") else {
            return false
        }
        if retry {
            history.newspaperSpend.add(max(0, cost), id: UUID(), source: image, baseAllowance: false)
        } else {
            monthlySpend?.pricedImages += 1
        }
        return true
    }

    func stopIfMonthlyReadDeclined() -> Bool {
        guard monthlyStopMessage != nil else { return false }
        cancel()
        return true
    }
}
