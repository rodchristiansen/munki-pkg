//
//  errors.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/4/25.
//

import Foundation

/// General error class for munkipkg errors
public class MunkiPkgError: Error, CustomStringConvertible, LocalizedError, @unchecked Sendable {
    let exitCode: Int
    private let message: String

    // Creates a new error with the given message.
    public init(_ message: String, exitCode: Int = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    public var description: String {
        return message
    }
    
    /// Ensures we can return a useful localizedError
    public var errorDescription: String? {
        return message
    }
}

// Convenience extensions for throwing different error types
extension MunkiPkgError {
    static func projectExists(_ description: String) -> MunkiPkgError {
        return MunkiPkgError(description, exitCode: 2)
    }
    
    static func invalidProject(_ description: String) -> MunkiPkgError {
        return MunkiPkgError(description, exitCode: 3)
    }
    
    static func importFailed(_ description: String) -> MunkiPkgError {
        return MunkiPkgError(description, exitCode: 4)
    }
    
    static func buildFailed(_ description: String) -> MunkiPkgError {
        return MunkiPkgError(description, exitCode: 5)
    }
}

