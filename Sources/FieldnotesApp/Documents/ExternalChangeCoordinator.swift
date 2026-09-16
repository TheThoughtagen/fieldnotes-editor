import Foundation

/// Reads run away from the main actor; NSDocument remains the only coordinated writer.
struct ExternalChangeCoordinator: Sendable {
    var read: (@Sendable (URL) async throws -> Data?)?

    @MainActor
    func coordinatedRead(from url: URL, presenter: NSFilePresenter) async throws -> Data? {
        if let read { return try await read(url) }
        let reader = CoordinatedReader(presenter: presenter)
        return try await Task.detached { try reader.read(url) }.value
    }

    static func diskData(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            if isMissing(error) { return nil }
            throw error
        }
    }

    fileprivate static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }
}

/// Constructed on the presenter's actor, then used exactly once on a worker task.
/// NSFileCoordinator is never accessed concurrently. Excluding our own presenter avoids
/// reentrant NSDocument relinquish/reacquire handling while reconciling its notification.
private final class CoordinatedReader: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    init(presenter: NSFilePresenter) { coordinator = NSFileCoordinator(filePresenter: presenter) }

    func read(_ url: URL) throws -> Data? {
        var coordinationError: NSError?
        var result: Result<Data?, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { accessorURL in
            result = Result { try ExternalChangeCoordinator.diskData(at: accessorURL) }
        }
        if let coordinationError {
            if ExternalChangeCoordinator.isMissing(coordinationError) { return nil }
            throw coordinationError
        }
        return try result?.get()
    }
}
