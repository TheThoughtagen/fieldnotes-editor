import Foundation
import UniformTypeIdentifiers
import WebKit

struct ResourceScope: Sendable {
    let generation: Int
    let allowedRoot: URL
    let baseURL: URL
    init(generation: Int, allowedRoot: URL, baseURL: URL? = nil) {
        self.generation = generation; self.allowedRoot = allowedRoot; self.baseURL = baseURL ?? allowedRoot
    }
}

enum ResourceError: Error, Equatable { case unsupportedScheme, malformedRequest, staleGeneration, outsideAllowedRoot, unavailable }

struct AuthorizedResource: Sendable {
    let fileURL: URL
    let root: URL
    let relativeComponents: [String]
    let mimeType: String
}

struct ResourceLoad: Sendable { let fileURL: URL; let mimeType: String; let data: Data }

struct ResourceResolver: Sendable {
    let scope: @MainActor @Sendable () -> ResourceScope?
    init(scope: @escaping @MainActor @Sendable () -> ResourceScope?) { self.scope = scope }

    @MainActor func resolve(_ request: URL) throws -> URL { try authorize(request).fileURL }

    @MainActor func authorize(_ request: URL) throws -> AuthorizedResource {
        guard request.scheme == "fieldnotes-resource" else { throw ResourceError.unsupportedScheme }
        guard let generation = Int(request.host ?? ""), generation > 0, let scope = scope() else { throw ResourceError.malformedRequest }
        guard generation == scope.generation else { throw ResourceError.staleGeneration }
        let root = scope.allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let components = URLComponents(url: request, resolvingAgainstBaseURL: false), components.path == "/resource",
              let items = components.queryItems, items.count == 1, items[0].name == "path",
              let markdownPath = items[0].value, !markdownPath.isEmpty, let decoded = markdownPath.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\") else { throw ResourceError.malformedRequest }
        let candidate = scope.baseURL.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard contains(candidate, in: root) else { throw ResourceError.outsideAllowedRoot }
        guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw ResourceError.unavailable }
        guard let type = UTType(filenameExtension: candidate.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else { throw ResourceError.unavailable }
        return AuthorizedResource(fileURL: candidate, root: root, relativeComponents: Array(candidate.pathComponents.dropFirst(root.pathComponents.count)), mimeType: mime)
    }

    @MainActor func load(_ request: URL, beforeOpen: (() throws -> Void)? = nil) throws -> ResourceLoad {
        let authorized = try authorize(request)
        try beforeOpen?()
        let data = try SecureFileIO.read(relativeComponents: authorized.relativeComponents, authorizedRoot: authorized.root, maximumBytes: 50_000_000)
        return ResourceLoad(fileURL: authorized.fileURL, mimeType: authorized.mimeType, data: data)
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.pathComponents, candidateParts = candidate.pathComponents
        return candidateParts.count >= rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }
}

private final class SchemeTaskBox: @unchecked Sendable {
    let task: WKURLSchemeTask
    init(_ task: WKURLSchemeTask) { self.task = task }
}

@MainActor final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: ResourceResolver
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(resolver: ResourceResolver) { self.resolver = resolver }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject), box = SchemeTaskBox(urlSchemeTask)
        do {
            guard tasks.count < 8 else { throw ResourceError.unavailable }
            guard let requestURL = urlSchemeTask.request.url else { throw ResourceError.malformedRequest }
            let authorized = try resolver.authorize(requestURL)
            tasks[identifier] = Task { [weak self] in
                let result = await Task.detached { Result { try SecureFileIO.read(relativeComponents: authorized.relativeComponents, authorizedRoot: authorized.root, maximumBytes: 50_000_000) } }.value
                guard !Task.isCancelled else { return }
                self?.tasks.removeValue(forKey: identifier)
                switch result {
                case .success(let data):
                    let response = URLResponse(url: requestURL, mimeType: authorized.mimeType, expectedContentLength: data.count, textEncodingName: nil)
                    box.task.didReceive(response); box.task.didReceive(data); box.task.didFinish()
                case .failure(let error): box.task.didFailWithError(error)
                }
            }
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks.removeValue(forKey: identifier)?.cancel()
    }
}
