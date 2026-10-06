import Darwin
import Foundation

/// Holds the per-user Tugboat instance lock until this object is released.
final class SingleInstanceLock {
    static let defaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.github.jduprat.Tugboat.single-instance.lock")

    private let descriptor: Int32

    init(url: URL = SingleInstanceLock.defaultURL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        descriptor = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            var openedDescriptor: Int32
            repeat {
                openedDescriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            } while openedDescriptor == -1 && errno == EINTR
            guard openedDescriptor >= 0 else { throw Self.posixError(errno) }
            return openedDescriptor
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    /// Returns false only when another descriptor owns the lock.
    func tryAcquire() throws -> Bool {
        while flock(descriptor, LOCK_EX | LOCK_NB) == -1 {
            let errorNumber = errno
            if errorNumber == EINTR { continue }
            if errorNumber == EWOULDBLOCK { return false }
            throw Self.posixError(errorNumber)
        }
        return true
    }

    private static func posixError(_ errorNumber: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
    }
}
