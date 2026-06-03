//
//  munkipkgoptions.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import Foundation

/// Format for the build result printed to stdout. Progress and diagnostics
/// always go to stderr regardless of this setting.
enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case text
    case json
}

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

    @Flag(name: .long,
          help: "Validate the package project (build-info, scripts, signing/notarization coherence) without building. Exits non-zero if any error is found. Useful as a fast pre-build check in PR CI.")
    var lint = false

    @Argument(help: "Path to package project directory.")
    var projectPath: String = ""

    mutating func validate() throws {
        var actionCount = 0
        if build { actionCount += 1 }
        if create { actionCount += 1 }
        if importPath != nil { actionCount += 1 }
        if sync { actionCount += 1 }
        if convert { actionCount += 1 }
        if lint { actionCount += 1 }
        if actionCount == 0 {
            // default to build
            build = true
            actionCount = 1
        }
        if actionCount != 1 {
            throw ValidationError("One (and only one) of --build, --create, --import, --sync, --convert, or --lint must be specified.")
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

    @Flag(name: .long,
          help: "Skips the post-build prompt to import the package into a Munki repo with munkiimport. Useful for automation and CI/CD pipelines.")
    var noImport = false
    
    @Option(name: .long,
            help: ArgumentHelp("Path to .env file containing build-time variables to substitute into scripts. If not specified, auto-detects .env in project directory. Values are embedded as plain text in the built .pkg — do NOT use this for secrets.", valueName: "path"))
    var env: String?

    @Flag(name: .customLong("strict-env"),
          help: "Fail the build if a script contains a placeholder that has no matching environment variable. Default behavior is to warn and leave the placeholder unsubstituted.")
    var strictEnv = false

    @Flag(name: .customLong("no-system-env"),
          help: "Do not merge MUNKIPKG_* prefixed variables from the calling process environment. By default these are merged in alongside the .env file.")
    var noSystemEnv = false

    @Option(name: .customLong("output-format"),
            help: "Format for the result printed to stdout: 'text' (default, human-readable summary) or 'json' (machine-readable report for CI). Valid with --build (build manifest) and --lint (lint report). All progress and diagnostics go to stderr. With --build it implies --no-import.")
    var outputFormat: OutputFormat = .text

    @Option(name: .customLong("pkg-version"),
            help: ArgumentHelp("Override the version from build-info. Lets the version come from a git tag or CI variable instead of being committed to the project. Resolved before ${version} substitution in the package name.", valueName: "version"))
    var pkgVersion: String?

    @Option(name: .customLong("output-dir"),
            help: ArgumentHelp("Write the built package to this directory instead of the project's build/ directory. Created if it does not exist.", valueName: "path"))
    var outputDir: String?

    @Flag(name: .long,
          help: "After building, verify the package: assert a signature is present when signing was requested (pkgutil --check-signature) and that it passes Gatekeeper assessment when notarized (spctl). Fails the build on mismatch.")
    var verify = false
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
