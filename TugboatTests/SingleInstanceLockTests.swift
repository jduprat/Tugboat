import Darwin
import Foundation
import XCTest
@testable import Tugboat

final class SingleInstanceLockTests: XCTestCase {
    func testContentionEndsWhenTheOwnerIsReleased() throws {
        try withLockURL { url in
            var owner: SingleInstanceLock? = try SingleInstanceLock(url: url)
            let contender = try SingleInstanceLock(url: url)

            XCTAssertTrue(try XCTUnwrap(owner).tryAcquire())
            XCTAssertFalse(try contender.tryAcquire())

            owner = nil
            XCTAssertTrue(try contender.tryAcquire())
        }
    }

    func testConcurrentAcquisitionAllowsExactlyOneOwner() throws {
        try withLockURL { url in
            // Independent opens have separate flock ownership, even in one process.
            let contenders = try (0..<8).map { _ in try SingleInstanceLock(url: url) }
            let results = AcquisitionResults()

            DispatchQueue.concurrentPerform(iterations: contenders.count) { index in
                results.append(Result { try contenders[index].tryAcquire() })
            }

            let acquisitions = try results.snapshot().map { try $0.get() }
            XCTAssertEqual(acquisitions.count, contenders.count)
            XCTAssertEqual(acquisitions.filter { $0 }.count, 1)
        }
    }

    func testOpeningInAMissingDirectoryThrowsAFileSystemError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceLockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock")

        XCTAssertThrowsError(try SingleInstanceLock(url: url)) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(ENOENT))
        }
    }

    private func withLockURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("instance.lock"))
    }

    private final class AcquisitionResults {
        private let mutex = NSLock()
        private var values: [Result<Bool, Error>] = []

        func append(_ value: Result<Bool, Error>) {
            mutex.lock()
            defer { mutex.unlock() }
            values.append(value)
        }

        func snapshot() -> [Result<Bool, Error>] {
            mutex.lock()
            defer { mutex.unlock() }
            return values
        }
    }
}
