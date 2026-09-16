import Foundation

enum ImageImportError: Error, Equatable {
    case sourceIsNotARegularFile
    case destinationEscaped
    case sourceTooLarge
}

struct ImageImporter: @unchecked Sendable {
    private let beforeSecureOpen: (() throws -> Void)?

    init(beforeSecureOpen: (() throws -> Void)? = nil) {
        self.beforeSecureOpen = beforeSecureOpen
    }

    func copy(_ source: URL, into destinationDirectory: URL) throws -> URL {
        try copy(source, into: destinationDirectory, authorizedRoot: destinationDirectory.deletingLastPathComponent())
    }

    func copy(_ source: URL, into destinationDirectory: URL, authorizedRoot: URL) throws -> URL {
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let data: Data
        do { data = try SecureFileIO.read(canonicalSource, maximumBytes: 20_000_000) }
        catch SecureFileError.tooLarge { throw ImageImportError.sourceTooLarge }
        catch SecureFileError.notRegularFile { throw ImageImportError.sourceIsNotARegularFile }
        catch { throw error }
        return try coordinatedWrite(data, suggestedName: source.lastPathComponent, source: canonicalSource, destinationDirectory: destinationDirectory, authorizedRoot: authorizedRoot)
    }

    func write(_ data: Data, suggestedName: String, into destinationDirectory: URL) throws -> URL {
        try write(data, suggestedName: suggestedName, into: destinationDirectory, authorizedRoot: destinationDirectory.deletingLastPathComponent())
    }

    func write(_ data: Data, suggestedName: String, into destinationDirectory: URL, authorizedRoot: URL) throws -> URL {
        try write(data, suggestedName: suggestedName, into: destinationDirectory, authority: SecureDirectoryAuthority(granting: authorizedRoot))
    }

    func write(_ data: Data, suggestedName: String, into destinationDirectory: URL, authority: SecureDirectoryAuthority) throws -> URL {
        guard data.count <= 20_000_000 else { throw ImageImportError.sourceTooLarge }
        return try coordinatedWrite(data, suggestedName: suggestedName, source: nil, destinationDirectory: destinationDirectory, authority: authority)
    }

    private func coordinatedWrite(_ data: Data, suggestedName: String, source: URL?, destinationDirectory: URL, authorizedRoot: URL) throws -> URL {
        try coordinatedWrite(data, suggestedName: suggestedName, source: source, destinationDirectory: destinationDirectory, authority: SecureDirectoryAuthority(granting: authorizedRoot))
    }

    private func coordinatedWrite(_ data: Data, suggestedName: String, source: URL?, destinationDirectory: URL, authority: SecureDirectoryAuthority) throws -> URL {
        let root = authority.displayURL
        let expectedDirectory = root.appendingPathComponent(destinationDirectory.lastPathComponent, isDirectory: true).standardizedFileURL
        guard expectedDirectory.path == destinationDirectory.standardizedFileURL.path else { throw ImageImportError.destinationEscaped }
        let safeName = sanitizedFilename(suggestedName)
        var coordinationError: NSError?, operationError: Error?, result: URL?
        let accessor: (URL, URL?) -> Void = { _, _ in
            do {
                try beforeSecureOpen?()
                result = try SecureFileIO.writeUnique(data, suggestedName: safeName, directoryName: destinationDirectory.lastPathComponent, authority: authority)
            } catch { operationError = error }
        }
        if let source {
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: root, options: .forMerging, error: &coordinationError) { readURL, writeURL in accessor(writeURL, readURL) }
        } else {
            NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError) { writeURL in accessor(writeURL, nil) }
        }
        if let coordinationError { throw coordinationError }
        if let operationError {
            if operationError as? SecureFileError == .unsafePath { throw ImageImportError.destinationEscaped }
            throw operationError
        }
        guard let result else { throw ImageImportError.destinationEscaped }
        return result
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let rawStem = (filename as NSString).deletingPathExtension
        let folded = rawStem.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet.alphanumerics
        var stem = "", pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) {
                if pendingSeparator && !stem.isEmpty { stem.append("-") }
                stem.append(Character(scalar)); pendingSeparator = false
            } else { pendingSeparator = true }
        }
        if stem.isEmpty { stem = "image" }
        let ext = rawExtension.unicodeScalars.allSatisfy { allowed.contains($0) } ? rawExtension : ""
        return String(stem.prefix(96)) + (ext.isEmpty ? "" : ".\(ext)")
    }
}
