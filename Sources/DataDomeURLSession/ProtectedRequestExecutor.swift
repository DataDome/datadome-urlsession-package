//
//  ProtectedRequestExecutor.swift
//  DataDomeURLSession
//

import Foundation
import CoreDataDome

/// The part of CoreDataDome the executor relies on. `DataDome` is the only production conformer; the
/// indirection exists so tests can drive every `ResponseValidationStatus` without presenting a challenge.
protocol DataDomeProtection: Sendable {
    func prepareRequestHeaders(_ headers: [String: String], forURL url: URL) async -> [String: String]
    func validate(_ response: DataDomeResponse, requestURL: URL) async -> ResponseValidationStatus
}

extension DataDome: DataDomeProtection {
    func validate(_ response: DataDomeResponse, requestURL: URL) async -> ResponseValidationStatus {
        await validateResponse(response, requestURL: requestURL)
    }
}

/// Runs one logical request through DataDome: prepare headers → send → validate → retry.
///
/// Every flavor of `ProtectedURLSession` (data, upload, download, bytes) goes through `execute`, which is
/// generic over what an attempt produces. Each HTTP response is handed to CoreDataDome with a lazy body
/// provider: CoreDataDome runs its own header check and only reads the body when the response is a challenge,
/// so there is no detection logic here and non-challenge responses are returned untouched.
///
/// On `.needRetry` the request is re-sent with freshly prepared headers (carrying the new cookie). The retry is
/// deliberately unbounded: it ends only when the user resolves the challenge (`.allowed`), is blocked
/// (`.blocked`) or dismisses it (`.error`). When the challenge came from a redirect destination, the retry is the
/// request URLSession sent there, recorded by `RedirectRecorder`, rather than the one that was redirected: the
/// redirect may have changed its method and body, and re-sending a non-idempotent request to the origin would
/// repeat it. A request whose body is an `httpBodyStream` is never re-sent: the stream is consumed by the first
/// attempt, so a resolved challenge throws `DataDomeError.cannotRetryStreamBody`.
struct ProtectedRequestExecutor: Sendable {
    /// One attempt, as handed to `send`.
    struct Attempt {
        /// The request to send, with the prepared headers.
        let request: URLRequest
        /// Must be the task's delegate: it records redirects and forwards to the caller's delegate.
        let delegate: any URLSessionTaskDelegate
        /// `false` once a redirect dropped the body (303, or 301 and 302 after a POST): an upload is then sent
        /// without its body, as URLSession did when following the redirect.
        let sendsBody: Bool
    }

    let protection: any DataDomeProtection
    /// The wrapped session's delegate, which decides redirects the caller's delegate doesn't handle.
    let sessionDelegate: (any URLSessionDelegate)?

    init(protection: any DataDomeProtection, sessionDelegate: (any URLSessionDelegate)? = nil) {
        self.protection = protection
        self.sessionDelegate = sessionDelegate
    }

    /// - Parameters:
    ///   - request: The request as built by the caller.
    ///   - delegate: The caller's task delegate, which receives every callback of every attempt.
    ///   - send: Performs one attempt.
    ///   - readBody: Reads an attempt's body for CoreDataDome. Called at most once per attempt, and only when
    ///     CoreDataDome needs the body.
    ///   - replay: Rebuilds an attempt's output from its buffered body, for outputs whose body can only be read
    ///     once (streams). Called only when the body was read and the attempt is returned to the caller.
    ///   - discard: Releases an attempt that is not returned to the caller (retried, blocked or failed).
    func execute<Output: Sendable>(
        _ request: URLRequest,
        delegate: (any URLSessionTaskDelegate)? = nil,
        send: (Attempt) async throws -> (Output, URLResponse),
        readBody: @escaping @Sendable (Output) async throws -> Data,
        replay: (Output, Data) -> Output = { output, _ in output },
        discard: (Output) -> Void = { _ in }
    ) async throws -> (Output, URLResponse) {
        func makeRecorder() -> RedirectRecorder {
            RedirectRecorder(forwardingTo: delegate, sessionDelegate: sessionDelegate)
        }

        // Without a URL CoreDataDome can neither scope headers nor present a response page; pass through.
        guard let url = request.url else {
            return try await send(Attempt(request: request, delegate: makeRecorder(), sendsBody: true))
        }

        // What the next attempt sends, before its headers are prepared: the caller's request, or the request
        // URLSession sent to the redirect destination a challenge came from.
        var next = request
        var sendsBody = true

        do {
            while true {
                try Task.checkCancellation()

                // Prepared on every attempt: after a resolved challenge they carry the fresh cookie.
                let attemptURL = next.url ?? url
                let preparedHeaders = await protection.prepareRequestHeaders(next.allHTTPHeaderFields ?? [:],
                                                                             forURL: attemptURL)
                var preparedRequest = next
                preparedRequest.allHTTPHeaderFields = preparedHeaders

                let recorder = makeRecorder()
                let (output, response) = try await send(Attempt(request: preparedRequest, delegate: recorder,
                                                                sendsBody: sendsBody))
                guard let httpResponse = response as? HTTPURLResponse else {
                    return (output, response)
                }

                let collected = CollectedBody()
                let ddResponse = DataDomeResponse(statusCode: httpResponse.statusCode,
                                                  headers: httpResponse.stringHeaderFields,
                                                  bodyProvider: { try await collected.resolve { try await readBody(output) } })

                // URLSession follows redirects before returning: a challenge comes from the final URL, which
                // CoreDataDome loads the challenge against and stores its cookie for.
                let status = await protection.validate(ddResponse, requestURL: httpResponse.url ?? attemptURL)
                // Closed as soon as validation ends: the output may go to the caller, who then owns its body.
                let bodyRead = await collected.close()

                // Validation can wait on the user for as long as a challenge is displayed; a request cancelled
                // meanwhile must not come back with the challenge response.
                if Task.isCancelled {
                    discard(output)
                    throw CancellationError()
                }

                switch status {
                case .needRetry:
                    discard(output)
                    if let redirected = recorder.lastRedirect {
                        sendsBody = redirected.keptBody
                        next = redirected.retried(from: next, preparedHeaders: preparedHeaders, keepsBody: sendsBody)
                    }
                    // Every attempt copies the caller's body stream, which this attempt already read. It cannot be
                    // rewound, so the caller has to resend.
                    if next.httpBodyStream != nil {
                        throw DataDomeError.cannotRetryStreamBody
                    }
                    continue
                case .blocked:
                    discard(output)
                    throw DataDomeError.blocked
                case .allowed, .error:
                    break
                @unknown default:
                    break
                }

                // If CoreDataDome never touched the body, the output is returned as is; if it read it, a
                // consume-once output is rebuilt from the buffered copy; if the read failed, that error surfaces.
                switch bodyRead {
                case nil:
                    return (output, response)
                case .success(let data)?:
                    return (replay(output, data), response)
                case .failure(let error)?:
                    discard(output)
                    throw error
                }
            }
        } catch is CancellationError {
            // Match URLSession, which reports a cancelled request as `URLError(.cancelled)`.
            throw URLError(.cancelled)
        }
    }
}

/// Reads an attempt's body at most once and shares the outcome with every access. CoreDataDome may access
/// `DataDomeResponse.body` more than once, possibly at the same time, but a streamed body can only be read once.
/// Once closed, it no longer reads: the body then belongs to the caller.
private actor CollectedBody {
    /// Thrown to an access that comes after the attempt was handed over.
    struct BodyNoLongerAvailable: Error {}

    private var read: Task<Data, any Error>?
    private var isClosed = false

    /// Starts the read on the first access; every access waits on that same read. Cancelling an access cancels
    /// the read.
    func resolve(_ readBody: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let read: Task<Data, any Error>
        if let started = self.read {
            read = started
        } else {
            guard !isClosed else {
                throw BodyNoLongerAvailable()
            }
            read = Task { try await readBody() }
            self.read = read
        }
        return try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
    }

    /// Stops further reads and returns the outcome of the read, or `nil` if the body was never read.
    func close() async -> Result<Data, any Error>? {
        isClosed = true
        return await read?.result
    }
}

private extension URLRequest {
    /// Whether URLSession sent the body with this redirected request.
    ///
    /// URLSession drops the body exactly when a redirect switches the method to GET (303, and 301 or 302 after a
    /// POST), and the method is decided by the time the redirect is recorded. A kept body usually shows on the
    /// request, as a stream, but the method alone decides: an upload's body lives in its task, and the request
    /// may not carry it.
    var keptBody: Bool {
        httpBody != nil || httpBodyStream != nil || !["GET", "HEAD"].contains(httpMethod ?? "GET")
    }

    /// This redirected request, made ready to be sent again in place of `previous`, the request it was redirected
    /// from before its headers were prepared.
    ///
    /// The headers prepared for `previous` are reverted to the caller's, to be prepared again for the new URL. A
    /// kept body (307 and 308) is the caller's again: URLSession hands it over as an internal stream it already
    /// read.
    func retried(from previous: URLRequest, preparedHeaders: [String: String], keepsBody: Bool) -> URLRequest {
        var request = self
        for (field, value) in preparedHeaders where previous.value(forHTTPHeaderField: field) != value {
            request.setValue(previous.value(forHTTPHeaderField: field), forHTTPHeaderField: field)
        }
        request.httpBodyStream = nil
        request.httpBody = keepsBody ? previous.httpBody : nil
        if keepsBody, let stream = previous.httpBodyStream {
            request.httpBodyStream = stream
        }
        return request
    }
}

private extension HTTPURLResponse {
    var stringHeaderFields: [String: String] {
        allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
    }
}
