//
//  URLSession+DataDome.swift
//  DataDomeURLSession
//

import Foundation
import CoreDataDome

extension URLSession {
    /// Returns a front over this session that protects every request sent through it with DataDome.
    ///
    /// ```swift
    /// let (data, response) = try await URLSession.shared.protected(by: dataDome).data(for: request)
    /// ```
    ///
    /// Each call returns a lightweight wrapper over this same session, so calling it per request is fine: the
    /// connection pool, cookies and `DataDome` instance are shared.
    public func protected(by dataDome: DataDome) -> ProtectedURLSession {
        ProtectedURLSession(dataDome: dataDome, session: self)
    }
}
