//
//  ProtectedURLSession+Combine.swift
//  DataDomeURLSession
//

import Foundation
import Combine

extension ProtectedURLSession {
    /// Like `URLSession.dataTaskPublisher(for:)`: publishes the response to the protected request, then finishes.
    public func dataTaskPublisher(for request: URLRequest) -> DataTaskPublisher {
        DataTaskPublisher(request: request, session: self)
    }

    public func dataTaskPublisher(for url: URL) -> DataTaskPublisher {
        dataTaskPublisher(for: URLRequest(url: url))
    }

    /// A publisher that sends a protected request when it receives demand. Cancelling the subscription cancels
    /// the request.
    public struct DataTaskPublisher: Publisher, Sendable {
        public typealias Output = (data: Data, response: URLResponse)
        public typealias Failure = any Error

        public let request: URLRequest
        public let session: ProtectedURLSession

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            subscriber.receive(subscription: DataTaskSubscription(request: request, session: session, subscriber: AnySubscriber(subscriber)))
        }
    }
}

/// Type-erases its subscriber so the task it starts captures no generic metatype.
private final class DataTaskSubscription: Subscription, @unchecked Sendable {
    typealias S = AnySubscriber<ProtectedURLSession.DataTaskPublisher.Output, any Error>

    private let request: URLRequest
    private let session: ProtectedURLSession

    // State is guarded by `lock`. `subscriber` is cleared once the subscription completes or is cancelled.
    private let lock = NSLock()
    private var subscriber: S?
    private var task: Task<Void, Never>?

    init(request: URLRequest, session: ProtectedURLSession, subscriber: S) {
        self.request = request
        self.session = session
        self.subscriber = subscriber
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else {
            return
        }

        lock.withLock {
            guard subscriber != nil, task == nil else {
                return
            }
            task = Task { [request, session] in
                do {
                    finish(.success(try await session.data(for: request)))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    func cancel() {
        let task = lock.withLock {
            subscriber = nil
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        let subscriber = lock.withLock {
            defer { self.subscriber = nil }
            return self.subscriber
        }
        guard let subscriber else {
            return
        }

        switch result {
        case .success(let (data, response)):
            _ = subscriber.receive((data: data, response: response))
            subscriber.receive(completion: .finished)
        case .failure(let error):
            subscriber.receive(completion: .failure(error))
        }
    }
}
