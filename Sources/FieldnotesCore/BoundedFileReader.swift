import Darwin
import Foundation

public enum BoundedFileReadError: Error { case unavailable, notRegular, tooLarge }

public enum BoundedFileReader {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw BoundedFileReadError.unavailable }
        defer { Darwin.close(descriptor) }
        return try read(fileDescriptor: descriptor, maximumBytes: maximumBytes)
    }

    static func read(fileDescriptor: Int32, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw BoundedFileReadError.tooLarge }
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0 else { throw BoundedFileReadError.unavailable }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw BoundedFileReadError.notRegular }
        guard metadata.st_size <= maximumBytes else { throw BoundedFileReadError.tooLarge }
        // The descriptor's size may change after fstat. Bound the actual read as well.
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw BoundedFileReadError.tooLarge }
        return data
    }
}
