# Migrating from DataDomeSDK to DataDomeURLSession

The URLSession integration used to ship inside the legacy `DataDomeSDK` (`3.x`). It is now this package,
**DataDomeURLSession**, built on top of the new **CoreDataDome** SDK. This is a **breaking change**.

The main difference: `DataDomeSDK` could protect every `URLSession` call automatically by swizzling
`URLSession` methods. DataDomeURLSession does not. Only requests sent through a `ProtectedURLSession` are
protected.

## Requirements

* iOS **15+** (previously iOS 11)
* Xcode **26+**, required by the App Store since April 28, 2026
* Swift Package Manager (CocoaPods is no longer supported)

## At a glance

| Area | Before (`DataDomeSDK` 3.x) | After (`DataDomeURLSession`) |
|------|----------------------------|------------------------------|
| Dependency | `DataDomeSDK` | `DataDomeURLSession` (pulls in `CoreDataDome`) |
| Package manager | CocoaPods **or** SPM | **SPM only** |
| Minimum iOS | 11 | **15** |
| Configuration | `DataDomeSDK.configure(withConfiguration:)` | create & inject a `DataDome` instance |
| Protection | automatic (swizzling) or `protectedDataTask` | `ProtectedURLSession` |
| Challenge presentation | `CaptchaDelegate` (optional) | automatic |
| Info.plist | `DataDomeKey`, `DataDomeProxyEnabled` | `DataDome` › `ClientSideKey` |

## Step 1 — Update the dependency

Remove `DataDomeSDK`: delete `pod 'DataDomeSDK'` from your `Podfile` and run `pod install`, or remove the
`datadome-ios` package in Xcode.

Then add DataDomeURLSession with **File › Add Package Dependencies…**:

```
https://github.com/DataDome/mobile-sdk-ios-wrapper-urlsession.git
```

Raise your app target's **Minimum Deployments** to **iOS 15.0** or later.

## Step 2 — Update your Info.plist

**Before**

```xml
<key>DataDomeKey</key>
<string>YOUR_DATADOME_CLIENT_SIDE_KEY</string>
<key>DataDomeProxyEnabled</key>
<true/>
```

**After**

```xml
<key>DataDome</key>
<dict>
    <key>ClientSideKey</key>
    <string>YOUR_DATADOME_CLIENT_SIDE_KEY</string>
</dict>
```

`DataDomeProxyEnabled` no longer exists: there is no swizzling to turn on or off.

## Step 3 — Create a `DataDome` instance

Replace the global configuration with one `DataDome` instance, created once and reused:

**Before**

```swift
let configuration = try DataDomeSDK.Configuration.configurationFromBundle()
DataDomeSDK.configure(withConfiguration: configuration)
```

**After**

```swift
import CoreDataDome
import DataDomeURLSession

let configuration = try DataDomeConfiguration.configurationFromBundle()
let dataDome = DataDome(configuration: configuration)
```

## Step 4 — Send requests through `ProtectedURLSession`

If you relied on swizzling, your plain `URLSession` calls are **no longer protected**. Route them through a
`ProtectedURLSession`. It mirrors the `URLSession` API:

**Before**

```swift
// Protected implicitly by swizzling
let task = URLSession.shared.dataTask(with: request) { data, response, error in }
task.resume()

// Or protected explicitly
let (data, response) = try await URLSession.shared.protectedDataTask(withRequest: request,
                                                                     captchaDelegate: nil)
```

**After**

```swift
let session = URLSession.shared.protected(by: dataDome)   // or ProtectedURLSession(dataDome: dataDome)

let task = session.dataTask(with: request) { data, response, error in }
task.resume()

let (data, response) = try await session.data(for: request)
```

## API mapping

| Removed / changed (old) | Replacement (new) |
|-------------------------|-------------------|
| `import DataDomeSDK` | `import CoreDataDome` and `import DataDomeURLSession` |
| `DataDomeSDK.configure(withConfiguration:)` | `DataDome(configuration:)` |
| `DataDomeSDK.Configuration` | `DataDomeConfiguration` |
| `protectedDataTask(withURL:captchaDelegate:)` (async) | `data(from:)` |
| `protectedDataTask(withRequest:captchaDelegate:)` (async) | `data(for:)` |
| `protectedDataTask(withURL:captchaDelegate:completionHandler:)` | `dataTask(with:completionHandler:)` |
| `protectedDataTask(withRequest:captchaDelegate:completionHandler:)` | `dataTask(with:completionHandler:)` |
| `protectedDataTaskPublisher(forURL:captchaDelegate:)` | `dataTaskPublisher(for:)` |
| `protectedDataTaskPublisher(forRequest:captchaDelegate:)` | `dataTaskPublisher(for:)` |
| `CaptchaDelegate` | _(removed — see below)_ |
| `DataDomeKey` (Info.plist) | `DataDome` › `ClientSideKey` |
| `DataDomeProxyEnabled` (Info.plist) | _(removed)_ |

The new methods are called on a `ProtectedURLSession`, not on `URLSession`.

## Behavioral changes

- **Challenge and block pages are displayed automatically.** `CaptchaDelegate` no longer exists.
- **Completion-handler methods return a `ProtectedURLSessionTask`**, not a `URLSessionDataTask`: one
  protected request can span several underlying tasks when a challenge is retried. It offers `resume()`
  and `cancel()`.
- **The Combine publisher fails with `any Error`**, not only `URLError`, so that it can report
  `DataDomeError`.
- **A block page throws `DataDomeError.blocked`.**
- **Upload, download and streamed (`bytes`) requests are now supported.**
- **Clearing the DataDome cookie** is done on the instance: `await dataDome.unsafeClearCachedData()`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Build error: _"requires minimum platform version 15.0"_ | Raise your app target's Minimum Deployment to iOS 15+. |
| Throw on launch about a missing `DataDome` / `ClientSideKey` | Your Info.plist still uses `DataDomeKey`; migrate it (Step 2), or use `DataDomeConfiguration(clientKey:)`. |
| Requests are challenged but no challenge appears | The request was sent on a plain `URLSession`. Send it through a `ProtectedURLSession` (Step 4). |

## Resources

- [DataDomeURLSession documentation](https://docs.datadome.co/docs/sdk-ios-urlsession)
