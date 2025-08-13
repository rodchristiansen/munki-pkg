//
//  errors.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/4/25.
//

import Foundation

/// General error class for munkipkg errors
class MunkiPkgError: Error, CustomStringConvertible, LocalizedError {
    private let message: String

    // Creates a new error with the given message.
    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
    
    /// Ensures we can return a useful localizedError
    var errorDescription: String? {
        return message
    }
}



class BuildError: MunkiPkgError {}

class PkgImportError: MunkiPkgError {}

