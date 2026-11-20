//
//  DataDomeError.swift
//  DataDomeURLSession
//

/// Errors surfaced by the DataDome URLSession integration.
public enum DataDomeError: Error {
    /// DataDome presented a block page; the request cannot proceed.
    case blocked

    /// The user resolved a challenge, but the request sends its body through `httpBodyStream`, which the first
    /// attempt already read, so it cannot be sent again.
    ///
    /// The DataDome cookie is set: resend the request with a new body stream. To have challenges retried
    /// automatically, send the body with `httpBody`, `upload(for:from:)` or `upload(for:fromFile:)` instead.
    case cannotRetryStreamBody
}
