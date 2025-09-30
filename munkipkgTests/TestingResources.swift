//
//  TestingResources.swift
//  munkipkgTests
//
//  Created by Greg Neagle on 7/5/25.
//

import Foundation

/// We use this to find bundled testing resources (files used as fixtures)
enum TestingResource {
    /// Return a file URL for a bundled test file in the fixtures directory
    static func url(for resource: String) -> URL? {
        return Bundle.module.url(forResource: resource, withExtension: nil, subdirectory: "fixtures")
    }

    /// Return a path for a bundled test file in the fixtures directory
    static func path(for resource: String) -> String? {
        return Bundle.module.url(forResource: resource, withExtension: nil, subdirectory: "fixtures")?.path
    }
}
