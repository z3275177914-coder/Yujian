import Foundation

public struct DirectorySessionBatch: Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let assets: [ImageAsset]
    public let isComplete: Bool

    public init(
        sessionID: UUID,
        revision: UInt64,
        assets: [ImageAsset],
        isComplete: Bool
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.assets = assets
        self.isComplete = isComplete
    }
}

/// Owns one progressive directory stream at a time. Starting a new stream
/// invalidates every older stream, even if its scanner is still unwinding.
public actor DirectorySession {
    private let scanner: DirectoryScanner
    private var revisionValue: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    public init(scanner: DirectoryScanner = DirectoryScanner()) {
        self.scanner = scanner
    }

    public func start(
        directoryURL: URL,
        batchSize: Int = 128
    ) -> AsyncStream<DirectorySessionBatch> {
        activeTask?.cancel()
        revisionValue &+= 1
        let revision = revisionValue
        let sessionID = UUID()
        let scanner = scanner

        let (stream, continuation) = AsyncStream<DirectorySessionBatch>.makeStream(
            bufferingPolicy: .unbounded
        )
        let task = Task { [weak self, scanner] in
            let batches = await scanner.scanBatches(
                directoryURL: directoryURL,
                batchSize: batchSize
            )
            for await batch in batches {
                guard !Task.isCancelled,
                      let self,
                      await self.isCurrent(revision) else {
                    break
                }
                continuation.yield(DirectorySessionBatch(
                    sessionID: sessionID,
                    revision: revision,
                    assets: batch.assets,
                    isComplete: batch.isComplete
                ))
            }
            continuation.finish()
            guard let self else {
                return
            }
            await self.clearActiveTask(for: revision)
        }
        activeTask = task
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        revisionValue &+= 1
    }

    public func isCurrent(_ revision: UInt64) -> Bool {
        revision == revisionValue
    }

    private func clearActiveTask(for revision: UInt64) {
        guard revision == revisionValue else {
            return
        }
        activeTask = nil
    }
}
