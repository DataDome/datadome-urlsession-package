import Foundation

/// A caller's delegate that decides redirects, and reports when task metrics reach it.
final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Decision {
        case follow
        case addHeader(String, String)
        /// Follows with the new request stripped of its body, keeping its method.
        case dropBody
        case refuse
    }

    private let decision: Decision
    private let metricsContinuation: AsyncStream<Void>.Continuation

    // State is guarded by `lock`.
    private let lock = NSLock()
    private var redirectCount = 0

    /// Yields each time task metrics reach the delegate.
    let metrics: AsyncStream<Void>

    init(_ decision: Decision) {
        self.decision = decision
        (metrics, metricsContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var redirects: Int {
        lock.withLock { redirectCount }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { redirectCount += 1 }
        switch decision {
        case .follow:
            completionHandler(request)
        case .addHeader(let field, let value):
            var request = request
            request.setValue(value, forHTTPHeaderField: field)
            completionHandler(request)
        case .dropBody:
            var request = request
            request.httpBody = nil
            request.httpBodyStream = nil
            completionHandler(request)
        case .refuse:
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        metricsContinuation.yield()
    }
}
