# DataDomeURLSession

The DataDome iOS SDK for `URLSession`, built on top of **CoreDataDome**.

Visit the [official documentation](https://docs.datadome.co/docs/sdk-ios-urlsession).

> **Upgrading from `DataDomeSDK`?** The URLSession integration moved to this package and its API changed.
> See the [migration guide](https://docs.datadome.co/docs/sdk-ios-urlsession-migration-from-datadomesdk).

## Requirements

- iOS **15+**
- Xcode **26+**, required by the App Store since April 28, 2026
- Swift Package Manager
- A DataDome client-side key, available in your
  [DataDome dashboard](https://app.datadome.co/dashboard/management/integrations)

## Installation

In Xcode, choose **File › Add Package Dependencies…** and enter:

```
https://github.com/DataDome/mobile-sdk-ios-wrapper-urlsession.git
```

`CoreDataDome` is added automatically as a dependency.

## Setup

Add your key to your Info.plist:

```xml
<key>DataDome</key>
<dict>
    <key>ClientSideKey</key>
    <string>YOUR_DATADOME_CLIENT_SIDE_KEY</string>
</dict>
```

Create **one** `DataDome` instance and reuse it:

```swift
import CoreDataDome
import DataDomeURLSession

let configuration = try DataDomeConfiguration.configurationFromBundle()
// or: DataDomeConfiguration(clientKey: "YOUR_DATADOME_CLIENT_SIDE_KEY")
let dataDome = DataDome(configuration: configuration)
```

## Usage

Send your requests through a `ProtectedURLSession`. It mirrors the `URLSession` API:

```swift
let session = ProtectedURLSession(dataDome: dataDome)              // wraps URLSession.shared
// To wrap your own URLSession instead, either of:
// let session = ProtectedURLSession(dataDome: dataDome, session: mySession)
// let session = mySession.protected(by: dataDome)
```

Only requests sent through `ProtectedURLSession` are protected. Requests sent directly on the
underlying `URLSession` are not.

### async/await

```swift
let (data, response) = try await session.data(for: request)
let (uploadData, uploadResponse) = try await session.upload(for: request, from: body)
let (fileUploadData, fileUploadResponse) = try await session.upload(for: request, fromFile: fileURL)
let (location, downloadResponse) = try await session.download(for: request)
let (bytes, bytesResponse) = try await session.bytes(for: request)
```

Each method also accepts a URL and an optional `delegate:`, as in `URLSession`. The delegate receives the
callbacks of every request sent, retries included.

### Completion handlers

```swift
let task = session.dataTask(with: request) { data, response, error in
    // Called on an arbitrary thread
}
task.resume()
```

`uploadTask(with:from:completionHandler:)`, `uploadTask(with:fromFile:completionHandler:)` and `downloadTask(with:completionHandler:)` work the same way.
They return a `ProtectedURLSessionTask`, which you `resume()` or `cancel()`.

### Combine

```swift
session.dataTaskPublisher(for: request)
    .sink(receiveCompletion: { _ in }, receiveValue: { data, response in })
```

## How challenges are handled

Every response is checked by DataDome, whatever its status code.

| DataDome outcome | Result |
|------------------|--------|
| No challenge | The response is returned unchanged. |
| Challenge resolved by the user | The request is sent again automatically with the new cookie, and the retry's response is returned. |
| Challenge resolved, after a redirect | The retry goes to the redirect destination, with the request URLSession sent there (for example a `GET` after a `303`), so the original request is not sent twice. |
| Challenge dismissed by the user | The original response is returned. |
| Block page | Throws `DataDomeError.blocked`. |
| Challenge resolved, but the body is an `httpBodyStream` | Throws `DataDomeError.cannotRetryStreamBody`: the stream was already read. Resend the request, or use `httpBody` or an `upload` method so it can be retried for you. |
| Request cancelled | Throws `URLError(.cancelled)`. |

The challenge and block pages are displayed by the SDK; there is no presentation code to write.

## Clearing the DataDome cookie

```swift
await dataDome.unsafeClearCachedData()
```
