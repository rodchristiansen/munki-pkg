//
//  munkipkgoptions.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import Foundation

struct ActionOptions: ParsableArguments {
    @Flag(name: .long,
          help: "Build a package using the package project at <project-path>.")
    var build = false

    @Flag(name: .long,
          help: "Creates a new empty project with default settings at <project-path>.")
    var create = false

    @Option(name: .customLong("import"),
            help: ArgumentHelp("Imports an existing package <installer-pkg> as a package project, creating <project-path> directory.", valueName: "installer-pkg"))
    var importPath: String?

    @Flag(name: .long,
          help: "Use Bom.txt in the project at <project-path> to set modes of files in payload directory and create missing empty directories. Useful after a git clone or pull.")
    var sync = false

    @Option(name: .long,
            help: ArgumentHelp("Migrate build-info file(s) to specified format (plist, json, or yaml). Can be used on a single project or a parent directory containing multiple projects.", valueName: "format"))
    var migrate: String?

    @Argument(help: "Path to package project directory.")
    var projectPath: String

    mutating func validate() throws {
        var actionCount = 0
        if build { actionCount += 1 }
        if create { actionCount += 1 }
        if importPath != nil { actionCount += 1 }
        if sync { actionCount += 1 }
        if migrate != nil { actionCount += 1 }
        if actionCount == 0 {
            // default to build
            build = true
            actionCount = 1
        }
        if actionCount != 1 {
            throw ValidationError("One (and only one) of --build, --create, --import, --sync, or --migrate must be specified.")
        }
        
        // Validate migrate format if specified
        if let format = migrate {
            let validFormats = ["plist", "json", "yaml", "yml"]
            if !validFormats.contains(format.lowercased()) {
                throw ValidationError("Invalid format '\(format)'. Must be one of: plist, json, yaml")
            }
        }
    }
}

struct BuildOptions: ParsableArguments {
    @Flag(name: .customLong("export-bom-info"),
          help: "Extracts the Bill-Of-Materials file from the output package and exports it as Bom.txt under the <project-path> directory. Useful for tracking owner, group and mode of the payload in git.")
    var exportBomInfo = false

    @Flag(name: .long,
          help: "Skips the notarization process when notarization is specified in build-info")
    var skipNotarization = false

    @Flag(name: .long,
          help: "Skips the stapling part of notarization process when notarization is specified in build-info")
    var skipStapling = false
}

struct CreateAndImportOptions: ParsableArguments {
    @Flag(name: .long,
          help: "Create build-info file in JSON format. Useful only with --create and --import options.")
    var json = false

    @Flag(name: .long,
          help: "Create build-info file in YAML format. Useful only with --create and --import options.")
    var yaml = false

    @Flag(name: .long,
          help: "Forces creation of <project-path> contents even if <project-path> already exists.")
    var force = false
    
    mutating func validate() throws {
        if json && yaml {
            throw ValidationError("Only one of --json and --yaml can be specified.")
        }
    }
}

struct AdditionalOptions: ParsableArguments {
    @Flag(name: .long,
          help: "Inhibits status messages on stdout. Any error messages are still sent to stderr.")
    var quiet = false
}
