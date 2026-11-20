import SwiftUI

struct ContentView: View {
    @State private var endpoint = "https://example.com/"
    @State private var status = "Idle"
    @State private var isLoading = false

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("URL", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }

            Section {
                Button("Send protected request") {
                    run("Request") { url in
                        let (data, response) = try await NetworkManager.shared.protectedData(from: url)
                        return "HTTP \(response?.statusCode ?? 0) — \(data.count) bytes"
                    }
                }

                Button("Download") {
                    run("Download") { url in
                        let (size, response) = try await NetworkManager.shared.protectedDownload(from: url)
                        return "HTTP \(response?.statusCode ?? 0) — downloaded \(size) bytes"
                    }
                }

                if #available(iOS 16.0, *) {
                    ImageUploadButton { result in
                        switch result {
                        case .success(let image):
                            run("Upload of \(image.name)") { url in
                                let (data, response) = try await NetworkManager.shared.protectedUpload(image.data, to: url)
                                return "HTTP \(response?.statusCode ?? 0) — uploaded \(image.name) (\(image.data.count) bytes), \(data.count) bytes in response"
                            }
                        case .failure(let error):
                            status = "Error picking image: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .disabled(isLoading)

            Section {
                Button("Clear DataDome cookie", role: .destructive) {
                    Task {
                        await NetworkManager.shared.clearCookies()
                        status = "Cookie cleared"
                    }
                }
            }

            Section("Result") {
                Text(status)
            }
        }
    }

    /// Runs `operation` against the endpoint and shows its outcome.
    private func run(_ name: String, _ operation: @escaping (URL) async throws -> String) {
        guard let url = URL(string: endpoint) else {
            status = "Invalid URL"
            return
        }

        isLoading = true
        status = "\(name) in progress…"

        Task {
            defer { isLoading = false }
            do {
                status = try await operation(url)
            } catch {
                status = "\(name) failed: \(error)"
            }
        }
    }
}

#Preview {
    ContentView()
}
