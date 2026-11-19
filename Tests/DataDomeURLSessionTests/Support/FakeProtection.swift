import Foundation
import CoreDataDome
@testable import DataDomeURLSession

/// Stands in for `DataDome`, without presenting any challenge.
///
/// Like CoreDataDome, it treats a response as a challenge only when it carries `x-dd-b`, and reads the body only
/// then. Each challenge consumes the next of `outcomes`.
actor FakeProtection: DataDomeProtection {
    static let attemptHeader = "X-Test-Attempt"

    private var outcomes: [ResponseValidationStatus]
    private let cancelsDuringChallenge: Bool
    private let duringChallenge: (@Sendable () async -> Void)?
    private let readsBodyTwiceAtOnce: Bool
    private var preparedCount = 0
    private(set) var challengeBodies: [Data?] = []
    /// The URL each response was validated against, in order.
    private(set) var validatedURLs: [URL] = []

    /// - Parameters:
    ///   - cancelsDuringChallenge: Cancels the request's task while validating a challenge, as if the caller
    ///     cancelled while the challenge was displayed.
    ///   - duringChallenge: Runs in the request's task while a challenge is validated, as if it were displayed
    ///     for as long as it runs.
    ///   - readsBodyTwiceAtOnce: Reads a challenge's body with two overlapping accesses instead of one.
    init(outcomes: [ResponseValidationStatus] = [],
         cancelsDuringChallenge: Bool = false,
         duringChallenge: (@Sendable () async -> Void)? = nil,
         readsBodyTwiceAtOnce: Bool = false) {
        self.outcomes = outcomes
        self.cancelsDuringChallenge = cancelsDuringChallenge
        self.duringChallenge = duringChallenge
        self.readsBodyTwiceAtOnce = readsBodyTwiceAtOnce
    }

    func prepareRequestHeaders(_ headers: [String: String], forURL url: URL) async -> [String: String] {
        preparedCount += 1
        // Appended to any value already there, as CoreDataDome may do with the `Cookie` header: a retry that still
        // carried the previous attempt's prepared headers would show both attempts.
        var headers = headers
        headers[Self.attemptHeader] = [headers[Self.attemptHeader], "\(preparedCount)"].compactMap { $0 }.joined(separator: ",")
        return headers
    }

    func validate(_ response: DataDomeResponse, requestURL: URL) async -> ResponseValidationStatus {
        validatedURLs.append(requestURL)
        guard response.headers["x-dd-b"] != nil else {
            return .allowed
        }
        if readsBodyTwiceAtOnce {
            async let first = try? response.body
            async let second = try? response.body
            challengeBodies += await [first, second]
        } else {
            challengeBodies.append(try? await response.body)
        }
        if cancelsDuringChallenge {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        await duringChallenge?()
        return outcomes.isEmpty ? .error : outcomes.removeFirst()
    }
}
