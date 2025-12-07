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

    @Flag(name: .long,
          help: "Convert build-info file(s) to a different format. Use with --to-yaml, --to-plist, or --to-json.")
    var convert = false

    @Argument(help: "Path to package project directory.")
    var projectPath: String = ""

    mutating func validate() throws {
        var actionCount = 0
        if build { actionCount += 1 }
        if create { actionCount += 1 }
        if importPath != nil { actionCount += 1 }
        if sync { actionCount += 1 }
        if convert { actionCount += 1 }
        if actionCount == 0 {
            // default to build
            build = true
            actionCount = 1
        }
        if actionCount != 1 {
            throw ValidationError("One (and only one) of --build, --create, --import, --sync, or --convert must be specified.")
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
    
    @Option(name: .long,
            help: ArgumentHelp("Path to .env file containing environment variables to inject into scripts. If not specified, auto-detects .env in project directory.", valueName: "path"))
    var env: String?
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

struct ConvertOptions: ParsableArguments {
    @Flag(name: .long,
          help: "Convert build-info to YAML format.")
    var toYaml = false

    @Flag(name: .long,
          help: "Convert build-info to plist format.")
    var toPlist = false

    @Flag(name: .long,
          help: "Convert build-info to JSON format.")
    var toJson = false

    @Flag(name: .long,
          help: "Show what would be done without making changes.")
    var dryRun = false

    mutating func validate() throws {
        // Validation happens in main command when --convert is used
    }
}

struct AdditionalOptions: ParsableArguments {
    @Flag(name: .long,
          help: "Inhibits status messages on stdout. Any error messages are still sent to stderr.")
    var quiet = false
    
    @Flag(name: .long,
          help: "Display version information.")
    var version = false
}
