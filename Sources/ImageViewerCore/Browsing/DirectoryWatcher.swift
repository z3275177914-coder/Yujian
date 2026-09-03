import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Lightweight directory invalidation signal. The event only says that the
/// directory changed; the active DirectorySession performs the authoritative
/// rescan and merges the resulting batches.
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias ChangeHandler = () -> Void

    private let directoryURL: URL
    private let onChange: ChangeHandler
    private let queue = DispatchQueue(
        label: "com.imageviewer.directory-watcher",
        qos: .utility
    )
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    public init(directoryURL: URL, onChange: @escaping ChangeHandler) {
        self.directoryURL = directoryURL
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        guard source == nil else {
            lock.unlock()
            return
        }

        #if canImport(Darwin)
        let fileDescriptor = Darwin.open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            lock.unlock()
            return
        }
        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )
        dispatchSource.setEventHandler { [weak self] in
            self?.onChange()
        }
        dispatchSource.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        source = dispatchSource
        lock.unlock()
        dispatchSource.resume()
        #else
        lock.unlock()
        #endif
    }

    public func cancel() {
        lock.lock()
        let dispatchSource = source
        source = nil
        lock.unlock()
        dispatchSource?.cancel()
    }

    deinit {
        cancel()
    }
}
