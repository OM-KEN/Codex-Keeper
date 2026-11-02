import Foundation
import KeeperZstd

/// Codex keeps rollout_path stable while moving cold logs between these representations.
enum RolloutFile {
    static func plainURL(_ url: URL) -> URL {
        url.pathExtension == "zst" ? url.deletingPathExtension() : url
    }
    static func logicalURL(_ url: URL) -> URL {
        let plain = plainURL(url)
        // The plain file can be absent while compressed; resolve its existing parent first.
        return plain.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(plain.lastPathComponent).resolvingSymlinksInPath()
    }
    static func resolvedURL(_ url: URL) -> URL {
        let plain = plainURL(url)
        if FileManager.default.fileExists(atPath: plain.path) { return plain }
        let compressed = plain.appendingPathExtension("zst")
        return FileManager.default.fileExists(atPath: compressed.path) ? compressed : plain
    }
    static func read(_ url: URL) throws -> Data {
        let actual = resolvedURL(url)
        let bytes = try Data(contentsOf: actual)
        guard actual.pathExtension == "zst" else { return bytes }
        var output: UnsafeMutableRawPointer?
        var count = 0
        let result = bytes.withUnsafeBytes { keeper_zstd_decode($0.baseAddress, $0.count, &output, &count) }
        guard result == 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard let output else { return Data() }
        return Data(bytesNoCopy: output, count: count, deallocator: .free)
    }
}

/// Desktop resumes materialize a cold log before appending. Never tail compressed bytes.
final class RolloutTailReader {
    private let url: URL
    private var baseline: Data?
    private var handle: FileHandle?

    init(url: URL) throws {
        self.url = url
        let actual = RolloutFile.resolvedURL(url)
        if actual.pathExtension == "zst" { baseline = try RolloutFile.read(actual) }
        else {
            let file = try FileHandle(forReadingFrom: actual)
            try file.seekToEnd()
            handle = file
        }
    }
    func close() throws { try handle?.close() }
    func read(upToCount count: Int) throws -> Data? {
        if let baseline {
            let actual = RolloutFile.resolvedURL(url)
            if actual.pathExtension == "zst" { return Data() }
            let file = try FileHandle(forReadingFrom: actual)
            do {
                guard try file.read(upToCount: baseline.count) == baseline else { throw CocoaError(.fileReadCorruptFile) }
            } catch { try? file.close(); throw error }
            handle = file
            self.baseline = nil
        }
        return try handle?.read(upToCount: count)
    }
}
