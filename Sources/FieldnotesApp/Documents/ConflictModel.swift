import Foundation
import Observation

struct ConflictModel: Identifiable, Equatable, Sendable {
    let id: UUID
    let base: Data
    let ours: String
    /// nil means the file was deleted, rather than an empty file.
    let theirs: Data?

    init(base: Data, ours: String, theirs: Data?) {
        id = UUID()
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }
}

enum ConflictResolution: Equatable {
    case editor
    case disk
    case merged(String)
}

enum ExternalChangeError: LocalizedError {
    case unresolvedConflict
    case unreadableDisk
    case saveInProgress

    var errorDescription: String? {
        switch self {
        case .unresolvedConflict: "Review the external change before saving this file."
        case .unreadableDisk: "The disk version could not be read. Save a copy or retry after restoring access."
        case .saveInProgress: "A save is already in progress."
        }
    }
}

/// Choosing a candidate is reversible. Only the document's confirmation action changes its buffer.
@MainActor
@Observable
final class ConflictReview {
    private(set) var conflict: ConflictModel
    var mergeText: String
    private(set) var pending: ConflictResolution?
    init(conflict: ConflictModel) {
        self.conflict = conflict
        mergeText = conflict.ours
    }
    func refresh(_ conflict: ConflictModel) {
        guard self.conflict.id != conflict.id else { return }
        self.conflict = conflict
        pending = nil
    }
    func choose(_ resolution: ConflictResolution) { pending = resolution }
    func cancel() { pending = nil }
}
