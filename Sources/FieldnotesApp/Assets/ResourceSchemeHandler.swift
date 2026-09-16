import Foundation
import UniformTypeIdentifiers
import WebKit

struct ResourceScope: Sendable {
    let generation: Int
    let allowedRoot: URL
    let baseURL: URL
    let authority: SecureDirectoryAuthority?
    init(generation: Int, allowedRoot: URL, baseURL: URL? = nil) {
        self.generation = generation; self.allowedRoot = allowedRoot; self.baseURL = baseURL ?? allowedRoot
        authority = try? SecureDirectoryAuthority(granting: allowedRoot)
    }
    init(generation: Int, replacingGenerationOf scope: ResourceScope) {
        self.generation = generation; allowedRoot = scope.allowedRoot; baseURL = scope.baseURL; authority = scope.authority
    }
}

enum ResourceError: Error, Equatable { case unsupportedScheme, malformedRequest, staleGeneration, outsideAllowedRoot, unavailable }

struct AuthorizedResource: Sendable {
    let fileURL: URL
    let root: URL
    let relativeComponents: [String]
    let mimeType: String
    let authority: SecureDirectoryAuthority
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
        guard let authority = scope.authority else { throw ResourceError.unavailable }
        let root = scope.allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let components = URLComponents(url: request, resolvingAgainstBaseURL: false), components.path == "/resource",
              let items = components.queryItems, items.count == 1, items[0].name == "path",
              let markdownPath = items[0].value, !markdownPath.isEmpty, let decoded = markdownPath.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\") else { throw ResourceError.malformedRequest }
        let candidate = scope.baseURL.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard contains(candidate, in: root) else { throw ResourceError.outsideAllowedRoot }
        guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw ResourceError.unavailable }
        guard let type = UTType(filenameExtension: candidate.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else { throw ResourceError.unavailable }
        return AuthorizedResource(fileURL: candidate, root: root, relativeComponents: Array(candidate.pathComponents.dropFirst(root.pathComponents.count)), mimeType: mime, authority: authority)
    }

    @MainActor func load(_ request: URL, beforeOpen: (() throws -> Void)? = nil) throws -> ResourceLoad {
        let authorized = try authorize(request)
        try beforeOpen?()
        let data = try SecureFileIO.read(relativeComponents: authorized.relativeComponents, authority: authorized.authority, maximumBytes: 50_000_000)
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
    private struct Pending {
        let identifier: ObjectIdentifier
        let box: SchemeTaskBox
        let requestURL: URL
        let authorized: AuthorizedResource
    }
    private let resolver: ResourceResolver
    private let reader: @Sendable (AuthorizedResource) throws -> Data
    private var pending: [Pending] = []
    private var workers: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(resolver: ResourceResolver, reader: @escaping @Sendable (AuthorizedResource) throws -> Data = {
        try SecureFileIO.read(relativeComponents: $0.relativeComponents, authority: $0.authority, maximumBytes: 50_000_000)
    }) { self.resolver = resolver; self.reader = reader }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject), box = SchemeTaskBox(urlSchemeTask)
        do {
            guard let requestURL = urlSchemeTask.request.url else { throw ResourceError.malformedRequest }
            let authorized = try resolver.authorize(requestURL)
            pending.append(.init(identifier: identifier, box: box, requestURL: requestURL, authorized: authorized))
            pump()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        if let index = pending.firstIndex(where: { $0.identifier == identifier }) { pending.remove(at: index); return }
        workers[identifier]?.cancel()
    }

    private func pump() {
        while workers.count < 8, !pending.isEmpty {
            let item = pending.removeFirst()
            let reader = reader
            workers[item.identifier] = Task.detached { [weak self] in
                let result = Result { try reader(item.authorized) }
                let cancelled = Task.isCancelled
                await self?.finish(item, result: result, cancelled: cancelled)
            }
        }
    }

    private func finish(_ item: Pending, result: Result<Data, Error>, cancelled: Bool) {
        guard workers.removeValue(forKey: item.identifier) != nil else { return }
        if !cancelled {
            switch result {
            case .success(let data):
                let response = URLResponse(url: item.requestURL, mimeType: item.authorized.mimeType, expectedContentLength: data.count, textEncodingName: nil)
                item.box.task.didReceive(response); item.box.task.didReceive(data); item.box.task.didFinish()
            case .failure(let error): item.box.task.didFailWithError(error)
            }
        }
        pump()
    }
}
