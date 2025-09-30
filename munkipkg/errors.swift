//
//  errors.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/4/25.
//

import Foundation

/// General error class for munkipkg errors
public class MunkiPkgError: Error, CustomStringConvertible, LocalizedError {
    var exitCode: Int = 1
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

// Specific error types
class ProjectExistsError: MunkiPkgError {
    init(_ description: String = "Project already exists") {
        super.init(description, exitCode: 2)
    }
}

class InvalidProjectError: MunkiPkgError {
    init(_ description: String = "Invalid project") {
        super.init(description, exitCode: 3)
    }
}

class ImportFailedError: MunkiPkgError {
    init(_ description: String = "Import failed") {
        super.init(description, exitCode: 4)
    }
}

class BuildFailedError: MunkiPkgError {
    init(_ description: String = "Build failed") {
        super.init(description, exitCode: 5)
    }
}

// Convenience extensions for throwing different error types
extension MunkiPkgError {
    static func projectExists(_ description: String) -> ProjectExistsError {
        return ProjectExistsError(description)
    }
    
    static func invalidProject(_ description: String) -> InvalidProjectError {
        return InvalidProjectError(description)
    }
    
    static func importFailed(_ description: String) -> ImportFailedError {
        return ImportFailedError(description)
    }
    
    static func buildFailed(_ description: String) -> BuildFailedError {
        return BuildFailedError(description)
    }
}

