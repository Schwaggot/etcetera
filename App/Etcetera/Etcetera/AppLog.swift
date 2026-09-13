//
//  AppLog.swift
//  Etcetera
//

import EtceteraCore
import Foundation
import os

/// Logging with keys redacted unless the window's session opted into
/// verbose logging. Values and secrets are never logged. See SPEC 6.9.
nonisolated enum AppLog {
    private static let logger = Logger(subsystem: "etcetera", category: "app")

    static func event(_ message: String, key: Data? = nil, verbose: Bool) {
        guard let key else {
            logger.info("\(message, privacy: .public)")
            return
        }
        let name = displayString(for: key)
        if verbose {
            logger.info("\(message, privacy: .public) \(name, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public) \(name, privacy: .private)")
        }
    }
}
