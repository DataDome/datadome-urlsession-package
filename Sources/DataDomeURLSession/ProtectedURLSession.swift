//
//  ProtectedURLSession.swift
//  DataDomeURLSession
//

import Foundation
import CoreDataDome

/// A `URLSession` front that protects every request it sends with DataDome.
///
/// It mirrors the `URLSession` API: `data`, `upload`, `download` and `bytes`. Every request first gets the
/// DataDome-required headers from CoreDataDome. Every HTTP response, whatever its status code, is then handed
/// to CoreDataDome for validation. When the response is a challenge, CoreDataDome presents it. Once the user
/// resolves it, the request is sent again with the fresh cookie and the caller receives the response to that
/// retry. A block page throws ``DataDomeError/blocked``. When the challenge came from a redirect destination,
/// the retry goes to that destination, with the request URLSession sent there.
///
/// A `delegate` passed to a method receives every callback of every request sent for it, retries included.
///
/// ```swift
/// let session = ProtectedURLSession(dataDome: dataDome)
/// let (data, response) = try await session.data(for: request)
///
/// // or, from an existing session
/// let (data, response) = try await URLSession.shared.protected(by: dataDome).data(for: request)
/// ```
///
/// Only requests sent through this object are protected; requests sent directly through the wrapped
/// `URLSession` are not.
public final class ProtectedURLSession: Sendable {
    /// The session that performs the actual network requests.
    public let session: URLSession

    let executor: ProtectedRequestExecutor

    /// Creates a DataDome-protected front over `session`.
    /// - Parameters:
    ///   - dataDome: The `DataDome` instance that prepares requests and validates responses.
    ///   - session: The session that performs the requests. Its `URLSessionConfiguration.httpCookieStorage`
    ///     must be the storage given to `DataDomeConfiguration`, or the DataDome cookie is never sent.
    public convenience init(dataDome: DataDome, session: URLSession = .shared) {
        self.init(protection: dataDome, session: session)
    }

    init(protection: any DataDomeProtection, session: URLSession) {
        self.session = session
        self.executor = ProtectedRequestExecutor(protection: protection, sessionDelegate: session.delegate)
    }

    // MARK: - Data

    public func data(for request: URLRequest,
                     delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await executor.execute(request, delegate: delegate,
                                   send: { try await session.data(for: $0.request, delegate: $0.delegate) },
                                   readBody: { $0 })
    }

    public func data(from url: URL,
                     delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), delegate: delegate)
    }

    // MARK: - Upload

    public func upload(for request: URLRequest,
                       from bodyData: Data,
                       delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await executor.execute(request.withoutBody, delegate: delegate,
                                   send: { attempt in
                                       guard attempt.sendsBody else {
                                           return try await session.data(for: attempt.request, delegate: attempt.delegate)
                                       }
                                       return try await session.upload(for: attempt.request, from: bodyData,
                                                                       delegate: attempt.delegate)
                                   },
                                   readBody: { $0 })
    }

    public func upload(for request: URLRequest,
                       fromFile fileURL: URL,
                       delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await executor.execute(request.withoutBody, delegate: delegate,
                                   send: { attempt in
                                       guard attempt.sendsBody else {
                                           return try await session.data(for: attempt.request, delegate: attempt.delegate)
                                       }
                                       return try await session.upload(for: attempt.request, fromFile: fileURL,
                                                                       delegate: attempt.delegate)
                                   },
                                   readBody: { $0 })
    }

    // MARK: - Download

    /// Like `URLSession.download(for:delegate:)`, the caller owns the returned file and must move or delete it.
    /// Files downloaded by attempts that were retried or blocked are deleted.
    public func download(for request: URLRequest,
                         delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (URL, URLResponse) {
        try await executor.execute(request, delegate: delegate,
                                   send: { try await session.download(for: $0.request, delegate: $0.delegate) },
                                   readBody: { try Data(contentsOf: $0) },
                                   discard: { try? FileManager.default.removeItem(at: $0) })
    }

    public func download(from url: URL,
                         delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (URL, URLResponse) {
        try await download(for: URLRequest(url: url), delegate: delegate)
    }

    // MARK: - Bytes

    /// Like `URLSession.bytes(for:delegate:)`. A non-challenge response streams through untouched. A challenge
    /// response that is not retried (for example one the user dismissed) has its body buffered while validating
    /// and replayed. The streams of attempts that were retried, blocked or cancelled are cancelled.
    public func bytes(for request: URLRequest,
                      delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) {
        try await executor.execute(request, delegate: delegate,
                                   send: { attempt in
                                       let (bytes, response) = try await session.bytes(for: attempt.request,
                                                                                       delegate: attempt.delegate)
                                       return (AsyncBytes(stream: bytes), response)
                                   },
                                   readBody: { bytes in
                                       var body = Data()
                                       for try await byte in bytes {
                                           body.append(byte)
                                       }
                                       return body
                                   },
                                   replay: { _, body in AsyncBytes(buffered: body) },
                                   discard: { $0.cancel() })
    }

    public func bytes(from url: URL,
                      delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) {
        try await bytes(for: URLRequest(url: url), delegate: delegate)
    }
}

private extension URLRequest {
    /// Upload tasks ignore the request's own body. Dropping it keeps a stray `httpBodyStream` from stopping the
    /// executor from retrying an upload, whose body is re-sent from the data or file on every attempt.
    var withoutBody: URLRequest {
        var request = self
        request.httpBodyStream = nil
        request.httpBody = nil
        return request
    }
}

// MARK: - AsyncBytes

extension ProtectedURLSession {
    /// The bytes of a response, as an asynchronous sequence: the live `URLSession.AsyncBytes` stream, or the
    /// buffered body of a challenge response that CoreDataDome had to read.
    public struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8

        private let stream: URLSession.AsyncBytes?
        private let buffered: Data?

        init(stream: URLSession.AsyncBytes) {
            self.stream = stream
            self.buffered = nil
        }

        init(buffered: Data) {
            self.stream = nil
            self.buffered = buffered
        }

        /// Stops the live stream's data task, which otherwise keeps downloading a body nobody reads. A buffered
        /// body has nothing to stop.
        func cancel() {
            stream?.task.cancel()
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(stream: stream?.makeAsyncIterator(), buffered: buffered?.makeIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var stream: URLSession.AsyncBytes.AsyncIterator?
            var buffered: Data.Iterator?

            public mutating func next() async throws -> UInt8? {
                if stream != nil {
                    return try await stream!.next()
                }
                return buffered?.next()
            }
        }
    }
}
