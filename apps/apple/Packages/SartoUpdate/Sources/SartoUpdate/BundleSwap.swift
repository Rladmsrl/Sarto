import Darwin
import Foundation

public enum BundleSwap {
    /// Exchanges what two paths on one volume hold in a single rename, so neither is ever missing.
    public static func exchange(_ a: URL, _ b: URL) throws {
        let result = a.withUnsafeFileSystemRepresentation { left in
            b.withUnsafeFileSystemRepresentation { right in
                renamex_np(left, right, UInt32(RENAME_SWAP))
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Puts `staged` in place of `app` and returns where the replaced bundle now is, for the next
    /// launch to delete. A staged bundle on another volume is copied next to `app` first, since a
    /// rename cannot cross volumes; the replaced bundle is then deleted here, as nothing cleans the
    /// app's own folder, and nil is returned. `exchange` is the rename, for the tests to refuse.
    @discardableResult
    public static func install(
        staged: URL,
        over app: URL,
        fileManager: FileManager = .default,
        exchange: (URL, URL) throws -> Void = BundleSwap.exchange
    ) throws -> URL? {
        do {
            try exchange(staged, app)
            return staged
        } catch let error as POSIXError where error.code == .EXDEV {
            let sibling = app.deletingLastPathComponent()
                .appendingPathComponent("\(leftoverPrefix(app))\(UUID().uuidString).app")
            try fileManager.copyItem(at: staged, to: sibling)
            do {
                try exchange(sibling, app)
            } catch {
                try? fileManager.removeItem(at: sibling)
                throw error
            }
            // `sibling` now holds the replaced app. Its running process keeps the files it has open.
            try? fileManager.removeItem(at: sibling)
            try? fileManager.removeItem(at: staged)
            return nil
        }
    }

    private static func leftoverPrefix(_ app: URL) -> String {
        ".\(app.deletingPathExtension().lastPathComponent)-update-"
    }

    /// Deletes the bundles a swap across volumes left beside `app`: those an earlier version never
    /// deleted, and one whose deletion failed. Only `.<name>-update-<UUID>.app` is one.
    public static func removeLeftovers(beside app: URL, fileManager: FileManager = .default) {
        let folder = app.deletingLastPathComponent()
        let prefix = leftoverPrefix(app)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".app") {
            let id = name.dropFirst(prefix.count).dropLast(".app".count)
            guard UUID(uuidString: String(id)) != nil else { continue }
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
