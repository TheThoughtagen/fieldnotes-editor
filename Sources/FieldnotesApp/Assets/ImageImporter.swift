import Foundation

enum ImageImportError: Error, Equatable {
    case sourceIsNotARegularFile
    case destinationEscaped
}

struct ImageImporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func copy(_ source: URL, into destinationDirectory: URL) throws -> URL {
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard (try? canonicalSource.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ImageImportError.sourceIsNotARegularFile
        }
        let (canonicalRoot, destination) = try availableDestination(named: source.lastPathComponent, in: destinationDirectory)
        guard contains(destination, in: canonicalRoot) else { throw ImageImportError.destinationEscaped }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: canonicalSource, options: [], writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinatedSource, coordinatedDestination in
            do { try fileManager.copyItem(at: coordinatedSource, to: coordinatedDestination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    func write(_ data: Data, suggestedName: String, into destinationDirectory: URL) throws -> URL {
        let (canonicalRoot, destination) = try availableDestination(named: suggestedName, in: destinationDirectory)
        guard contains(destination, in: canonicalRoot) else { throw ImageImportError.destinationEscaped }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinatedDestination in
            do { try data.write(to: coordinatedDestination, options: .withoutOverwriting) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return destination
    }

    private func availableDestination(named name: String, in destinationDirectory: URL) throws -> (URL, URL) {
        let destinationRoot = destinationDirectory.standardizedFileURL
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let canonicalRoot = destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        let safeName = sanitizedFilename(name)
        let stem = (safeName as NSString).deletingPathExtension
        let suffix = (safeName as NSString).pathExtension
        var attempt = 1
        var destination: URL
        repeat {
            let filename = attempt == 1 ? safeName : "\(stem)-\(attempt)\(suffix.isEmpty ? "" : ".\(suffix)")"
            destination = canonicalRoot.appendingPathComponent(filename, isDirectory: false)
            attempt += 1
        } while fileManager.fileExists(atPath: destination.path)
        return (canonicalRoot, destination)
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let rawStem = (filename as NSString).deletingPathExtension
        let folded = rawStem.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet.alphanumerics
        var stem = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) {
                if pendingSeparator && !stem.isEmpty { stem.append("-") }
                stem.append(Character(scalar))
                pendingSeparator = false
            } else { pendingSeparator = true }
        }
        if stem.isEmpty { stem = "image" }
        let ext = rawExtension.unicodeScalars.allSatisfy { allowed.contains($0) } ? rawExtension : ""
        return String(stem.prefix(96)) + (ext.isEmpty ? "" : ".\(ext)")
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.pathComponents
        let candidateParts = candidate.standardizedFileURL.pathComponents
        return candidateParts.count >= rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }
}
