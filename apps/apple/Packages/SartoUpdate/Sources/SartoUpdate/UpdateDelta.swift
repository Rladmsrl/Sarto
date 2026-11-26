import Compression
import CryptoKit
import Foundation

/// Builds a new Sarto.app from the running one and a delta (tools/sarto/delta.mjs), so an update
/// downloads what changed rather than the whole app. Every file of the new app must have the SHA-256
/// the delta names, and nothing it names may lie outside the app; the updater then checks the new
/// app's code signature as it checks a whole one, and downloads the zip when anything fails.
public enum UpdateDelta {
    public enum Failure: Error, Equatable, Sendable {
        /// The delta is not one: its header, manifest or an entry is wrong.
        case malformed(String)
        /// A file came out other than the delta says, or the old app lacks what it needs.
        case mismatch(String)
    }

    public struct Summary: Equatable, Sendable {
        public let from: String
        public let to: String
        public let files: Int
    }

    private static let magic = Data("SARTODELTA1\n".utf8)
    private static let maxManifest = 32 << 20

    /// Writes the new app to `newApp`, which must not exist yet.
    @discardableResult
    public static func apply(delta: URL, oldApp: URL, newApp: URL, fileManager: FileManager = .default) throws -> Summary {
        let bytes = try Data(contentsOf: delta, options: .alwaysMapped)
        guard bytes.count >= magic.count + 4, bytes.prefix(magic.count) == magic else {
            throw Failure.malformed("it has no delta header")
        }
        let lengthStart = bytes.startIndex + magic.count
        let length = bytes[lengthStart..<(lengthStart + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let manifestStart = lengthStart + 4
        guard length > 0, length <= maxManifest, manifestStart + length <= bytes.endIndex else {
            throw Failure.malformed("its manifest does not fit")
        }
        let payload = bytes[(manifestStart + length)...]
        guard let manifest = try? JSONSerialization.jsonObject(with: bytes[manifestStart..<(manifestStart + length)]) as? [String: Any],
              let from = manifest["from"] as? String, let to = manifest["to"] as? String,
              let entries = manifest["entries"] as? [[String: Any]]
        else { throw Failure.malformed("its manifest is not one") }

        guard !fileManager.fileExists(atPath: newApp.path) else { throw Failure.malformed("\(newApp.path) exists") }
        try fileManager.createDirectory(at: newApp, withIntermediateDirectories: true)
        do {
            var files = 0
            var seenPaths: Set<String> = []
            for entry in entries {
                guard let rel = entry["path"] as? String, let parts = safeParts(rel), let kind = entry["kind"] as? String else {
                    throw Failure.malformed("an entry names no path inside the app")
                }
                let normalizedRel = parts.joined(separator: "/").lowercased()
                guard seenPaths.insert(normalizedRel).inserted else {
                    throw Failure.malformed("the delta lists \(rel) twice")
                }
                let target = newApp.appendingPathComponent(parts.joined(separator: "/"))
                switch kind {
                case "dir":
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                case "link":
                    guard let destination = entry["target"] as? String, linkStaysInside(destination) else {
                        throw Failure.malformed("the link \(rel) points out of the app")
                    }
                    try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                case "file":
                    try writeFile(entry, rel: rel, to: target, oldApp: oldApp, payload: payload, fileManager: fileManager)
                    files += 1
                default:
                    throw Failure.malformed("the entry \(rel) is of no known kind")
                }
            }
            return Summary(from: from, to: to, files: files)
        } catch {
            try? fileManager.removeItem(at: newApp)
            throw error
        }
    }

    private static func writeFile(
        _ entry: [String: Any],
        rel: String,
        to target: URL,
        oldApp: URL,
        payload: Data,
        fileManager: FileManager
    ) throws {
        guard let size = integer(entry["size"]), size >= 0,
              let expected = entry["sha256"] as? String, expected.count == 64,
              let mode = integer(entry["mode"]), mode == 0o755 || mode == 0o644,
              let source = entry["source"] as? [String: Any], let type = source["type"] as? String
        else { throw Failure.malformed("the file \(rel) is not described") }

        var hasher = SHA256()
        var written = 0
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else {
            throw Failure.mismatch("\(rel) could not be written")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        func append(_ data: Data) throws {
            hasher.update(data: data)
            written += data.count
            try handle.write(contentsOf: data)
        }

        switch type {
        case "old":
            let old = try oldFile(source["path"], in: oldApp)
            try append(old)
        case "data":
            try append(try chunk(source["data"], of: payload, rel: rel, maxBytes: size))
        case "patch":
            let old = try oldFile(source["path"], in: oldApp)
            let literal = try chunk(source["data"], of: payload, rel: rel, maxBytes: max(size, 64 << 20))
            guard let ops = source["ops"] as? [[Any]] else { throw Failure.malformed("the patch of \(rel) has no ops") }
            var cursor = literal.startIndex
            for op in ops {
                guard let kind = integer(op.first) else { throw Failure.malformed("the patch of \(rel) has a bad op") }
                if kind == 0, op.count == 3, let offset = integer(op[1]), let count = integer(op[2]),
                   offset >= 0, count >= 0, offset + count <= old.count {
                    try append(old[(old.startIndex + offset)..<(old.startIndex + offset + count)])
                } else if kind == 1, op.count == 2, let count = integer(op[1]), count >= 0,
                          cursor + count <= literal.endIndex {
                    try append(literal[cursor..<(cursor + count)])
                    cursor += count
                } else {
                    throw Failure.malformed("the patch of \(rel) has a bad op")
                }
            }
        default:
            throw Failure.malformed("the file \(rel) comes from nowhere known")
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard written == size, digest == expected else {
            throw Failure.mismatch("\(rel) does not match the delta")
        }
        if fchmod(fd, mode_t(mode)) != 0 {
            throw Failure.mismatch("\(rel) could not set permissions")
        }
    }

    private static func oldFile(_ value: Any?, in oldApp: URL) throws -> Data {
        guard let rel = value as? String, let parts = safeParts(rel) else {
            throw Failure.malformed("an entry names no old file inside the app")
        }
        let url = oldApp.appendingPathComponent(parts.joined(separator: "/"))
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw Failure.mismatch("the running app has no \(rel)")
        }
        return data
    }

    private static func chunk(_ value: Any?, of payload: Data, rel: String, maxBytes: Int) throws -> Data {
        guard let range = value as? [Any], range.count == 2,
              let offset = integer(range[0]), let count = integer(range[1]),
              offset >= 0, count >= 0, offset + count <= payload.count
        else { throw Failure.malformed("the data of \(rel) lies outside the delta") }
        let start = payload.startIndex + offset
        let compressed = Data(payload[start..<(start + count)])
        return try inflateZlib(compressed, maxBytes: maxBytes, rel: rel)
    }

    private static func inflateZlib(_ compressed: Data, maxBytes: Int, rel: String) throws -> Data {
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(
            dst_ptr: dummy,
            dst_size: 0,
            src_ptr: dummy,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.malformed("the data of \(rel) does not inflate")
        }
        defer { compression_stream_destroy(&stream) }

        let scratchSize = 64 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }

        var output = Data()
        let ok: Bool = compressed.withUnsafeBytes { rawBuf in
            guard let srcBase = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return compressed.isEmpty
            }
            stream.src_ptr = srcBase
            stream.src_size = compressed.count
            while true {
                stream.dst_ptr = scratch
                stream.dst_size = scratchSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = scratchSize - stream.dst_size
                if produced > 0 {
                    if output.count + produced > maxBytes {
                        return false
                    }
                    output.append(scratch, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    return true
                }
                if status != COMPRESSION_STATUS_OK {
                    return false
                }
            }
        }
        guard ok else {
            throw Failure.malformed("the data of \(rel) does not inflate")
        }
        return output
    }

    /// The components of a relative path inside the app; nil for one that is absolute, empty or
    /// steps out of it.
    static func safeParts(_ rel: String) -> [String]? {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("\0") else { return nil }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    /// Whether a link to `destination` stays inside the app. Only a relative link that
    /// never steps up does, whatever links it passes through: one that steps up could go through
    /// another link the delta made first, which reading its text alone would not see.
    static func linkStaysInside(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("/"), !destination.contains("\0") else { return false }
        return !destination.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }
}
