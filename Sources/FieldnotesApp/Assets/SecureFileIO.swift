import Darwin
import Foundation

enum SecureFileError: Error, Equatable {
    case unsafePath
    case notRegularFile
    case tooLarge
    case unavailable
}

enum SecureFileIO {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = try openPath(try canonicalExistingPath(url), finalFlags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(descriptor) }
        return try read(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    static func read(relativeComponents: [String], authorizedRoot: URL, maximumBytes: Int) throws -> Data {
        guard !relativeComponents.isEmpty, !relativeComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw SecureFileError.unsafePath }
        let root = try openPath(try canonicalExistingPath(authorizedRoot), finalFlags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var descriptor = root
        for (index, component) in relativeComponents.enumerated() {
            let flags = index == relativeComponents.count - 1 ? O_RDONLY | O_NOFOLLOW | O_CLOEXEC : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = component.withCString { openat(descriptor, $0, flags) }
            if descriptor != root { close(descriptor) }
            guard next >= 0 else { close(root); throw SecureFileError.unsafePath }
            descriptor = next
        }
        close(root)
        defer { close(descriptor) }
        return try read(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    private static func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw SecureFileError.notRegularFile }
        guard status.st_size >= 0, status.st_size <= maximumBytes else { throw SecureFileError.tooLarge }
        var data = Data(); data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { if errno == EINTR { continue }; throw SecureFileError.unavailable }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw SecureFileError.tooLarge }
            data.append(buffer, count: count)
        }
        return data
    }

    static func writeUnique(_ data: Data, suggestedName: String, directoryName: String, authorizedRoot: URL) throws -> URL {
        let canonicalRootPath = try canonicalExistingPath(authorizedRoot)
        let root = try openPath(canonicalRootPath, finalFlags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(root) }
        let mkdirResult = directoryName.withCString { mkdirat(root, $0, 0o755) }
        guard mkdirResult == 0 || errno == EEXIST else { throw SecureFileError.unavailable }
        let directory = try directoryName.withCString { name -> Int32 in
            let fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SecureFileError.unsafePath }
            return fd
        }
        defer { close(directory) }

        let pathExtension = (suggestedName as NSString).pathExtension
        let stem = (suggestedName as NSString).deletingPathExtension
        for attempt in 1...10_000 {
            let name = attempt == 1 ? suggestedName : "\(stem)-\(attempt)\(pathExtension.isEmpty ? "" : ".\(pathExtension)")"
            let descriptor = name.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw SecureFileError.unsafePath
            }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        if Task.isCancelled { throw CancellationError() }
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        guard count >= 0 else { if errno == EINTR { continue }; throw SecureFileError.unavailable }
                        offset += count
                    }
                }
                guard fsync(descriptor) == 0 else { throw SecureFileError.unavailable }
                close(descriptor)
                return authorizedRoot.standardizedFileURL.appendingPathComponent(directoryName).appendingPathComponent(name)
            } catch {
                close(descriptor)
                _ = name.withCString { unlinkat(directory, $0, 0) }
                throw error
            }
        }
        throw SecureFileError.unavailable
    }

    private static func openPath(_ path: String, finalFlags: Int32) throws -> Int32 {
        guard path.hasPrefix("/") else { throw SecureFileError.unsafePath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecureFileError.unavailable }
        let components = (path as NSString).pathComponents.dropFirst()
        for (index, component) in components.enumerated() {
            let flags = index == components.count - 1 ? finalFlags : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = component.withCString { openat(descriptor, $0, flags) }
            close(descriptor)
            guard next >= 0 else { throw SecureFileError.unsafePath }
            descriptor = next
        }
        return descriptor
    }

    private static func canonicalExistingPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw SecureFileError.unsafePath }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw SecureFileError.unsafePath }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
