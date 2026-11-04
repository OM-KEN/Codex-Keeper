import Foundation
import KeeperZstd
import CryptoKit

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
        guard actual.pathExtension == "zst" else { return try Data(contentsOf: actual) }
        var data = Data()
        try forEachChunk(actual) { data.append($0) }
        return data
    }

    /// Emit fixed-size decoded chunks (except the last) without buffering the whole file.
    static func forEachChunk(_ url: URL, chunkSize: Int = 64 * 1024, _ receive: (Data) throws -> Void) throws {
        precondition(chunkSize > 0)
        let actual = resolvedURL(url)
        let handle = try FileHandle(forReadingFrom: actual)
        defer { try? handle.close() }
        guard actual.pathExtension == "zst" else {
            while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { try receive(data) }
            return
        }
        guard let stream = keeper_zstd_stream_create() else { throw CocoaError(.fileReadCorruptFile) }
        defer { keeper_zstd_stream_free(stream) }
        var output = Data(count: chunkSize)
        var remaining = 1, buffered = 0, sawInput = false
        while let input = try handle.read(upToCount: chunkSize), !input.isEmpty {
            sawInput = true
            var offset = 0, written = 0, capacity = 0
            repeat {
                var consumed = 0
                capacity = chunkSize - buffered
                let result = input.withUnsafeBytes { source in
                    output.withUnsafeMutableBytes { target in
                        keeper_zstd_stream_decode(stream, source.baseAddress?.advanced(by: offset), input.count - offset,
                            &consumed, target.baseAddress?.advanced(by: buffered), capacity, &written, &remaining)
                    }
                }
                guard result == 0 else { throw CocoaError(.fileReadCorruptFile) }
                if consumed == 0 && written == 0 {
                    guard offset == input.count else { throw CocoaError(.fileReadCorruptFile) }
                    break // Buffered output is drained; the decoder needs the next input chunk.
                }
                offset += consumed
                buffered += written
                if buffered == chunkSize { try receive(output); buffered = 0 }
            } while offset < input.count || (written == capacity && remaining != 0)
        }
        guard sawInput && remaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
        if buffered > 0 { try receive(output.prefix(buffered)) }
    }

    /// Only the unfinished JSONL record is retained across chunks, including UTF-8 split points.
    static func forEachLine(_ url: URL, chunkSize: Int = 64 * 1024, _ receive: (Data) throws -> Void) throws {
        var pending = Data()
        try forEachChunk(url, chunkSize: chunkSize) { data in
            var start = data.startIndex
            while let end = data[start...].firstIndex(of: 10) {
                pending.append(contentsOf: data[start..<end])
                try receive(pending)
                pending = Data()
                start = data.index(after: end)
            }
            pending.append(contentsOf: data[start...])
        }
        if !pending.isEmpty { try receive(pending) }
    }

}

/// Desktop resumes materialize a cold log before appending. Never tail compressed bytes.
final class RolloutTailReader {
    private let url: URL
    private var baseline: (count: UInt64, digest: Data)?
    private var handle: FileHandle?

    init(url: URL) throws {
        self.url = url
        let actual = RolloutFile.resolvedURL(url)
        if actual.pathExtension == "zst" {
            var digest = SHA256(), count: UInt64 = 0
            try RolloutFile.forEachChunk(actual) { data in digest.update(data: data); count += UInt64(data.count) }
            baseline = (count, Data(digest.finalize()))
        }
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
                var digest = SHA256(), remaining = baseline.count
                while remaining > 0 {
                    guard let data = try file.read(upToCount: Int(min(64 * 1024, remaining))), !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    digest.update(data: data); remaining -= UInt64(data.count)
                }
                guard Data(digest.finalize()) == baseline.digest else { throw CocoaError(.fileReadCorruptFile) }
            } catch { try? file.close(); throw error }
            handle = file
            self.baseline = nil
        }
        return try handle?.read(upToCount: count)
    }
}
