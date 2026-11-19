import Foundation
import Testing
@testable import DataDomeURLSession

@Suite struct ProtectedURLSessionTests {
    private func makeSession(_ protection: FakeProtection) -> ProtectedURLSession {
        ProtectedURLSession(protection: protection, session: StubServer.makeSession())
    }

    private func attempts(_ server: StubServer) -> [String?] {
        server.requests.map { $0.value(forHTTPHeaderField: FakeProtection.attemptHeader) }
    }

    // MARK: - Data

    @Test func preparesHeadersAndPassesNonChallengeThrough() async throws {
        let server = StubServer([.ok("hello")])
        let protection = FakeProtection()
        var request = URLRequest(url: server.baseURL)
        request.setValue("kept", forHTTPHeaderField: "X-Caller")

        let (data, response) = try await makeSession(protection).data(for: request)

        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(attempts(server) == ["1"])
        #expect(server.requests.first?.value(forHTTPHeaderField: "X-Caller") == "kept")
        #expect(await protection.challengeBodies.isEmpty)
    }

    @Test func retriesWithFreshHeadersAfterResolvedChallenge() async throws {
        let server = StubServer([.challenge, .ok("after retry")])
        let protection = FakeProtection(outcomes: [.needRetry])

        let (data, _) = try await makeSession(protection).data(from: server.baseURL)

        #expect(String(decoding: data, as: UTF8.self) == "after retry")
        #expect(attempts(server) == ["1", "2"])
        #expect(await protection.challengeBodies == [StubServer.Response.challenge.body])
    }

    @Test func keepsRetryingWhileChallengesAreResolved() async throws {
        let server = StubServer([.challenge, .challenge, .ok("done")])
        let protection = FakeProtection(outcomes: [.needRetry, .needRetry])

        let (data, _) = try await makeSession(protection).data(from: server.baseURL)

        #expect(String(decoding: data, as: UTF8.self) == "done")
        #expect(server.requests.count == 3)
    }

    @Test func throwsWhenBlocked() async throws {
        let server = StubServer([.challenge])
        let protection = FakeProtection(outcomes: [.blocked])

        await #expect(throws: DataDomeError.blocked) {
            try await makeSession(protection).data(from: server.baseURL)
        }
        #expect(server.requests.count == 1)
    }

    @Test func returnsChallengeResponseWhenNotResolved() async throws {
        let server = StubServer([.challenge])
        let protection = FakeProtection(outcomes: [.error])

        let (data, response) = try await makeSession(protection).data(from: server.baseURL)

        #expect(data == StubServer.Response.challenge.body)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(server.requests.count == 1)
    }

    @Test func reportsCancellationDuringChallengeInsteadOfChallengeResponse() async throws {
        let server = StubServer([.challenge])
        let protection = FakeProtection(outcomes: [.error], cancelsDuringChallenge: true)
        let session = makeSession(protection)

        // Sent from a child task so the fake cancels that task, not the test's own: Swift Testing reports a
        // test whose task is cancelled as skipped.
        let request = Task { try await session.data(from: server.baseURL) }

        await #expect(throws: URLError(.cancelled)) {
            try await request.value
        }
    }

    @Test func throwsInsteadOfResendingConsumedBodyStream() async throws {
        let server = StubServer([.challenge, .ok("never sent")])
        let protection = FakeProtection(outcomes: [.needRetry])
        var request = URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("streamed".utf8))

        await #expect(throws: DataDomeError.cannotRetryStreamBody) {
            try await makeSession(protection).data(for: request)
        }
        #expect(server.requests.count == 1)
    }

    // MARK: - Redirects

    private func post(_ url: URL, body: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return request
    }

    private func bodies(_ server: StubServer) -> [String?] {
        server.requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
    }

    @Test func retriesChallengeAtRedirectDestination() async throws {
        let destination = StubServer([.challenge, .ok("after redirect")])
        let origin = StubServer([.redirect(to: destination.baseURL)])
        let protection = FakeProtection(outcomes: [.needRetry])

        let (data, _) = try await makeSession(protection).data(from: origin.baseURL)

        #expect(String(decoding: data, as: UTF8.self) == "after redirect")
        #expect(await protection.validatedURLs == [destination.baseURL, destination.baseURL])
        #expect(origin.requests.count == 1)
        // Prepared again for the retry, not on top of the headers prepared for the redirected attempt.
        #expect(attempts(destination) == ["1", "2"])
    }

    @Test func retriesPostRedirectedBy303AsGet() async throws {
        let destination = StubServer([.challenge, .ok("order page")])
        let origin = StubServer([.redirect(to: destination.baseURL, statusCode: 303)])

        let (data, _) = try await makeSession(FakeProtection(outcomes: [.needRetry]))
            .data(for: post(origin.baseURL, body: "order=1"))

        #expect(String(decoding: data, as: UTF8.self) == "order page")
        #expect(origin.requests.count == 1)
        #expect(destination.requests.map(\.httpMethod) == ["GET", "GET"])
        #expect(bodies(destination) == [nil, nil])
    }

    @Test func retriesPostRedirectedBy307WithItsBody() async throws {
        let destination = StubServer([.challenge, .ok("ordered")])
        let origin = StubServer([.redirect(to: destination.baseURL, statusCode: 307)])

        let (data, _) = try await makeSession(FakeProtection(outcomes: [.needRetry]))
            .data(for: post(origin.baseURL, body: "order=1"))

        #expect(String(decoding: data, as: UTF8.self) == "ordered")
        #expect(origin.requests.count == 1)
        #expect(destination.requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(bodies(destination) == ["order=1", "order=1"])
    }

    @Test(arguments: [(307, "POST", "payload"), (303, "GET", nil)] as [(Int, String, String?)])
    func retriesRedirectedUploadAsURLSessionSentIt(statusCode: Int, method: String, body: String?) async throws {
        let destination = StubServer([.challenge, .ok("uploaded")])
        let origin = StubServer([.redirect(to: destination.baseURL, statusCode: statusCode)])
        var request = URLRequest(url: origin.baseURL)
        request.httpMethod = "POST"

        let (data, _) = try await makeSession(FakeProtection(outcomes: [.needRetry]))
            .upload(for: request, from: Data("payload".utf8))

        #expect(String(decoding: data, as: UTF8.self) == "uploaded")
        #expect(origin.requests.count == 1)
        #expect(destination.requests.map(\.httpMethod) == [method, method])
        #expect(bodies(destination) == [body, body])
    }

    @Test(arguments: [(307, "POST"), (301, "PUT")] as [(Int, String)])
    func retriesRedirectedUploadWithItsBodyWhenNewRequestHasNone(statusCode: Int, method: String) async throws {
        let destination = StubServer([.challenge, .ok("uploaded")])
        let origin = StubServer([.redirect(to: destination.baseURL, statusCode: statusCode)])
        var request = URLRequest(url: origin.baseURL)
        request.httpMethod = method

        // An upload's body lives in its task, so a redirect that keeps the method keeps it, even if the new
        // request doesn't carry it.
        let (data, _) = try await makeSession(FakeProtection(outcomes: [.needRetry]))
            .upload(for: request, from: Data("payload".utf8), delegate: RedirectDelegate(.dropBody))

        #expect(String(decoding: data, as: UTF8.self) == "uploaded")
        #expect(destination.requests.last?.httpMethod == method)
        #expect(bodies(destination).last == "payload")
    }

    @Test func retriesBodyStreamRequestWhoseRedirectDroppedTheBody() async throws {
        let destination = StubServer([.challenge, .ok("order page")])
        let origin = StubServer([.redirect(to: destination.baseURL, statusCode: 303)])
        var request = URLRequest(url: origin.baseURL)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("streamed".utf8))

        let (data, _) = try await makeSession(FakeProtection(outcomes: [.needRetry])).data(for: request)

        #expect(String(decoding: data, as: UTF8.self) == "order page")
    }

    @Test func retryKeepsRedirectChangedByCallerDelegate() async throws {
        let destination = StubServer([.challenge, .ok("after redirect")])
        let origin = StubServer([.redirect(to: destination.baseURL)])
        let delegate = RedirectDelegate(.addHeader("X-Redirected", "yes"))

        _ = try await makeSession(FakeProtection(outcomes: [.needRetry])).data(from: origin.baseURL, delegate: delegate)

        #expect(delegate.redirects == 1)
        #expect(destination.requests.map { $0.value(forHTTPHeaderField: "X-Redirected") } == ["yes", "yes"])
    }

    @Test func callerDelegateCanRefuseRedirect() async throws {
        let destination = StubServer([.ok("never")])
        let origin = StubServer([.redirect(to: destination.baseURL)])

        let (_, response) = try await makeSession(FakeProtection())
            .data(from: origin.baseURL, delegate: RedirectDelegate(.refuse))

        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(destination.requests.isEmpty)
    }

    @Test func sessionDelegateStillDecidesRedirects() async throws {
        let destination = StubServer([.ok("never")])
        let origin = StubServer([.redirect(to: destination.baseURL)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: RedirectDelegate(.refuse), delegateQueue: nil)

        let (_, response) = try await ProtectedURLSession(protection: FakeProtection(), session: session)
            .data(from: origin.baseURL)

        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(destination.requests.isEmpty)
    }

    @available(iOS 16.0, *) // for `timeLimit`
    @Test(.timeLimit(.minutes(1)))
    func callerDelegateReceivesOtherCallbacks() async throws {
        let server = StubServer([.ok("hello")])
        let delegate = RedirectDelegate(.follow)

        _ = try await makeSession(FakeProtection()).data(from: server.baseURL, delegate: delegate)

        await delegate.metrics.first { _ in true }
    }

    // MARK: - Upload

    @Test func uploadRetriesEvenWhenRequestCarriesIgnoredBodyStream() async throws {
        let server = StubServer([.challenge, .ok("uploaded")])
        let protection = FakeProtection(outcomes: [.needRetry])
        var request = URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("ignored".utf8))

        let (data, _) = try await makeSession(protection).upload(for: request, from: Data("payload".utf8))

        #expect(String(decoding: data, as: UTF8.self) == "uploaded")
        #expect(server.requests.count == 2)
    }

    @Test func uploadRetriesAfterResolvedChallenge() async throws {
        let server = StubServer([.challenge, .ok("uploaded")])
        let protection = FakeProtection(outcomes: [.needRetry])
        var request = URLRequest(url: server.baseURL)
        request.httpMethod = "POST"

        let (data, _) = try await makeSession(protection).upload(for: request, from: Data("payload".utf8))

        #expect(String(decoding: data, as: UTF8.self) == "uploaded")
        #expect(attempts(server) == ["1", "2"])
    }

    // MARK: - Download

    @Test func downloadRetriesAfterResolvedChallenge() async throws {
        let server = StubServer([.challenge, .ok("file")])
        let protection = FakeProtection(outcomes: [.needRetry])

        let (location, _) = try await makeSession(protection).download(from: server.baseURL)
        defer { try? FileManager.default.removeItem(at: location) }

        #expect(try String(contentsOf: location, encoding: .utf8) == "file")
        #expect(await protection.challengeBodies == [StubServer.Response.challenge.body])
    }

    // MARK: - Bytes

    @Test func bytesStreamsNonChallengeThrough() async throws {
        let server = StubServer([.ok("streamed")])
        let protection = FakeProtection()

        let (bytes, _) = try await makeSession(protection).bytes(from: server.baseURL)

        #expect(try await collect(bytes) == Data("streamed".utf8))
    }

    @Test func bytesReplaysChallengeBodyReadDuringValidation() async throws {
        let server = StubServer([.challenge])
        let protection = FakeProtection(outcomes: [.error])

        let (bytes, _) = try await makeSession(protection).bytes(from: server.baseURL)

        #expect(try await collect(bytes) == StubServer.Response.challenge.body)
        #expect(await protection.challengeBodies == [StubServer.Response.challenge.body])
    }

    @Test func readsBodyOnceWhenAccessedTwiceAtOnce() async throws {
        let protection = FakeProtection(outcomes: [.error], readsBodyTwiceAtOnce: true)
        let executor = ProtectedRequestExecutor(protection: protection)
        let url = URL(string: "https://reads-once.stub.test/")!
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil,
                                       headerFields: StubServer.Response.challenge.headers)!
        let reads = EventLog()

        _ = try await executor.execute(URLRequest(url: url),
                                       send: { _ in ("output", response) },
                                       readBody: { _ in
                                           reads.record("read")
                                           // Long enough for the second access to arrive during the first read.
                                           try await Task.sleep(nanoseconds: 50_000_000)
                                           return Data("body".utf8)
                                       })

        #expect(reads.entries.count == 1)
        #expect(await protection.challengeBodies == [Data("body".utf8), Data("body".utf8)])
    }

    private func collect(_ bytes: ProtectedURLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    // MARK: - Completion handlers

    @Test func dataTaskDeliversResponseOnResume() async throws {
        let server = StubServer([.challenge, .ok("completed")])
        let session = makeSession(FakeProtection(outcomes: [.needRetry]))

        let data = await withCheckedContinuation { continuation in
            session.dataTask(with: server.baseURL) { data, _, _ in
                continuation.resume(returning: data)
            }.resume()
        }

        #expect(data.map { String(decoding: $0, as: UTF8.self) } == "completed")
    }

    @Test func uploadTaskFromFileResendsFileAfterResolvedChallenge() async throws {
        let server = StubServer([.challenge, .ok("uploaded")])
        let session = makeSession(FakeProtection(outcomes: [.needRetry]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: server.baseURL)
        request.httpMethod = "POST"

        let data = await withCheckedContinuation { continuation in
            session.uploadTask(with: request, fromFile: file) { data, _, _ in
                continuation.resume(returning: data)
            }.resume()
        }

        #expect(data.map { String(decoding: $0, as: UTF8.self) } == "uploaded")
        #expect(bodies(server) == ["file payload", "file payload"])
    }

    @Test func cancellingBeforeResumeReportsCancelled() async throws {
        let server = StubServer([.ok("never")])
        let session = makeSession(FakeProtection())

        let error = await withCheckedContinuation { continuation in
            session.dataTask(with: server.baseURL) { _, _, error in
                continuation.resume(returning: error)
            }.cancel()
        }

        #expect((error as? URLError)?.code == .cancelled)
        #expect(server.requests.isEmpty)
    }

    // MARK: - Combine

    @Test func publisherPublishesProtectedResponse() async throws {
        let server = StubServer([.challenge, .ok("published")])
        let session = makeSession(FakeProtection(outcomes: [.needRetry]))

        var outputs: [Data] = []
        for try await output in session.dataTaskPublisher(for: server.baseURL).values {
            outputs.append(output.data)
        }

        #expect(outputs == [Data("published".utf8)])
    }

    @Test func cancellingSubscriptionStopsRequestAndPublishesNothing() async throws {
        let server = StubServer([.challenge, .ok("never published")])
        let (challengeShown, showContinuation) = AsyncStream.makeStream(of: Void.self)
        let (challengeEnded, endContinuation) = AsyncStream.makeStream(of: Void.self)
        // The challenge stays displayed until the request is cancelled, then asks for a retry.
        let protection = FakeProtection(outcomes: [.needRetry], duringChallenge: {
            showContinuation.yield()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            endContinuation.yield()
        })
        let events = EventLog()

        let subscription = makeSession(protection).dataTaskPublisher(for: server.baseURL)
            .sink(receiveCompletion: { _ in events.record("completion") },
                  receiveValue: { _ in events.record("value") })
        await challengeShown.first { _ in true }
        subscription.cancel()
        await challengeEnded.first { _ in true }

        // Nothing signals the end of the request once it is cancelled; give a late delivery or retry time to show.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(events.entries.isEmpty)
        #expect(server.requests.count == 1)
    }
}
