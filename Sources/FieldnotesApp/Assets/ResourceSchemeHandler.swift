import Foundation
import UniformTypeIdentifiers
import WebKit

struct ResourceScope: Sendable {
    let generation: Int
    let allowedRoot: URL
    let baseURL: URL

    init(generation: Int, allowedRoot: URL, baseURL: URL? = nil) {
        self.generation = generation
        self.allowedRoot = allowedRoot
        self.baseURL = baseURL ?? allowedRoot
    }
}

enum ResourceError: Error, Equatable {
    case unsupportedScheme
    case malformedRequest
    case staleGeneration
    case outsideAllowedRoot
    case unavailable
}

struct ResourceResolver: Sendable {
    let scope: @MainActor @Sendable () -> ResourceScope?

    init(scope: @escaping @MainActor @Sendable () -> ResourceScope?) {
        self.scope = scope
    }

    @MainActor func resolve(_ request: URL) throws -> URL {
        guard request.scheme == "fieldnotes-resource" else { throw ResourceError.unsupportedScheme }
        guard let generation = Int(request.host ?? ""), generation > 0,
              let scope = scope() else { throw ResourceError.malformedRequest }
        guard generation == scope.generation else { throw ResourceError.staleGeneration }
        let root = scope.allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let components = URLComponents(url: request, resolvingAgainstBaseURL: false) else {
            throw ResourceError.malformedRequest
        }
        guard components.path == "/resource", let items = components.queryItems, items.count == 1,
              items[0].name == "path", let decoded = items[0].value, !decoded.isEmpty,
              !decoded.hasPrefix("/"), !decoded.contains("\\") else { throw ResourceError.malformedRequest }
        let candidate = scope.baseURL.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard contains(candidate, in: root) else { throw ResourceError.outsideAllowedRoot }
        guard (try? candidate.resourceValues(forKeys: Set([URLResourceKey.isRegularFileKey])).isRegularFile) == true else {
            throw ResourceError.unavailable
        }
        return candidate
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        return candidateParts.count >= rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }
}

@MainActor final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: ResourceResolver

    init(resolver: ResourceResolver) { self.resolver = resolver }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let requestURL = urlSchemeTask.request.url else { throw ResourceError.malformedRequest }
            let fileURL = try resolver.resolve(requestURL)
            guard let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 50_000_000 else {
                throw ResourceError.unavailable
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let type = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(url: requestURL, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
