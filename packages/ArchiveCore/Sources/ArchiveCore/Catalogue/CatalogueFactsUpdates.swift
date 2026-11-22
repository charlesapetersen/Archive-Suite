import Foundation

/// Distributes scoped snapshots from the caller's scan/refresh loop. An update includes changes
/// to availability, the selected PDF, its document owner, or its enclosure target.
public actor CatalogueFactsUpdates {
    public let rootInstanceID: UUID
    private var snapshot: CatalogueReader.Snapshot?
    private var subscriptions: [UUID: Subscription] = [:]

    private struct Subscription {
        let relativePath: String
        let physicalPageIndex: Int?
        let continuation: AsyncStream<ItemFacts>.Continuation
        var revision: ItemFacts.SelectionRevision?

        mutating func update(from snapshot: CatalogueReader.Snapshot) {
            let facts = snapshot.facts(at: relativePath, physicalPageIndex: physicalPageIndex)
            let current = facts.revision
            guard revision != current else { return }
            revision = current
            continuation.yield(facts)
        }
    }

    public init(rootInstanceID: UUID) {
        self.rootInstanceID = rootInstanceID
    }

    /// Publish snapshots in refresh order. A snapshot from another root instance is rejected.
    @discardableResult
    public func publish(_ snapshot: CatalogueReader.Snapshot) -> Bool {
        guard snapshot.rootInstanceID == rootInstanceID else { return false }
        self.snapshot = snapshot
        for id in subscriptions.keys {
            subscriptions[id]?.update(from: snapshot)
        }
        return true
    }

    /// Produces the current facts when available, followed by the latest value at each change.
    /// Include active selections in refreshes when their PDFs may be absent from inventory.
    public func updates(at relativePath: String, physicalPageIndex: Int? = nil) -> AsyncStream<ItemFacts> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ItemFacts>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(id) }
        }
        var subscription = Subscription(relativePath: relativePath, physicalPageIndex: physicalPageIndex,
                                        continuation: continuation)
        if let snapshot { subscription.update(from: snapshot) }
        subscriptions[id] = subscription
        return stream
    }

    private func removeSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
    }
}
