//
//  RedirectRecorder.swift
//  DataDomeURLSession
//

import Foundation

/// The delegate of every task the executor sends. It records the request URLSession sends after each redirect,
/// so that a challenge returned by a redirect destination is retried there, and forwards every callback to the
/// caller's delegate, which keeps working as if it were the task's delegate.
///
/// A task delegate that handles redirects takes them over from the session delegate. When the caller's delegate
/// doesn't handle them, the session delegate still decides.
final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let redirectSelector =
        #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))

    private let delegate: (any URLSessionTaskDelegate)?
    private let sessionDelegate: (any URLSessionTaskDelegate)?

    // State is guarded by `lock`.
    private let lock = NSLock()
    private var redirected: URLRequest?

    init(forwardingTo delegate: (any URLSessionTaskDelegate)?, sessionDelegate: (any URLSessionDelegate)?) {
        self.delegate = delegate
        self.sessionDelegate = sessionDelegate as? any URLSessionTaskDelegate
    }

    /// The request URLSession sent after the last redirect it followed, or `nil` if it followed none.
    var lastRedirect: URLRequest? {
        lock.withLock { redirected }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let decider = [delegate, sessionDelegate].lazy.compactMap({ $0 }).first(where: {
            $0.responds(to: Self.redirectSelector)
        }) else {
            record(request)
            completionHandler(request)
            return
        }
        decider.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { decided in
            // A refused redirect is not followed: the response then comes from the request before it.
            if let decided {
                self.record(decided)
            }
            completionHandler(decided)
        }
    }

    private func record(_ request: URLRequest) {
        lock.withLock { redirected = request }
    }

    // MARK: - Forwarding

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (delegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        delegate
    }
}
