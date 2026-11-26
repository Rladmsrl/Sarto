import Foundation

/// One file downloaded to `destination` with progress. A source that sends nothing for the stall
/// time fails with a timeout, so the updater moves on to the next one.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Failure: Error {
        case status(Int)
    }

    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var finishedResult: Result<URL, Error>?
    private var lastPercent = -1

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(
        _ url: URL,
        to destination: URL,
        userAgent: String,
        stallSeconds: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let download = FileDownload(destination: destination, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        // URLSession's request timeout is the longest wait for more data, connecting included.
        config.timeoutIntervalForRequest = TimeInterval(stallSeconds)
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let earlyResult: Result<URL, Error>? = download.lock.withLock {
                    if let finished = download.finishedResult {
                        return finished
                    }
                    download.continuation = continuation
                    return nil
                }
                if let earlyResult {
                    continuation.resume(with: earlyResult)
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100
        let whole = Int(percent)
        let changed = lock.withLock {
            guard whole != lastPercent else { return false }
            lastPercent = whole
            return true
        }
        if changed { onProgress(percent) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns, so it moves now.
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failure(Failure.status(http.statusCode))
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }
        lock.withLock { outcome = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, Result<URL, Error>) in
            let pending = self.continuation
            self.continuation = nil
            let finalResult: Result<URL, Error>
            if let error {
                finalResult = .failure(error)
            } else {
                finalResult = outcome ?? .failure(URLError(.badServerResponse))
            }
            if pending == nil {
                self.finishedResult = finalResult
            }
            return (pending, finalResult)
        }
        continuation?.resume(with: result)
    }
}
