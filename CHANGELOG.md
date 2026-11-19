## 1.0.0 (2026-11-17)

To migrate from `DataDomeSDK`, follow [this migration guide](https://docs.datadome.co/docs/sdk-ios-urlsession-migration-from-datadomesdk).

- Initial release
- `ProtectedURLSession` supports `data`, `upload`, `download` and `bytes`, with async/await, completion handlers and Combine
- Requests are retried automatically once the user resolves a challenge, whatever the response status code
- A challenge returned by a redirect destination is retried at that destination, as URLSession sent the redirected request

### Breaking changes

| Removed / changed (old)                                              | Replacement (new)                                                    |
| -------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `import DataDomeSDK`                                                 | `import CoreDataDome` and `import DataDomeURLSession`                |
| `DataDomeSDK.configure(withConfiguration:)`                          | `DataDome(configuration:)`                                           |
| Automatic protection of `URLSession` calls (method swizzling)        | send requests through `ProtectedURLSession`                          |
| `session.protectedDataTask(withRequest:captchaDelegate:)` (async)    | `session.protected(by: dataDome).data(for:)`                         |
| `session.protectedDataTask(withRequest:captchaDelegate:completionHandler:)` | `session.protected(by: dataDome).dataTask(with:completionHandler:)` |
| `session.protectedDataTaskPublisher(forRequest:captchaDelegate:)`    | `session.protected(by: dataDome).dataTaskPublisher(for:)`            |
| `CaptchaDelegate`                                                    | _(removed)_                                                          |
| `DataDomeKey` (Info.plist)                                           | `DataDome` › `ClientSideKey`                                         |
| `DataDomeProxyEnabled` (Info.plist)                                  | _(removed)_                                                          |

***

For previous versions, refer to [this changelog](https://docs.datadome.co/update/docs/sdk-ios-changelog).
