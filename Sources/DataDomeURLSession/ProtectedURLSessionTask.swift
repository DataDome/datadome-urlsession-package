//
//  ProtectedURLSessionTask.swift
//  DataDomeURLSession
//

import Foundation

/// A protected request started with a completion handler.
///
/// It stands in for `URLSessionTask`: one protected request can span several underlying tasks (the original
/// and every retry after a resolved challenge), so there is no single `URLSessionTask` to hand back. Like a
/// `URLSessionTask`, it is created suspended and starts on ``resume()``.
public final class ProtectedURLSessionTask: @unchecked Sendable {
    // State is guarded by `lock`.
    private let lock = NSLock()
    private var operation: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?

    init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    /// Starts the request. Has no effect once the request has started.
    public func resume() {
        lock.withLock {
            start(cancelled: false)
        }
    }

    /// Cancels the request. Its completion handler is called with `URLError(.cancelled)`, even if it was never
    /// resumed, as with `URLSessionTask`.
    public func cancel() {
        lock.withLock {
            start(cancelled: true)
            task?.cancel()
        }
    }

    /// Must be called with `lock` held.
    private func start(cancelled: Bool) {
        guard let operation else {
            return
        }
        self.operation = nil
        task = Task {
            // Cancelled before it was resumed: the task marks itself cancelled before running the operation.
            // Cancelling it from `cancel()` alone races with it starting, which could send the request.
            if cancelled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            await operation()
        }
    }
}

// MARK: - Completion handlers

extension ProtectedURLSession {
    /// Like `URLSession.dataTask(with:completionHandler:)`. The handler is called on an arbitrary thread.
    public func dataTask(with request: URLRequest,
                         completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        makeTask({ [self] in try await data(for: request) }, completionHandler: completionHandler)
    }

    public func dataTask(with url: URL,
                         completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        dataTask(with: URLRequest(url: url), completionHandler: completionHandler)
    }

    /// Like `URLSession.uploadTask(with:from:completionHandler:)`. The handler is called on an arbitrary thread.
    public func uploadTask(with request: URLRequest,
                           from bodyData: Data,
                           completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        makeTask({ [self] in try await upload(for: request, from: bodyData) }, completionHandler: completionHandler)
    }

    /// Like `URLSession.uploadTask(with:fromFile:completionHandler:)`. The handler is called on an arbitrary thread.
    public func uploadTask(with request: URLRequest,
                           fromFile fileURL: URL,
                           completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        makeTask({ [self] in try await upload(for: request, fromFile: fileURL) }, completionHandler: completionHandler)
    }

    /// Like `URLSession.downloadTask(with:completionHandler:)`, the downloaded file is deleted once the handler
    /// returns, so the handler must move or read it. The handler is called on an arbitrary thread.
    public func downloadTask(with request: URLRequest,
                             completionHandler: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        makeTask({ [self] in try await download(for: request) },
                 afterCompletion: { try? FileManager.default.removeItem(at: $0) },
                 completionHandler: completionHandler)
    }

    public func downloadTask(with url: URL,
                             completionHandler: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void) -> ProtectedURLSessionTask {
        downloadTask(with: URLRequest(url: url), completionHandler: completionHandler)
    }

    /// Wraps `operation` in a task that reports its outcome to `completionHandler`, then runs `afterCompletion`
    /// with the output once the handler has returned.
    private func makeTask<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> (Output, URLResponse),
        afterCompletion: @escaping @Sendable (Output) -> Void = { _ in },
        completionHandler: @escaping @Sendable (Output?, URLResponse?, (any Error)?) -> Void
    ) -> ProtectedURLSessionTask {
        ProtectedURLSessionTask {
            do {
                let (output, response) = try await operation()
                completionHandler(output, response, nil)
                afterCompletion(output)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
    }
}
