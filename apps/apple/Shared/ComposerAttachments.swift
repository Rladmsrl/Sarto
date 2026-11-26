import CoreGraphics
import Foundation
import ImageIO
import SartoProtocol
import PrismDesign
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Attachment Limits (matching src/shared/attachments.ts)

public enum AttachmentLimits {
    public static let maxAttachments = 20
    public static let maxAttachmentBytes = 20 * 1024 * 1024
    public static let maxImageSide = 2000
    public static let maxImageBytes = Int(3.75 * 1024 * 1024)
    public static let maxPromptBytes = 10 * 1024 * 1024
    public static let thumbSide = 224
    public static let maxThumbChars = 256 * 1024
    public static let embedTextBytes = 256 * 1024
    /// Largest source image read before it is scaled down to `maxImageBytes`.
    public static let maxSourceImageBytes = 50 * 1024 * 1024
    /// Most pixels a source image may declare; decoding a larger one would take gigabytes.
    public static let maxSourceImagePixels = 100_000_000
}

// MARK: - Draft Attachment Model

public struct DraftAttachmentItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case image
        case file
        case folder
        case text
    }

    public enum Status: Sendable, Equatable {
        case preparing
        case ready(AttachmentInfo)
        case failed(String)
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var mimeType: String
    public var size: Int
    public var status: Status
    public var thumbnailData: Data?
    public var thumbDataURL: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Retains full prepared image bytes locally for crisp instant preview lightbox before/after upload.
    public var previewImageData: Data?
    /// Retains pasted long text locally for instant viewing and "Paste as text" without a host round-trip.
    public var pastedTextBody: String?
    /// Relative path inside the project when added via `@` mention, used to link inline chips.
    public var projectRelativePath: String?
    /// True when a restored draft attachment's host record has expired and cannot be removed remotely.
    public var goneOnHost: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        mimeType: String,
        size: Int = 0,
        status: Status = .preparing,
        thumbnailData: Data? = nil,
        thumbDataURL: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        previewImageData: Data? = nil,
        pastedTextBody: String? = nil,
        projectRelativePath: String? = nil,
        goneOnHost: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mimeType = mimeType
        self.size = size
        self.status = status
        self.thumbnailData = thumbnailData
        self.thumbDataURL = thumbDataURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.previewImageData = previewImageData
        self.pastedTextBody = pastedTextBody
        self.projectRelativePath = projectRelativePath
        self.goneOnHost = goneOnHost
    }

    /// Mention token label used to match inline `@name` or `@folder/` chips in composer text.
    public var mentionTokenName: String {
        kind == .folder ? (name.hasSuffix("/") ? name : "\(name)/") : name
    }

    public var readyAttachment: AttachmentInfo? {
        if case .ready(let info) = status { return info }
        return nil
    }

    public var isPreparing: Bool {
        if case .preparing = status { return true }
        return false
    }

    public var failureMessage: String? {
        if case .failed(let msg) = status { return msg }
        return nil
    }

    /// Estimated contribution to Sarto's `PROMPT_BYTES` (10 MB) budget.
    /// Text attachments `<= embedTextBytes` are sent inline; larger text/files/folders go as ~256 B `ContentRef` links.
    public var estimatedPromptBytes: Int {
        switch kind {
        case .image:
            return ((size * 4) + 2) / 3
        case .text:
            return size <= AttachmentLimits.embedTextBytes ? size : 256
        case .file:
            return AttachmentPreparer.isTextMimeType(mimeType) && size <= AttachmentLimits.embedTextBytes ? size : 256
        case .folder:
            return 256
        }
    }
}

// MARK: - Persistent Composer Draft Store (mirrors src/renderer/src/features/session/composer/drafts.ts)

public struct PersistedDraftAttachment: Codable, Sendable, Equatable {
    public let attachment: AttachmentInfo
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let projectRelativePath: String?

    public init(
        attachment: AttachmentInfo,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        projectRelativePath: String? = nil
    ) {
        self.attachment = attachment
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.projectRelativePath = projectRelativePath
    }

    public func toDraftItem() -> DraftAttachmentItem {
        let kind: DraftAttachmentItem.Kind
        switch attachment.type {
        case "image": kind = .image
        case "folder": kind = .folder
        case "text": kind = .text
        default: kind = .file
        }
        return DraftAttachmentItem(
            name: attachment.name,
            kind: kind,
            mimeType: attachment.mimeType ?? (kind == .text ? "text/plain" : "application/octet-stream"),
            size: attachment.size ?? 0,
            status: .ready(attachment),
            thumbnailData: PrismImageDecoder.decodeDataURL(attachment.thumb),
            thumbDataURL: attachment.thumb,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            projectRelativePath: projectRelativePath
        )
    }
}

public struct PersistedComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [PersistedDraftAttachment]
    public var comments: [DraftReplyComment]
    public var sessionReferences: [DraftSessionReference]

    public init(
        text: String = "",
        attachments: [PersistedDraftAttachment] = [],
        comments: [DraftReplyComment] = [],
        sessionReferences: [DraftSessionReference] = []
    ) {
        self.text = text
        self.attachments = attachments
        self.comments = comments
        self.sessionReferences = sessionReferences
    }

    enum CodingKeys: String, CodingKey {
        case text, attachments, comments, sessionReferences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.attachments = (try? c.decode([PersistedDraftAttachment].self, forKey: .attachments)) ?? []
        self.comments = (try? c.decode([DraftReplyComment].self, forKey: .comments)) ?? []
        self.sessionReferences = (try? c.decode([DraftSessionReference].self, forKey: .sessionReferences)) ?? []
    }

    public var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && comments.isEmpty && sessionReferences.isEmpty
    }
}

/// Persists unsent composer drafts (text, ready attachments, passage comments) per session scope
/// to Application Support with a 300ms debounce and 1 MB per-draft cap.
@MainActor
public final class ComposerDraftStore {
    private static let maxDraftBytes = 1024 * 1024
    private static let debounceNs: UInt64 = 300_000_000

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "dev.sarto.composer-drafts.io", qos: .utility)
    private var cache: [String: PersistedComposerDraft] = [:]
    private var flushTask: Task<Void, Never>?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = appSupport
                .appendingPathComponent("Sarto", isDirectory: true)
                .appendingPathComponent("composer-drafts.json", isDirectory: false)
        }
        self.cache = Self.loadFromDisk(url: self.fileURL)
    }

    public func allDrafts() -> [String: PersistedComposerDraft] {
        cache
    }

    public func update(scope: String, draft: PersistedComposerDraft) {
        if draft.isEmpty {
            cache.removeValue(forKey: scope)
        } else {
            cache[scope] = draft
        }
        scheduleFlush()
    }

    public func remove(scope: String) {
        if cache.removeValue(forKey: scope) != nil {
            scheduleFlush()
        }
    }

    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        writeToDisk(wait: true)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNs)
            guard !Task.isCancelled else { return }
            self?.writeToDisk(wait: false)
        }
    }

    private func writeToDisk(wait: Bool) {
        let snapshot = cache.filter { !$0.value.isEmpty }
        let targetURL = fileURL
        let maxBytes = Self.maxDraftBytes

        let work: @Sendable () -> Void = {
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: targetURL)
                return
            }
            let encoder = JSONEncoder()
            var obj: [String: Data] = [:]
            for (scope, draft) in snapshot {
                if let data = try? encoder.encode(draft), data.count <= maxBytes {
                    obj[scope] = data
                }
            }
            if obj.isEmpty {
                try? FileManager.default.removeItem(at: targetURL)
                return
            }
            // Assemble single-pass JSON object from already-encoded per-scope slices without double encoding.
            var assembled = Data("{".utf8)
            var first = true
            for key in obj.keys.sorted() {
                guard let keyJSON = try? encoder.encode(key), let valJSON = obj[key] else { continue }
                if !first { assembled.append(0x2C) }
                first = false
                assembled.append(keyJSON)
                assembled.append(0x3A)
                assembled.append(valJSON)
            }
            assembled.append(0x7D)

            let dir = targetURL.deletingLastPathComponent()
            #if os(macOS)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            #else
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #endif
            try? assembled.write(to: targetURL, options: [.atomic])
            #if os(macOS)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            #endif
        }

        if wait {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    private static func loadFromDisk(url: URL) -> [String: PersistedComposerDraft] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: PersistedComposerDraft].self, from: data)
        else { return [:] }
        return decoded
    }
}

public struct PreparedAttachmentPayload: Sendable {
    public let name: String
    public let kind: DraftAttachmentItem.Kind
    public let mimeType: String
    public let bytes: Data
    public let thumbnailData: Data?
    public let thumbDataURL: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
}

public enum AttachmentPrepareError: Error, Sendable {
    case unreadable
    case tooLarge
    case empty
    case directoryNotSupported
}

// MARK: - Cross-Platform ImageIO & File Preparer

public enum AttachmentPreparer {
    private static let modelImageTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
    ]

    private static let textExtensionMime: [String: String] = [
        "txt": "text/plain",
        "log": "text/plain",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "csv": "text/csv",
        "tsv": "text/tab-separated-values",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "cjs": "text/javascript",
        "jsx": "text/javascript",
        "ts": "text/x-typescript",
        "tsx": "text/x-typescript",
        "py": "text/x-python",
        "go": "text/x-go",
        "rs": "text/x-rust",
        "java": "text/x-java",
        "c": "text/x-c",
        "h": "text/x-c",
        "cpp": "text/x-c++",
        "hpp": "text/x-c++",
        "swift": "text/x-swift",
        "json": "application/json",
        "xml": "application/xml",
        "yaml": "application/yaml",
        "yml": "application/yaml",
        "toml": "application/toml",
        "sql": "application/sql",
        "sh": "application/x-sh",
        "zsh": "application/x-sh",
        "svg": "image/svg+xml",
    ]

    private static let textApplicationTypes: Set<String> = [
        "application/json",
        "application/xml",
        "application/yaml",
        "application/toml",
        "application/sql",
        "application/x-sh",
        "image/svg+xml",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif",
    ]

    public static func isTextMimeType(_ mime: String) -> Bool {
        mime.hasPrefix("text/") || textApplicationTypes.contains(mime)
    }

    public static func looksLikeImage(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let ut = UTType(filenameExtension: ext) {
            return ut.conforms(to: .image) && ut != .svg
        }
        return false
    }

    public static func prepareFile(url: URL, manageSecurityScope: Bool = true) throws -> PreparedAttachmentPayload {
        let accessed = manageSecurityScope ? url.startAccessingSecurityScopedResource() : false
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true {
            throw AttachmentPrepareError.directoryNotSupported
        }

        let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let isImage = looksLikeImage(url: url) || ((values?.contentType?.conforms(to: .image) ?? false) && ext != "svg")

        // Source images may be larger than the attachment limit since prepareImage scales them down.
        let maxReadBytes = isImage ? AttachmentLimits.maxSourceImageBytes : AttachmentLimits.maxAttachmentBytes
        if let fileSize = values?.fileSize, fileSize > maxReadBytes {
            throw AttachmentPrepareError.tooLarge
        }

        guard let rawData = try? Data(contentsOf: url) else {
            throw AttachmentPrepareError.unreadable
        }
        guard !rawData.isEmpty else {
            throw AttachmentPrepareError.empty
        }
        if rawData.count > maxReadBytes {
            throw AttachmentPrepareError.tooLarge
        }

        if isImage {
            return try prepareImage(data: rawData, name: name)
        }

        let mime = resolveFileMimeType(ext: ext, contentType: values?.contentType, data: rawData)
        let kind: DraftAttachmentItem.Kind = isTextMimeType(mime) ? .text : .file
        return PreparedAttachmentPayload(
            name: name,
            kind: kind,
            mimeType: mime,
            bytes: rawData,
            thumbnailData: nil,
            thumbDataURL: nil,
            pixelWidth: nil,
            pixelHeight: nil
        )
    }

    public static func prepareImage(data: Data, name: String) throws -> PreparedAttachmentPayload {
        guard !data.isEmpty else { throw AttachmentPrepareError.empty }
        guard data.count <= AttachmentLimits.maxSourceImageBytes else { throw AttachmentPrepareError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AttachmentPrepareError.unreadable
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let rawHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = orientation >= 5 && orientation <= 8
        let displayWidth = swapped ? rawHeight : rawWidth
        let displayHeight = swapped ? rawWidth : rawHeight
        guard displayWidth > 0, displayHeight > 0 else {
            throw AttachmentPrepareError.unreadable
        }
        // Checked from the header before any pixel is decoded.
        let (pixels, overflow) = rawWidth.multipliedReportingOverflow(by: rawHeight)
        guard !overflow, pixels <= AttachmentLimits.maxSourceImagePixels else {
            throw AttachmentPrepareError.tooLarge
        }

        let detectedMime = detectModelImageMime(data)
        let frameCount = CGImageSourceGetCount(source)

        // Generate 224px JPEG thumbnail (validated by host: data:image/(webp|png|jpeg);base64,...).
        let thumbData = makeThumbnailJPEG(source: source, maxSide: AttachmentLimits.thumbSide, quality: 0.78)
        let thumbURL: String? = thumbData.flatMap { td in
            let url = "data:image/jpeg;base64,\(td.base64EncodedString())"
            return url.count <= AttachmentLimits.maxThumbChars ? url : nil
        }

        let fitsDimensions = max(displayWidth, displayHeight) <= AttachmentLimits.maxImageSide
        let fitsSize = data.count <= AttachmentLimits.maxImageBytes
        let needsOrientTransform = orientation != 1

        // Keep original bytes untouched if already a model-native image type, normal orientation, and within limits.
        if let detectedMime,
           modelImageTypes.contains(detectedMime),
           fitsDimensions,
           fitsSize,
           (!needsOrientTransform || frameCount > 1) {
            return PreparedAttachmentPayload(
                name: ensureImageExtension(name: name, mimeType: detectedMime),
                kind: .image,
                mimeType: detectedMime,
                bytes: data,
                thumbnailData: thumbData ?? data,
                thumbDataURL: thumbURL,
                pixelWidth: displayWidth,
                pixelHeight: displayHeight
            )
        }

        // Scale and/or transcode to PNG (if alpha and compact) or JPEG <= 3.75 MB.
        let targetSide = min(max(displayWidth, displayHeight), AttachmentLimits.maxImageSide)
        guard let scaledCG = makeOrientedCGImage(source: source, maxSide: targetSide) else {
            throw AttachmentPrepareError.unreadable
        }

        let hasAlpha = imageHasAlpha(scaledCG)
        var finalBytes: Data?
        var finalMime = "image/jpeg"
        var finalWidth = scaledCG.width
        var finalHeight = scaledCG.height

        if hasAlpha && detectedMime == "image/png" {
            if let png = encodeCGImage(scaledCG, utType: UTType.png.identifier as CFString, quality: nil),
               png.count <= AttachmentLimits.maxImageBytes {
                finalBytes = png
                finalMime = "image/png"
            }
        }

        if finalBytes == nil {
            let qualities: [CGFloat] = [0.88, 0.78, 0.68, 0.56]
            for q in qualities {
                if let jpg = encodeCGImage(scaledCG, utType: UTType.jpeg.identifier as CFString, quality: q),
                   jpg.count <= AttachmentLimits.maxImageBytes {
                    finalBytes = jpg
                    finalMime = "image/jpeg"
                    break
                }
            }
        }

        if finalBytes == nil {
            // Last resort: step down pixel dimensions until within maxImageBytes.
            for side in [1500, 1200, 900] {
                if let smaller = makeOrientedCGImage(source: source, maxSide: side),
                   let jpg = encodeCGImage(smaller, utType: UTType.jpeg.identifier as CFString, quality: 0.72),
                   jpg.count <= AttachmentLimits.maxImageBytes {
                    finalBytes = jpg
                    finalMime = "image/jpeg"
                    finalWidth = smaller.width
                    finalHeight = smaller.height
                    break
                }
            }
        }

        guard let encodedBytes = finalBytes else {
            throw AttachmentPrepareError.tooLarge
        }

        return PreparedAttachmentPayload(
            name: ensureImageExtension(name: name, mimeType: finalMime),
            kind: .image,
            mimeType: finalMime,
            bytes: encodedBytes,
            thumbnailData: thumbData ?? encodedBytes,
            thumbDataURL: thumbURL,
            pixelWidth: finalWidth,
            pixelHeight: finalHeight
        )
    }

    private static func makeOrientedCGImage(source: CGImageSource, maxSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeThumbnailJPEG(source: CGImageSource, maxSide: Int, quality: CGFloat) -> Data? {
        guard let cg = makeOrientedCGImage(source: source, maxSide: maxSide) else { return nil }
        return encodeCGImage(cg, utType: UTType.jpeg.identifier as CFString, quality: quality)
    }

    private static func encodeCGImage(_ image: CGImage, utType: CFString, quality: CGFloat?) -> Data? {
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, utType, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props.isEmpty ? nil : (props as CFDictionary))
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    private static func detectModelImageMime(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
            && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A {
            return "image/png"
        }
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
            return "image/jpeg"
        }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38
            && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61 {
            return "image/gif"
        }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }

    private static func ensureImageExtension(name: String, mimeType: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        let desiredExt: String
        switch mimeType {
        case "image/png": desiredExt = "png"
        case "image/jpeg": desiredExt = "jpg"
        case "image/gif": desiredExt = "gif"
        case "image/webp": desiredExt = "webp"
        default: desiredExt = ext.isEmpty ? "jpg" : ext
        }
        if ext == desiredExt || (desiredExt == "jpg" && ext == "jpeg") {
            return name
        }
        let stem = base.isEmpty ? "image" : base
        return "\(stem).\(desiredExt)"
    }

    private static func resolveFileMimeType(ext: String, contentType: UTType?, data: Data) -> String {
        let candidate: String
        if let mapped = textExtensionMime[ext] {
            candidate = mapped
        } else if let preferred = contentType?.preferredMIMEType, !preferred.isEmpty {
            candidate = preferred
        } else if ext == "pdf" {
            candidate = "application/pdf"
        } else if ext == "zip" {
            candidate = "application/zip"
        } else {
            candidate = "application/octet-stream"
        }

        // Verify valid UTF-8 with no NUL bytes before labeling as a text MIME type, matching host attachments.ts.
        if isTextMimeType(candidate) {
            let probe = data.prefix(8000)
            if probe.contains(0) || String(data: data, encoding: .utf8) == nil {
                return "application/octet-stream"
            }
        }
        return candidate
    }
}

// MARK: - Data URL & Platform Image Helpers

public enum PrismImageDecoder {
    /// Longest side kept for on-screen images; larger sources are downsampled by ImageIO.
    static let maxDisplayPixelSide = 2048

    private final class ImageEntry {
        let image: Image?
        init(_ image: Image?) { self.image = image }
    }

    private final class DataEntry {
        let data: Data
        init(_ data: Data) { self.data = data }
    }

    private final class Caches: @unchecked Sendable {
        let images = NSCache<NSString, ImageEntry>()
        let dataURLs = NSCache<NSString, DataEntry>()

        init() {
            images.totalCostLimit = 96 * 1024 * 1024
            images.countLimit = 512
            dataURLs.totalCostLimit = 16 * 1024 * 1024
            dataURLs.countLimit = 512
        }
    }

    private static let caches = Caches()

    /// Decoded bytes of a `data:image/...;base64,` URL, cached so view bodies can call it freely.
    public static func decodeDataURL(_ dataURL: String?) -> Data? {
        guard let dataURL,
              dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ",")
        else { return nil }
        let key = "u:\(fingerprint(of: dataURL))" as NSString
        if let hit = caches.dataURLs.object(forKey: key) {
            return hit.data
        }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            return nil
        }
        caches.dataURLs.setObject(DataEntry(data), forKey: key, cost: data.count)
        return data
    }

    public static func swiftUIImage(from data: Data?) -> Image? {
        swiftUIImage(from: data, cacheKey: nil)
    }

    /// A downsampled image for `data`, decoded once and then served from a bounded cache.
    /// `cacheKey` names bytes that never change under it, such as an attachment id or blob hash;
    /// without one the bytes are identified by their length and a sample of their content.
    public static func swiftUIImage(from data: Data?, cacheKey: String?) -> Image? {
        guard let data, !data.isEmpty else { return nil }
        let key = imageCacheKey(data: data, cacheKey: cacheKey)
        if let hit = caches.images.object(forKey: key) {
            return hit.image
        }
        let decoded = decodeDownsampled(data)
        caches.images.setObject(ImageEntry(decoded?.image), forKey: key, cost: decoded?.cost ?? 64)
        return decoded?.image
    }

    /// Like `swiftUIImage(from:cacheKey:)`, decoding off the main thread on a cache miss.
    public static func decodedImage(from data: Data, cacheKey: String?) async -> Image? {
        guard !data.isEmpty else { return nil }
        let key = imageCacheKey(data: data, cacheKey: cacheKey)
        if let hit = caches.images.object(forKey: key) {
            return hit.image
        }
        let cgImage = await Task.detached(priority: .userInitiated) {
            downsampledCGImage(data)
        }.value
        let decoded = cgImage.map { (image: platformImage($0), cost: $0.bytesPerRow * $0.height) }
            ?? decodePlatformImage(data)
        caches.images.setObject(ImageEntry(decoded?.image), forKey: key, cost: decoded?.cost ?? 64)
        return decoded?.image
    }

    private static func imageCacheKey(data: Data, cacheKey: String?) -> NSString {
        if let cacheKey { return "k:\(cacheKey)" as NSString }
        return "d:\(fingerprint(of: data))" as NSString
    }

    private static func decodeDownsampled(_ data: Data) -> (image: Image, cost: Int)? {
        if let cgImage = downsampledCGImage(data) {
            return (platformImage(cgImage), cgImage.bytesPerRow * cgImage.height)
        }
        return decodePlatformImage(data)
    }

    private static func downsampledCGImage(_ data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= AttachmentLimits.maxSourceImagePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxDisplayPixelSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func platformImage(_ cgImage: CGImage) -> Image {
        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        #else
        return Image(uiImage: UIImage(cgImage: cgImage))
        #endif
    }

    /// Formats ImageIO cannot read (such as SVG or PDF) still go through the platform image class.
    private static func decodePlatformImage(_ data: Data) -> (image: Image, cost: Int)? {
        guard data.count <= AttachmentLimits.maxSourceImageBytes else { return nil }
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return (Image(nsImage: nsImage), data.count)
        #elseif os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return (Image(uiImage: uiImage), data.count)
        #else
        return nil
        #endif
    }

    /// Length plus a hash of evenly spaced 64-byte windows: constant time for any size, and
    /// distinct for different encoded images in practice since their compressed bytes differ.
    static func fingerprint(of data: Data) -> String {
        data.withUnsafeBytes { fingerprint(bytes: $0) }
    }

    static func fingerprint(of string: String) -> String {
        var copy = string
        return copy.withUTF8 { fingerprint(bytes: UnsafeRawBufferPointer($0)) }
    }

    private static func fingerprint(bytes: UnsafeRawBufferPointer) -> String {
        let count = bytes.count
        let window = 64
        var hasher = Hasher()
        hasher.combine(count)
        for slot in 0...16 {
            let start = max(0, min(count * slot / 16, count - window))
            let end = min(count, start + window)
            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
        }
        return "\(count)-\(hasher.finalize())"
    }

    public static func formatByteCount(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    public static func symbolName(for filename: String, mimeType: String?, type: String) -> String {
        if type == "folder" { return "folder.fill" }
        if type == "image" { return "photo" }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" || mimeType == "application/pdf" { return "doc.richtext" }
        if ["zip", "gz", "tar", "7z", "rar"].contains(ext) { return "doc.zipper" }
        if ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "cpp", "h", "java", "sh", "sql", "json", "yaml", "yml", "toml", "html", "css"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if type == "text" || ["md", "txt", "log", "csv"].contains(ext) { return "doc.text" }
        return "doc"
    }
}

// MARK: - Obsidian Prism Composer Attachment Tray

public struct ComposerAttachmentTrayView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    public let items: [DraftAttachmentItem]
    /// Attachment IDs currently represented by inline `@` chips in the editor text, hidden here to avoid duplicates.
    public let hiddenIDs: Set<UUID>
    public let onRemove: (UUID) -> Void
    public let onPreviewImage: (String, Data) -> Void
    public let onOpenText: ((DraftAttachmentItem) -> Void)?

    public init(
        items: [DraftAttachmentItem],
        hiddenIDs: Set<UUID> = [],
        onRemove: @escaping (UUID) -> Void,
        onPreviewImage: @escaping (String, Data) -> Void,
        onOpenText: ((DraftAttachmentItem) -> Void)? = nil
    ) {
        self.items = items
        self.hiddenIDs = hiddenIDs
        self.onRemove = onRemove
        self.onPreviewImage = onPreviewImage
        self.onOpenText = onOpenText
    }

    private var visibleItems: [DraftAttachmentItem] {
        if hiddenIDs.isEmpty { return items }
        return items.filter { !hiddenIDs.contains($0.id) }
    }

    public var body: some View {
        let shown = visibleItems
        if !shown.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shown) { item in
                        attachmentTile(item)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func attachmentTile(_ item: DraftAttachmentItem) -> some View {
        let failed = item.failureMessage != nil
        let parsedThumb = item.kind == .text ? ComposerAttachmentRules.readTextThumb(item.thumbDataURL) : nil

        ZStack(alignment: .topTrailing) {
            if item.kind == .image, let img = PrismImageDecoder.swiftUIImage(from: item.thumbnailData) {
                Button {
                    if let full = item.previewImageData ?? item.thumbnailData {
                        onPreviewImage(item.name, full)
                    }
                } label: {
                    ZStack {
                        img
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipped()

                        if item.isPreparing {
                            Color.black.opacity(0.45)
                            PrismTurnDotsView(phase: .thinking, size: 16, tint: .white)
                        } else if failed {
                            Color.black.opacity(0.55)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(tokens.danger)
                        }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(failed ? tokens.danger.opacity(0.75) : tokens.borderStrong, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(tileTooltip(item))
            } else if item.kind == .text, let parsedThumb {
                Button {
                    onOpenText?(item)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(parsedThumb.lines.prefix(2).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            if item.isPreparing {
                                PrismTurnDotsView(phase: .thinking, size: 9)
                            } else if failed {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(tokens.danger)
                            } else {
                                Image(systemName: "doc.plaintext")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(tokens.prismCobalt)
                            }
                            Text(item.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Text(l10n.tr("composer.attachments.lines", parsedThumb.count))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(tokens.placeholder)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 22)
                    .padding(.vertical, 6)
                    .frame(width: 176, height: 58, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(tokens.surface1.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(failed ? tokens.danger.opacity(0.65) : tokens.borderEtched, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(tileTooltip(item))
            } else {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .fill(failed ? tokens.dangerSoft : tokens.surface2)
                            .frame(width: 30, height: 30)
                        if item.isPreparing {
                            PrismTurnDotsView(phase: .thinking, size: 13)
                        } else if failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(tokens.danger)
                        } else {
                            Image(systemName: PrismImageDecoder.symbolName(for: item.name, mimeType: item.mimeType, type: item.kind.rawValue))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(tokens.prismCobalt)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let err = item.failureMessage {
                            Text(err)
                                .font(.system(size: 9.5))
                                .foregroundStyle(tokens.danger)
                                .lineLimit(1)
                        } else if item.isPreparing {
                            Text(l10n.tr("composer.attachmentsUploading"))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(tokens.prismCobalt)
                                .lineLimit(1)
                        } else if item.kind == .folder {
                            Text(l10n.tr("composer.mentions.folder"))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        } else {
                            Text(PrismImageDecoder.formatByteCount(item.size))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 132, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, 24)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(tokens.surface1.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(failed ? tokens.danger.opacity(0.65) : tokens.borderEtched, lineWidth: 1)
                )
                .help(tileTooltip(item))
            }

            // Crisp top-right remove button
            Button {
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                    onRemove(item.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tokens.foreground)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(tokens.background.opacity(0.92)))
                    .overlay(Circle().strokeBorder(tokens.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .help(l10n.tr("composer.removeAttachment"))
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    private func tileTooltip(_ item: DraftAttachmentItem) -> String {
        if let err = item.failureMessage {
            return "\(item.name) — \(err)"
        }
        var parts = [item.name]
        if let w = item.pixelWidth, let h = item.pixelHeight {
            parts.append("\(w)×\(h)")
        }
        let sz = PrismImageDecoder.formatByteCount(item.size)
        if !sz.isEmpty { parts.append(sz) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pasted Text Attachment Preview & Paste-as-Text Sheet

public struct PrismTextAttachmentSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let item: DraftAttachmentItem
    public let loadText: () async -> String?
    public let onPasteAsText: (String) -> Void

    @State private var loadedText: String?
    @State private var isLoading = true

    public init(
        item: DraftAttachmentItem,
        loadText: @escaping () async -> String?,
        onPasteAsText: @escaping (String) -> Void
    ) {
        self.item = item
        self.loadText = loadText
        self.onPasteAsText = onPasteAsText
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                Text(item.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                if let text = loadedText {
                    Text(l10n.tr("composer.attachments.lines", ComposerAttachmentRules.lineCount(text)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer()
                if let text = loadedText {
                    Button {
                        onPasteAsText(text)
                        dismiss()
                    } label: {
                        Text(l10n.tr("composer.attachments.pasteAsText"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tokens.onPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tokens.primary))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    dismiss()
                } label: {
                    Text(l10n.tr("composer.previewClose"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(tokens.surface2))
                        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = loadedText {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tokens.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            } else {
                Text(l10n.tr("composer.attachmentsUnreadable"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .background(tokens.background)
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 380)
        #endif
        .task(id: item.id) {
            if let local = item.pastedTextBody {
                loadedText = local
                isLoading = false
                return
            }
            loadedText = await loadText()
            isLoading = false
        }
    }
}

// MARK: - Full-Resolution Image Preview Lightbox

public struct PrismImagePreviewItem: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let data: Data

    public init(title: String, data: Data) {
        self.title = title
        self.data = data
    }
}

public struct PrismImageLightboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let item: PrismImagePreviewItem

    @State private var image: Image?

    public init(item: PrismImagePreviewItem) {
        self.item = item
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(PrismImageDecoder.formatByteCount(item.data.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                Button {
                    dismiss()
                } label: {
                    Text(l10n.tr("composer.previewClose"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(tokens.surface2))
                        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760, maxHeight: 540)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(tokens.borderEtched, lineWidth: 1)
                    )
            }
        }
        .padding(18)
        .background(tokens.background)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
        .task(id: item.id) {
            image = await PrismImageDecoder.decodedImage(from: item.data, cacheKey: item.id.uuidString)
        }
    }
}
