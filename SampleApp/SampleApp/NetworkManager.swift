import Foundation
import CoreDataDome
import DataDomeURLSession

final class NetworkManager: Sendable {
    static let shared = NetworkManager()

    private let dataDome: DataDome
    private let session: ProtectedURLSession

    private let headers = [
        "Accept": "application/json",
        "User-Agent": "BLOCKUA", // For testing purpose only - This will force a Captcha challenge if no DataDome cookie is present
        "Cache-Control": "max-age=0, no-cache, must-revalidate, proxy-revalidate" // For testing purpose only - This will bypass all cache
    ]

    private init() {
        dataDome = DataDome(configuration: DataDomeConfiguration(clientKey: "YOUR_DATADOME_CLIENT_SIDE_KEY"))
        session = URLSession.shared.protected(by: dataDome)
    }

    func protectedData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await session.data(for: makeRequest(url))
        return (data, response as? HTTPURLResponse)
    }

    /// Downloads `url` and returns the size of the downloaded file, which is then deleted.
    func protectedDownload(from url: URL) async throws -> (Int, HTTPURLResponse?) {
        let (location, response) = try await session.download(for: makeRequest(url))
        defer { try? FileManager.default.removeItem(at: location) }

        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return (size, response as? HTTPURLResponse)
    }

    /// POSTs `body` to `url`.
    func protectedUpload(_ body: Data, to url: URL) async throws -> (Data, HTTPURLResponse?) {
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: body)
        return (data, response as? HTTPURLResponse)
    }

    /// Clears the DataDome cookie from both the shared HTTP cookie storage and the WKWebView store.
    func clearCookies() async {
        await dataDome.unsafeClearCachedData()
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        return request
    }
}
