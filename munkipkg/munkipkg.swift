//
//  munkipkg.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import CryptoKit
import Foundation

// Default .gitignore content for new projects
private let GITIGNORE_DEFAULT = """
# .DS_Store files!
.DS_Store

# our build directory
build/

# Environment files used for build-time variable substitution.
# Note: any value substituted into a pre/postinstall script ends up as plain
# text inside the built .pkg, so don't put real secrets here regardless.
.env
"""

// Helper for printing to stderr
private func printStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// Machine-readable summary of a completed build. Emitted on stdout as JSON when
/// `--output-format json` is requested so CI steps can consume the result without
/// scraping human-readable status text.
struct BuildResult: Codable, Sendable {
    let name: String
    let version: String
    let identifier: String
    let pkgPath: String
    let sha256: String
    let signed: Bool
    let notarized: Bool
    let stapled: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case identifier
        case pkgPath = "pkg_path"
        case sha256
        case signed
        case notarized
        case stapled
    }
}

// CFPreferences domain for munkipkg admin preferences.
private let MUNKIPKG_PREFS_DOMAIN = "com.github.munki.munkipkg"

/// Read a munkipkg admin preference.
///
/// Looks `key` up via `CFPreferencesCopyAppValue`, which searches the standard
/// preference path: a managed/forced configuration profile first, then the
/// user's preferences. This lets an MDM profile or
/// `defaults write com.github.munki.munkipkg <key> <value>` configure munkipkg
/// behavior. Returns nil when the key is not set in any domain.
private func adminPref(_ key: String) -> Any? {
    CFPreferencesCopyAppValue(key as CFString, MUNKIPKG_PREFS_DOMAIN as CFString)
}

@main
struct MunkiPkg: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "munkipkg",
        abstract: "A tool for building Apple installer packages from the contents of a package project directory."
    )

    @OptionGroup(title: "Actions")
    var actionOptions: ActionOptions

    @OptionGroup(title: "Build options")
    var buildOptions: BuildOptions

    @OptionGroup(title: "Create and import options")
    var createImportOptions: CreateAndImportOptions

    @OptionGroup(title: "Convert options")
    var convertOptions: ConvertOptions

    @OptionGroup(title: "Additional options")
    var additionalOptions: AdditionalOptions

    mutating func validate() throws {
        // Allow --version without a project path
        if additionalOptions.version {
            return
        }
        
        // All other operations require a project path
        if actionOptions.projectPath.isEmpty {
            throw ValidationError("Missing expected argument '<project-path>'")
        }
        
        // action is not build
        if !actionOptions.build {
            // check for options that only work with --build
            if buildOptions.exportBomInfo {
                throw ValidationError("--export-bom-info only valid with --build")
            }
            if buildOptions.skipNotarization {
                throw ValidationError("--skip-notarization only valid with --build")
            }
            if buildOptions.skipStapling {
                throw ValidationError("--skip-stapling only valid with --build")
            }
            if buildOptions.noImport {
                throw ValidationError("--no-import only valid with --build")
            }
            if buildOptions.pkgVersion != nil {
                throw ValidationError("--pkg-version only valid with --build")
            }
            if buildOptions.outputDir != nil {
                throw ValidationError("--output-dir only valid with --build")
            }
            if buildOptions.verify {
                throw ValidationError("--verify only valid with --build")
            }
            if buildOptions.provenance {
                throw ValidationError("--provenance only valid with --build")
            }
        }

        // --output-format produces a result report; it applies to --build and --lint.
        if buildOptions.outputFormat != .text, !actionOptions.build, !actionOptions.lint {
            throw ValidationError("--output-format only valid with --build or --lint")
        }

        // Reject empty/whitespace values that would otherwise fail with a less
        // clear error deeper in the build (or target an unintended path).
        if let pkgVersion = buildOptions.pkgVersion, pkgVersion.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--pkg-version must not be empty")
        }
        if let outputDir = buildOptions.outputDir, outputDir.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--output-dir must not be empty")
        }

        // action is not create or import
        if !actionOptions.create && actionOptions.importPath == nil {
            // check for options that only apply to create or import
            if createImportOptions.force {
                throw ValidationError("--force only valid with --create or --import")
            }
            if createImportOptions.json {
                throw ValidationError("--json only valid with --create or --import")
            }
            if createImportOptions.yaml {
                throw ValidationError("--yaml only valid with --create or --import")
            }
        }

        // action is convert - validate format options
        if actionOptions.convert {
            let formatCount = [convertOptions.toYaml, convertOptions.toPlist, convertOptions.toJson].filter { $0 }.count
            if formatCount == 0 {
                throw ValidationError("--convert requires a target format: --to-yaml, --to-plist, or --to-json")
            }
            if formatCount > 1 {
                throw ValidationError("Please specify only one target format")
            }
        } else {
            // Not convert - check for convert-only options
            if convertOptions.toYaml || convertOptions.toPlist || convertOptions.toJson {
                throw ValidationError("--to-yaml, --to-plist, and --to-json are only valid with --convert")
            }
            if convertOptions.dryRun {
                throw ValidationError("--dry-run is only valid with --convert")
            }
        }
    }
    
    mutating func run() async throws {
        // Handle --version flag first
        if additionalOptions.version {
            print(VERSION)
            return
        }
        
        do {
            // Handle different actions
            if actionOptions.create {
                try createPackageProject()
            } else if let importPath = actionOptions.importPath {
                try await importPackage(from: importPath)
            } else if actionOptions.sync {
                try syncFromBomInfo()
            } else if actionOptions.convert {
                try convertBuildInfo()
            } else if actionOptions.lint {
                try lintProject()
            } else if actionOptions.build {
                try await buildPackage()
            } else {
                // Default action - provide help
                print(MunkiPkg.helpMessage())
            }
        } catch let error as MunkiPkgError {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw ExitCode(Int32(error.exitCode))
        }
    }
    
    private func createPackageProject() throws {
        let projectPath = actionOptions.projectPath
        
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Check if directory already exists
        if FileManager.default.fileExists(atPath: projectPath) && !createImportOptions.force {
            throw MunkiPkgError.projectExists("Project directory already exists. Use --force to overwrite.")
        }
        
        // Create directory structure
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("payload"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        
        // Create build-info file
        let buildInfo = BuildInfo()
        let buildInfoPath = projectURL.appendingPathComponent("build-info.plist").path
        
        if createImportOptions.json {
            try buildInfo.jsonString().write(toFile: buildInfoPath.replacingOccurrences(of: ".plist", with: ".json"), 
                                           atomically: true, encoding: .utf8)
        } else if createImportOptions.yaml {
            try buildInfo.yamlString().write(toFile: buildInfoPath.replacingOccurrences(of: ".plist", with: ".yaml"), 
                                           atomically: true, encoding: .utf8)
        } else {
            try buildInfo.plistString().write(toFile: buildInfoPath, atomically: true, encoding: .utf8)
        }
        
        // Create default .gitignore
        try createDefaultGitignore(at: projectURL)
        
        print("Created package project at: \(projectPath)")
    }
    
    // MARK: - Import functionality
    private func importPackage(from importPath: String) async throws {
        let projectPath = actionOptions.projectPath
        
        let importURL = URL(fileURLWithPath: importPath)
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Check if import file exists
        guard FileManager.default.fileExists(atPath: importPath) else {
            throw MunkiPkgError.importFailed("Import file does not exist: \(importPath)")
        }
        
        // Check if project directory already exists
        if FileManager.default.fileExists(atPath: projectPath) && !createImportOptions.force {
            throw MunkiPkgError.projectExists("Project directory already exists. Use --force to overwrite.")
        }
        
        // Determine if it's a flat package or bundle package
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: importPath, isDirectory: &isDirectory)
        
        if isDirectory.boolValue {
            try await importBundlePackage(from: importURL, to: projectURL)
        } else {
            try await importFlatPackage(from: importURL, to: projectURL)
        }
        
        // Create default .gitignore
        try createDefaultGitignore(at: projectURL)
        
        print("Successfully imported package to: \(projectPath)")
    }
    
    private func importFlatPackage(from packageURL: URL, to projectURL: URL) async throws {
        // Create project directory
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        
        // Expand the flat package to get payload and scripts
        try await expandPayload(from: packageURL, to: projectURL)
        
        // Convert PackageInfo to build-info format
        try convertPackageInfo(at: projectURL)
        
        print("Imported flat package: \(packageURL.lastPathComponent)")
    }
    
    private func importBundlePackage(from packageURL: URL, to projectURL: URL) async throws {
        // Create project directory
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        
        // Find the Payload in the bundle
        let payloadPath = packageURL.appendingPathComponent("Contents/Archive.pax.gz")
        if FileManager.default.fileExists(atPath: payloadPath.path) {
            try await expandPayload(from: payloadPath, to: projectURL)
        }
        
        // Copy scripts from Resources
        try copyBundlePackageScripts(from: packageURL, to: projectURL)
        
        // Convert PackageInfo to build-info format
        try convertPackageInfo(at: projectURL)
        
        print("Imported bundle package: \(packageURL.lastPathComponent)")
    }
    
    private func expandPayload(from sourceURL: URL, to projectURL: URL) async throws {
        let payloadDir = projectURL.appendingPathComponent("payload")
        let tempDir = projectURL.appendingPathComponent("temp")
        
        // Use pkgutil to extract payload
        let result = await runCliAsync(
            "/usr/sbin/pkgutil", 
            arguments: ["--expand-full", sourceURL.path, tempDir.path]
        )
        
        if result.exitCode != 0 {
            throw MunkiPkgError.importFailed("Failed to expand package payload: \(result.stderr)")
        }
        
        // Handle payload directory - remove existing and move from temp
        let tempPayloadPath = tempDir.appendingPathComponent("Payload")
        if FileManager.default.fileExists(atPath: tempPayloadPath.path) {
            // Remove existing payload directory if it exists
            if FileManager.default.fileExists(atPath: payloadDir.path) {
                try FileManager.default.removeItem(at: payloadDir)
            }
            // Move the extracted payload directory to the project
            try FileManager.default.moveItem(at: tempPayloadPath, to: payloadDir)
        } else {
            // Create empty payload directory if no payload was found
            try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        }
        
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    private func copyBundlePackageScripts(from packageURL: URL, to projectURL: URL) throws {
        let scriptsDir = projectURL.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        
        let resourcesPath = packageURL.appendingPathComponent("Contents/Resources")
        
        // Common script names to look for
        let scriptNames = ["preinstall", "postinstall", "preupgrade", "postupgrade"]
        
        for scriptName in scriptNames {
            let scriptPath = resourcesPath.appendingPathComponent(scriptName)
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                let destPath = scriptsDir.appendingPathComponent(scriptName)
                try FileManager.default.copyItem(at: scriptPath, to: destPath)
                
                // Make executable
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destPath.path
                )
            }
        }
    }
    
    private func convertPackageInfo(at projectURL: URL) throws {
        let packageInfoPath = projectURL.appendingPathComponent("temp/PackageInfo")
        
        guard FileManager.default.fileExists(atPath: packageInfoPath.path) else {
            // Create default build-info if no PackageInfo found
            let buildInfo = BuildInfo()
            let buildInfoPath = projectURL.appendingPathComponent("build-info.plist")
            try buildInfo.plistString().write(to: buildInfoPath, atomically: true, encoding: .utf8)
            return
        }
        
        // Parse PackageInfo XML and convert to build-info
        let packageInfoData = try Data(contentsOf: packageInfoPath)
        let doc = try XMLDocument(data: packageInfoData)
        
        var buildInfo = BuildInfo()
        
        // Extract package information from XML
        if let identifierNode = try doc.nodes(forXPath: "//pkg-info/@identifier").first {
            buildInfo.identifier = identifierNode.stringValue ?? ""
        }
        
        if let versionNode = try doc.nodes(forXPath: "//pkg-info/@version").first {
            buildInfo.version = versionNode.stringValue ?? "1.0"
        }
        
        if let installKbytesNode = try doc.nodes(forXPath: "//pkg-info/@install-kbytes").first,
           let installKbytes = Int(installKbytesNode.stringValue ?? "") {
            buildInfo.installKbytes = installKbytes
        }
        
        // Save build-info file
        let buildInfoPath = projectURL.appendingPathComponent(
            createImportOptions.json ? "build-info.json" : 
            createImportOptions.yaml ? "build-info.yaml" : "build-info.plist"
        )
        
        if createImportOptions.json {
            try buildInfo.jsonString().write(to: buildInfoPath, atomically: true, encoding: .utf8)
        } else if createImportOptions.yaml {
            try buildInfo.yamlString().write(to: buildInfoPath, atomically: true, encoding: .utf8)
        } else {
            try buildInfo.plistString().write(to: buildInfoPath, atomically: true, encoding: .utf8)
        }
    }
    
    // MARK: - Helper functions
    
    private func createDefaultGitignore(at projectURL: URL) throws {
        let gitignorePath = projectURL.appendingPathComponent(".gitignore")
        try GITIGNORE_DEFAULT.write(to: gitignorePath, atomically: true, encoding: .utf8)
    }

    /// Emit a build progress/status line to stderr, honoring `--quiet`. stdout is
    /// reserved for the build result (the human summary or `--output-format json`
    /// manifest) so it stays parseable in a pipeline.
    private func status(_ message: String) {
        if !additionalOptions.quiet {
            printStderr(message + "\n")
        }
    }

    /// Emit raw subprocess output (pkgbuild/productbuild/notarytool) to stderr as a
    /// diagnostic, honoring `--quiet`. No trailing newline is added.
    private func diagnostic(_ text: String) {
        if !additionalOptions.quiet, !text.isEmpty {
            printStderr(text)
        }
    }

    /// Streaming SHA-256 of a file, returned as a lowercase hex string. Reads in
    /// chunks so a large .pkg isn't loaded into memory all at once.
    private func sha256(ofFileAt path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Print the build result to stdout in the requested format.
    private func emitBuildResult(_ result: BuildResult) throws {
        switch buildOptions.outputFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Write the encoder's UTF-8 output straight to stdout (plus a trailing
            // newline) so a manifest is always emitted — no Data→String round-trip
            // that could silently drop the result.
            var data = try encoder.encode(result)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        case .text:
            print("Package built successfully: \(result.pkgPath)")
        }
    }
    
    private func analyzePermissionsInBom(bomPath: URL, buildInfo: BuildInfo) -> (hasNonRecommendedOwnership: Bool, warnings: [String]) {
        var hasNonRootOwnership = false
        var warnings: [String] = []
        
        guard let bomContent = try? String(contentsOf: bomPath, encoding: .utf8) else {
            return (false, [])
        }
        
        let lines = bomContent.components(separatedBy: .newlines)
        
        for line in lines {
            // Skip empty lines and root directory entry
            if line.isEmpty || line.hasPrefix(".\t") {
                continue
            }
            
            // Parse BOM line format: "path\tmode\tuid/gid"
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            
            let path = parts[0]
            let ownerGroup = parts[2]
            
            // Parse owner/group
            let ownerParts = ownerGroup.components(separatedBy: "/")
            let uid = uid_t(ownerParts[0]) ?? 0
            let gid = gid_t(ownerParts.count > 1 ? ownerParts[1] : "0") ?? 0
            
            // Check for non-root ownership
            if uid != 0 || gid != 0 {
                hasNonRootOwnership = true
                warnings.append("File \(path) has owner/group \(ownerGroup) (not 0/0)")
            }
        }
        
        // Provide recommendations based on findings
        if hasNonRootOwnership && buildInfo.ownership == .recommended {
            warnings.insert("WARNING: BOM contains files with non-root ownership (not 0/0), but build-info ownership is set to 'recommended'.", at: 0)
            warnings.insert("RECOMMENDATION: Consider changing ownership to 'preserve' or 'preserve-other' in build-info to maintain the correct ownership.", at: 1)
        }
        
        return (hasNonRootOwnership, warnings)
    }
    
    private func syncFromBomInfo() throws {
        let projectPath = actionOptions.projectPath
        let projectURL = URL(fileURLWithPath: projectPath)
        let bomPath = projectURL.appendingPathComponent("Bom.txt")
        
        guard FileManager.default.fileExists(atPath: bomPath.path) else {
            throw MunkiPkgError("No Bom.txt file found in \(projectPath)")
        }
        
        // Load build info to check ownership mode
        let buildInfo = try loadBuildInfo(from: projectURL)
        let runningAsRoot = getuid() == 0
        
        // Analyze BOM for permission issues
        let (_, warnings) = analyzePermissionsInBom(bomPath: bomPath, buildInfo: buildInfo)
        
        // Display warnings about ownership issues
        if !warnings.isEmpty {
            for warning in warnings {
                printStderr("\(warning)\n")
            }
            printStderr("\n")
        }
        
        // Warn if ownership mode might require sudo
        if buildInfo.ownership != .recommended && !runningAsRoot {
            printStderr("WARNING: build-info ownership: \(buildInfo.ownership?.rawValue ?? "unknown") might require using sudo to properly sync owner and group for payload files.\n\n")
        }
        
        let bomContent = try String(contentsOf: bomPath, encoding: .utf8)
        let lines = bomContent.components(separatedBy: .newlines)
        
        var changesMade = 0
        let payloadDir = projectURL.appendingPathComponent("payload")
        
        for line in lines {
            // Skip empty lines and root directory entry
            if line.isEmpty || line.hasPrefix(".\t") {
                continue
            }
            
            // Parse BOM line format: "path\tmode\tuid/gid"
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            
            let path = parts[0]
            let fullMode = parts[1]
            let ownerGroup = parts[2]
            
            let payloadPath = payloadDir.appendingPathComponent(path)
            
            // Check for extended attributes warning
            let basename = (path as NSString).lastPathComponent
            if basename.hasPrefix("._") {
                let otherfile = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(String(basename.dropFirst(2)))
                printStderr("WARNING: file \(path) contains extended attributes or a resource fork for \(otherfile). git and pkgbuild may not properly preserve extended attributes.\n")
                continue
            }
            
            // Parse mode (handle both octal 4-digit and 5-digit)
            let mode: mode_t
            if fullMode.count == 5 {
                // 5-digit mode includes file type
                mode = mode_t(fullMode.suffix(4), radix: 8) ?? 0
            } else {
                mode = mode_t(fullMode, radix: 8) ?? 0
            }
            
            // Parse owner/group
            let ownerParts = ownerGroup.components(separatedBy: "/")
            let uid = uid_t(ownerParts[0]) ?? 0
            let gid = gid_t(ownerParts.count > 1 ? ownerParts[1] : "0") ?? 0
            
            if FileManager.default.fileExists(atPath: payloadPath.path) {
                // Update permissions on existing file/directory
                do {
                    var attributes: [FileAttributeKey: Any] = [
                        .posixPermissions: mode
                    ]
                    
                    // Only set owner/group if not in recommended mode or if running as root
                    if buildInfo.ownership != .recommended || runningAsRoot {
                        attributes[.ownerAccountID] = uid
                        attributes[.groupOwnerAccountID] = gid
                    }
                    
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: payloadPath.path)
                    changesMade += 1
                } catch {
                    printStderr("ERROR: Could not update \(payloadPath.path): \(error.localizedDescription)\n")
                }
            } else if fullMode.hasPrefix("4") {
                // Missing directory - create it
                do {
                    try FileManager.default.createDirectory(at: payloadPath, withIntermediateDirectories: true)
                    
                    var attributes: [FileAttributeKey: Any] = [
                        .posixPermissions: mode
                    ]
                    
                    if buildInfo.ownership != .recommended || runningAsRoot {
                        attributes[.ownerAccountID] = uid
                        attributes[.groupOwnerAccountID] = gid
                    }
                    
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: payloadPath.path)
                    changesMade += 1
                } catch {
                    printStderr("ERROR: Could not create directory \(payloadPath.path): \(error.localizedDescription)\n")
                }
            } else {
                // Missing file - this is a problem
                printStderr("ERROR: File \(payloadPath.path) is missing in payload\n")
                throw MunkiPkgError("Sync failed: missing files in payload")
            }
        }
        
        if !additionalOptions.quiet {
            print("Sync complete. Updated \(changesMade) items from Bom.txt")
        }
    }
    
    private func makeComponentPropertyList(buildInfo: BuildInfo, tempDir: URL) async throws -> URL? {
        // Only create if suppress_bundle_relocation is true
        guard buildInfo.suppressBundleRelocation == true else {
            return nil
        }
        
        let componentPlistPath = tempDir.appendingPathComponent("component.plist")
        let payloadPath = tempDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("payload").path
        
        // Use pkgbuild --analyze to generate template
        let analyzeArgs = [
            "--analyze",
            "--root", payloadPath,
            componentPlistPath.path
        ]
        
        let analyzeResult = await runCliAsync("/usr/bin/pkgbuild", arguments: analyzeArgs)
        guard analyzeResult.exitCode == 0 else {
            throw MunkiPkgError("Failed to analyze package components")
        }
        
        // Read the plist and modify BundleIsRelocatable
        guard let plistData = try? Data(contentsOf: componentPlistPath),
              var plistArray = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [[String: Any]] else {
            throw MunkiPkgError("Failed to read component plist")
        }
        
        // Set BundleIsRelocatable to false for all components
        for i in 0..<plistArray.count {
            plistArray[i]["BundleIsRelocatable"] = false
        }
        
        // Write back
        let modifiedData = try PropertyListSerialization.data(fromPropertyList: plistArray, format: .xml, options: 0)
        try modifiedData.write(to: componentPlistPath)
        
        return componentPlistPath
    }
    
    private func makePkgInfo(buildInfo: BuildInfo, tempDir: URL) throws -> URL? {
        // Only create if we have postinstall_action or preserve_xattr
        guard buildInfo.postinstallAction != nil || buildInfo.preserveXattr == true else {
            return nil
        }
        
        let pkginfoPath = tempDir.appendingPathComponent("PackageInfo")
        
        // Create a minimal PackageInfo XML
        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info postinstall-action="\(buildInfo.postinstallAction?.rawValue ?? "none")"
        """
        
        if buildInfo.preserveXattr == true {
            xml += " preserve-xattr=\"true\""
        }
        
        xml += "/>\n"
        
        try xml.write(to: pkginfoPath, atomically: true, encoding: .utf8)
        return pkginfoPath
    }
    
    // MARK: - Build functionality
    private func buildPackage() async throws {
        let projectPath = actionOptions.projectPath
        
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Load build info, applying any CLI version override.
        let buildInfo = try loadBuildInfo(from: projectURL, versionOverride: buildOptions.pkgVersion)

        // Load build-time variables from .env (and optionally system env).
        let envVars = try loadEnvironmentVariables(for: projectURL)

        // Build the package
        let result = try await performBuild(projectURL: projectURL, buildInfo: buildInfo, envVars: envVars)

        if buildOptions.exportBomInfo {
            try await exportBom(for: projectURL, buildInfo: buildInfo)
        }

        try emitBuildResult(result)

        // Skip the import prompt entirely if --no-import was passed, or whenever a
        // machine-readable result was requested — JSON output implies an automated
        // pipeline, and an interactive prompt would both stall it and pollute stdout.
        if buildOptions.noImport || buildOptions.outputFormat != .text {
            return
        }

        // Prompt to import into repo using munkiimport.
        let importAfterBuild = adminPref("import_after_build") as? Bool ?? false
        if try await promptYesNo("Do you want to import new .pkg into repo?", defaultYes: importAfterBuild) {
            try await runMunkiimport(packagePath: result.pkgPath)
        }
    }
    
    /// Load build-time variables from a `.env` file and merge with selected
    /// system-environment variables. Honors `--env`, `--no-system-env`, and emits
    /// warnings about permissive `.env` modes and git-tracked `.env` files.
    private func loadEnvironmentVariables(for projectURL: URL) throws -> [String: String] {
        let envFilePath: String
        let envExplicit: Bool
        if let customEnvPath = buildOptions.env {
            envFilePath = customEnvPath
            envExplicit = true
            if !FileManager.default.fileExists(atPath: envFilePath) {
                throw MunkiPkgError("Specified environment file does not exist: \(envFilePath)")
            }
        } else {
            envFilePath = projectURL.appendingPathComponent(".env").path
            envExplicit = false
        }

        let envFileVars = try EnvLoader.load(from: envFilePath)
        let merged = EnvLoader.merge(envFileVars: envFileVars, includeSysEnv: !buildOptions.noSystemEnv)

        // Informational lines self-quiet via status(); warnings and the secret-like
        // NOTE are emitted regardless of --quiet, which only suppresses progress.
        if !envFileVars.isEmpty {
            status("munkipkg: loaded \(envFileVars.count) build-time variable(s) from \(envFilePath)")
        } else if envExplicit {
            printStderr("WARNING: environment file \(envFilePath) contained no variables.\n")
        }
        if !merged.systemEnvKeys.isEmpty {
            status("munkipkg: picked up \(merged.systemEnvKeys.count) MUNKIPKG_* var(s) from system environment: \(merged.systemEnvKeys.joined(separator: ", "))")
        }
        // Only print the plain-text-in-pkg note when keys look secret-like.
        // For benign keys (SERVER_URL, ORG_NAME) the note would just train
        // users to ignore it.
        if Self.containsSecretLikeKey(merged.vars.keys) {
            printStderr("NOTE: one or more variable names look secret-like (KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL). Substituted values end up as plain text inside the built .pkg — anyone with the package can read them via `pkgutil --expand`. Use this mechanism for build-time configuration only; fetch real secrets at runtime from Keychain or an MDM-delivered profile.\n")
        }

        // Warn if a .env file exists in the project at all, regardless of whether
        // it parsed to any variables — a file containing only comments or only
        // invalid keys is still git-relevant and will be committed.
        if FileManager.default.fileExists(atPath: envFilePath) {
            warnIfEnvIsGitTracked(envPath: envFilePath, projectURL: projectURL, isExplicit: envExplicit)
        }

        return merged.vars
    }

    private static let secretLikePattern: NSRegularExpression = {
        // Case-insensitive; anchored to word components so SERVER doesn't match.
        return try! NSRegularExpression(
            pattern: #"(?i)(^|_)(key|token|secret|password|passwd|credential|apikey)($|_)"#
        )
    }()

    private static func containsSecretLikeKey<S: Sequence>(_ keys: S) -> Bool where S.Element == String {
        for key in keys {
            let range = NSRange(location: 0, length: (key as NSString).length)
            if secretLikePattern.firstMatch(in: key, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Warn if the `.env` file is tracked by git (or about to be — i.e., not ignored
    /// and inside a git working tree). No-op outside a git repo or for `.env` files
    /// outside the project directory (those are the caller's responsibility).
    private func warnIfEnvIsGitTracked(envPath: String, projectURL: URL, isExplicit: Bool) {
        let projectPath = projectURL.path
        // Probe whether projectPath is inside a git working tree.
        let revParse = runGitProbe(["-C", projectPath, "rev-parse", "--is-inside-work-tree"])
        guard revParse.exitCode == 0, revParse.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return
        }

        // Determine the path to query against git. Pass a project-relative path when
        // the .env is inside the project, so git resolves it correctly even when the
        // project dir or env path is reached via symlinks. For an explicit --env path
        // outside the project, skip the check entirely — it's not the project's repo.
        let pathForGit: String
        let stdProjectPath = (projectPath as NSString).standardizingPath
        let stdEnvPath = (envPath as NSString).standardizingPath
        if !isExplicit {
            pathForGit = ".env"
        } else if stdEnvPath.hasPrefix(stdProjectPath + "/") {
            pathForGit = String(stdEnvPath.dropFirst(stdProjectPath.count + 1))
        } else {
            return
        }

        let lsFiles = runGitProbe(["-C", projectPath, "ls-files", "--error-unmatch", pathForGit])
        if lsFiles.exitCode == 0 {
            printStderr("WARNING: \(envPath) is tracked by git. Substituted values will be embedded in the .pkg AND visible in your repo history. Add `.env` to .gitignore and rotate any sensitive values that have been committed.\n")
            return
        }
        let checkIgnore = runGitProbe(["-C", projectPath, "check-ignore", "-q", pathForGit])
        if checkIgnore.exitCode != 0 {
            printStderr("WARNING: \(envPath) is not gitignored. A future `git add` will commit it. Add `.env` to .gitignore.\n")
        }
    }

    /// Run a short-output git command and capture stdout/stderr. Reads pipes
    /// concurrently with `proc.waitUntilExit()` so a child producing more than
    /// the pipe-buffer's worth of output cannot deadlock the parent.
    private func runGitProbe(_ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return (-1, "", "\(error)")
        }

        // Hold the captured Data values in a Sendable box so the concurrent reader
        // closures can write to independent fields without violating capture-sendability
        // rules. Each closure writes its own field exactly once; the parent reads only
        // after `group.wait()`, so there's no concurrent mutation.
        final class DataBox: @unchecked Sendable {
            var stdout = Data()
            var stderr = Data()
        }
        let box = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        proc.waitUntilExit()
        group.wait()

        return (
            proc.terminationStatus,
            String(data: box.stdout, encoding: .utf8) ?? "",
            String(data: box.stderr, encoding: .utf8) ?? ""
        )
    }
    
    private func loadBuildInfo(from projectURL: URL, versionOverride: String? = nil) throws -> BuildInfo {
        // Try different build-info file formats
        let possiblePaths = [
            projectURL.appendingPathComponent("build-info.plist"),
            projectURL.appendingPathComponent("build-info.json"),
            projectURL.appendingPathComponent("build-info.yaml")
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                var buildInfo = try BuildInfo(fromFile: path.path)
                // Apply a CLI version override before substitution so a ${version}
                // placeholder in the package name resolves to the overridden value.
                if let versionOverride {
                    buildInfo.version = versionOverride
                }
                buildInfo.doSubstitutions()
                return buildInfo
            }
        }

        throw MunkiPkgError.invalidProject("No build-info file found")
    }
    
    private func performBuild(projectURL: URL, buildInfo: BuildInfo, envVars: [String: String] = [:]) async throws -> BuildResult {
        // Create build directory
        let buildDir = projectURL.appendingPathComponent("build")
        if !FileManager.default.fileExists(atPath: buildDir.path) {
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        }
        
        // Create temp directory for component plist, pkginfo, and processed scripts.
        // Mode 0700 so substituted-script copies aren't readable by other local users
        // during the build window.
        let tempDir = buildDir.appendingPathComponent("tmp")
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        }
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Check if payload directory exists and has contents
        let payloadPath = projectURL.appendingPathComponent("payload")
        var isDirectory: ObjCBool = false
        let payloadExists = FileManager.default.fileExists(atPath: payloadPath.path, isDirectory: &isDirectory)
        let hasPayload = payloadExists && isDirectory.boolValue
        
        // Generate component property list if needed (only if payload exists)
        let componentPlistPath: URL?
        if hasPayload {
            componentPlistPath = try await makeComponentPropertyList(buildInfo: buildInfo, tempDir: tempDir)
        } else {
            componentPlistPath = nil
        }
        
        // Generate PackageInfo if needed
        let pkginfoPath = try makePkgInfo(buildInfo: buildInfo, tempDir: tempDir)
        
        let packageName = buildInfo.name.hasSuffix(".pkg") ? buildInfo.name : "\(buildInfo.name).pkg"
        let componentPackagePath = buildDir.appendingPathComponent(packageName).path
        
        // Build component package with pkgbuild
        var pkgbuildArgs: [String] = []
        var useNoPayload = false
        
        // Determine if we should use --nopayload or --root
        if hasPayload {
            // Check if payload directory has any contents
            let payloadContents = try? FileManager.default.contentsOfDirectory(atPath: payloadPath.path)
            if let contents = payloadContents, !contents.isEmpty {
                // Payload has contents, use --root
                pkgbuildArgs.append(contentsOf: ["--root", payloadPath.path])
            } else {
                // Payload exists but is empty, use --nopayload
                pkgbuildArgs.append("--nopayload")
                useNoPayload = true
            }
        } else {
            // Payload directory doesn't exist, use --nopayload
            pkgbuildArgs.append("--nopayload")
            useNoPayload = true
        }
        
        // Add identifier and version
        pkgbuildArgs.append(contentsOf: [
            "--identifier", buildInfo.identifier,
            "--version", buildInfo.version
        ])
        
        // Add component plist if we created one (only valid with --root)
        if !useNoPayload, let componentPlist = componentPlistPath {
            pkgbuildArgs.append(contentsOf: ["--component-plist", componentPlist.path])
        }
        
        // Add pkginfo if we created one
        if let pkginfo = pkginfoPath {
            pkgbuildArgs.append(contentsOf: ["--info", pkginfo.path])
        }
        
        // Add install location if specified (only valid with --root)
        if !useNoPayload, let installLocation = buildInfo.installLocation {
            pkgbuildArgs.append(contentsOf: ["--install-location", installLocation])
        }
        
        // Add ownership if specified
        if let ownership = buildInfo.ownership {
            pkgbuildArgs.append(contentsOf: ["--ownership", ownership.rawValue])
        }
        
        // Add scripts if they exist. When build-time variables are present, process the
        // scripts in a temp copy so the originals are never modified. If no variables
        // are present but `--strict-env` is set, we still need to detect placeholders
        // so a script with `${MISSING}` fails the build.
        let scriptsPath = projectURL.appendingPathComponent("scripts").path
        if FileManager.default.fileExists(atPath: scriptsPath) {
            var unresolvedByScript: [String: Set<String>] = [:]
            var scriptsArgPath = scriptsPath

            if !envVars.isEmpty,
               let dirResult = try PlaceholderReplacer.processScriptsDirectory(
                   at: scriptsPath,
                   with: envVars,
                   tempDir: tempDir.path
               ) {
                status("munkipkg: substituted build-time variables into scripts (\(dirResult.unresolvedByScript.isEmpty ? "all placeholders resolved" : "some unresolved — see warnings"))")
                unresolvedByScript = dirResult.unresolvedByScript
                scriptsArgPath = dirResult.scriptsDir
            } else if buildOptions.strictEnv {
                // No variables, but strict mode is on — scan the original scripts.
                unresolvedByScript = PlaceholderReplacer.scanScriptsDirectory(at: scriptsPath)
            }

            if !unresolvedByScript.isEmpty {
                for (scriptName, keys) in unresolvedByScript.sorted(by: { $0.key < $1.key }) {
                    let names = keys.sorted().joined(separator: ", ")
                    printStderr("WARNING: unresolved placeholder(s) in \(scriptName): \(names)\n")
                }
                if buildOptions.strictEnv {
                    throw MunkiPkgError.buildFailed("--strict-env: one or more script placeholders had no matching environment variable")
                }
            }

            pkgbuildArgs.append(contentsOf: ["--scripts", scriptsArgPath])
        }
        
        pkgbuildArgs.append(componentPackagePath)

        status("pkgbuild: Building component package...")

        let pkgbuildResult = await runCliAsync("/usr/bin/pkgbuild", arguments: pkgbuildArgs)

        if pkgbuildResult.exitCode != 0 {
            throw MunkiPkgError.buildFailed("pkgbuild failed: \(pkgbuildResult.stderr)")
        }

        diagnostic(pkgbuildResult.stdout)
        diagnostic(pkgbuildResult.stderr)

        var finalPackagePath = componentPackagePath
        let isSigned = buildInfo.signingInfo != nil
        var didNotarize = false
        var didStaple = false

        // Handle distribution-style packages and signing
        if buildInfo.distributionStyle == true || buildInfo.signingInfo != nil {
            let distPackageName = "Dist-\(packageName)"
            let distPackagePath = buildDir.appendingPathComponent(distPackageName).path
            
            var productbuildArgs = [
                "--package", componentPackagePath,
                distPackagePath
            ]
            
            // Add signing if specified
            if let signingInfo = buildInfo.signingInfo {
                status("munkipkg: Adding package signing info to command")
                productbuildArgs.insert(contentsOf: ["--sign", signingInfo.identity], at: 0)
                
                // Add keychain if specified
                if let keychain = signingInfo.keychain {
                    // Expand ${HOME} environment variable if present
                    var expandedKeychain = keychain.replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
                    // Also expand tilde
                    expandedKeychain = NSString(string: expandedKeychain).expandingTildeInPath
                    productbuildArgs.insert(contentsOf: ["--keychain", expandedKeychain], at: 0)
                }
                
                // Add additional certificates if specified
                if let additionalCerts = signingInfo.additionalCertNames {
                    for certName in additionalCerts {
                        productbuildArgs.insert(contentsOf: ["--certs", certName], at: 0)
                    }
                }
                
                // Add timestamp if specified
                if signingInfo.timestamp == true {
                    productbuildArgs.insert("--timestamp", at: 0)
                }
            }
            
            status("productbuild: Creating distribution package...")

            let productbuildResult = await runCliAsync("/usr/bin/productbuild", arguments: productbuildArgs)

            // Surface productbuild output as a diagnostic; force it to stderr on
            // failure even under --quiet so the cause isn't swallowed.
            if productbuildResult.exitCode != 0 {
                printStderr(productbuildResult.stdout)
                printStderr(productbuildResult.stderr)
                // A productbuild failure when signing was requested is a signing
                // failure (distinct exit code); otherwise it's a generic build failure.
                if isSigned {
                    throw MunkiPkgError.signingFailed("productbuild signing failed with exit code \(productbuildResult.exitCode)")
                }
                throw MunkiPkgError.buildFailed("productbuild failed with exit code \(productbuildResult.exitCode)")
            }
            diagnostic(productbuildResult.stdout)
            diagnostic(productbuildResult.stderr)

            // Remove component package
            status("\nmunkipkg: Removing component package \(componentPackagePath)")
            try FileManager.default.removeItem(atPath: componentPackagePath)

            // Rename distribution package
            status("munkipkg: Renaming distribution package \(distPackagePath) to \(componentPackagePath)")
            try FileManager.default.moveItem(atPath: distPackagePath, toPath: componentPackagePath)

            finalPackagePath = componentPackagePath
        }
        
        // Handle notarization
        if !buildOptions.skipNotarization,
           let notarizationInfo = buildInfo.notarizationInfo {
            
            // Prepare notarization arguments
            var notarizeArgs = ["notarytool", "submit", finalPackagePath]
            
            // Use keychain profile if specified, otherwise use Apple ID authentication
            if let keychainProfile = notarizationInfo.keychainProfile {
                notarizeArgs.append(contentsOf: ["--keychain-profile", keychainProfile])
            } else if let appleId = notarizationInfo.appleId,
                      let teamId = notarizationInfo.teamId,
                      let password = notarizationInfo.password {
                notarizeArgs.append(contentsOf: ["--apple-id", appleId])
                notarizeArgs.append(contentsOf: ["--team-id", teamId])
                notarizeArgs.append(contentsOf: ["--password", password])
                
                // Add ASC provider if specified
                if let ascProvider = notarizationInfo.ascProvider {
                    notarizeArgs.append(contentsOf: ["--asc-provider", ascProvider])
                }
            } else {
                throw MunkiPkgError.notarizationFailed("Notarization info incomplete - need either keychain_profile or apple_id+team_id+password")
            }

            notarizeArgs.append("--wait")

            status("munkipkg: Uploading package to Apple notary service")

            let notarizeResult = await runCliAsync("/usr/bin/xcrun", arguments: notarizeArgs)

            // Check if notarization was successful by looking for "Accepted" status
            let notarizationSucceeded = notarizeResult.exitCode == 0 &&
                                        notarizeResult.stdout.contains("status: Accepted")

            // On any failure, surface notarytool output to stderr (even under --quiet)
            // and fail the build. A package that declares notarization but didn't
            // notarize must never exit 0 — that's the silent-failure CI footgun.
            if !notarizationSucceeded {
                printStderr(notarizeResult.stdout)
                if !notarizeResult.stderr.isEmpty {
                    printStderr(notarizeResult.stderr)
                }
                if notarizeResult.exitCode != 0 {
                    throw MunkiPkgError.notarizationFailed("Notarization submission failed (notarytool exit code \(notarizeResult.exitCode))")
                }
                if notarizeResult.stdout.contains("status: Invalid") {
                    throw MunkiPkgError.notarizationFailed("Package notarization returned Invalid status")
                }
                throw MunkiPkgError.notarizationFailed("Notarization completed but package was not accepted")
            }

            diagnostic(notarizeResult.stdout)
            diagnostic(notarizeResult.stderr)
            status("munkipkg: Successfully received submission info")
            didNotarize = true

            // Staple unless explicitly skipped. A staple failure also fails the build:
            // an un-stapled package can't validate offline, so a green build that
            // didn't staple is misleading in a pipeline.
            if !buildOptions.skipStapling {
                status("munkipkg: Stapling package")

                let stapleResult = await runCliAsync("/usr/bin/xcrun", arguments: [
                    "stapler", "staple", finalPackagePath
                ])

                if stapleResult.exitCode == 0 {
                    status("munkipkg: The staple and validate action worked!")
                    didStaple = true
                } else {
                    printStderr(stapleResult.stdout)
                    printStderr(stapleResult.stderr)
                    throw MunkiPkgError.notarizationFailed("Stapling failed (stapler exit code \(stapleResult.exitCode))")
                }
            }
        }

        // Move the finished package to a caller-specified output directory.
        if let outputDir = buildOptions.outputDir {
            let outDirURL = URL(fileURLWithPath: outputDir)
            try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)
            let dest = outDirURL.appendingPathComponent((finalPackagePath as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(atPath: finalPackagePath, toPath: dest.path)
            finalPackagePath = dest.path
            status("munkipkg: moved package to \(dest.path)")
        }

        // Verify the built package matches what build-info declared.
        if buildOptions.verify {
            try await verifyPackage(at: finalPackagePath, signed: isSigned, notarized: didNotarize)
        }

        let digest = try sha256(ofFileAt: finalPackagePath)

        if buildOptions.provenance {
            try writeProvenance(packagePath: finalPackagePath, projectURL: projectURL, buildInfo: buildInfo, pkgSha256: digest)
        }

        return BuildResult(
            // Report the actual artifact filename so `name` always agrees with
            // `pkg_path` (the build path may append a missing .pkg extension).
            name: (finalPackagePath as NSString).lastPathComponent,
            version: buildInfo.version,
            identifier: buildInfo.identifier,
            pkgPath: finalPackagePath,
            sha256: digest,
            signed: isSigned,
            notarized: didNotarize,
            stapled: didStaple
        )
    }

    // MARK: - Provenance

    /// Supply-chain attestation written alongside the package as
    /// `<package>.provenance.json`. Records what was built, from which source, and
    /// with which tool, so a downstream consumer can tie a package back to its inputs.
    private struct Provenance: Codable {
        let tool: String
        let toolVersion: String
        let builtAt: String
        let name: String
        let identifier: String
        let version: String
        let pkgSha256: String
        let inputSha256: String
        let gitCommit: String?
        let gitRemote: String?

        enum CodingKeys: String, CodingKey {
            case tool
            case toolVersion = "tool_version"
            case builtAt = "built_at"
            case name
            case identifier
            case version
            case pkgSha256 = "pkg_sha256"
            case inputSha256 = "input_sha256"
            case gitCommit = "git_commit"
            case gitRemote = "git_remote"
        }
    }

    private func writeProvenance(packagePath: String, projectURL: URL, buildInfo: BuildInfo, pkgSha256: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Capture the source revision when the project lives in a git work tree.
        var gitCommit: String?
        var gitRemote: String?
        let revParse = runGitProbe(["-C", projectURL.path, "rev-parse", "--is-inside-work-tree"])
        if revParse.exitCode == 0, revParse.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            let head = runGitProbe(["-C", projectURL.path, "rev-parse", "HEAD"])
            if head.exitCode == 0 {
                gitCommit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let remote = runGitProbe(["-C", projectURL.path, "remote", "get-url", "origin"])
            if remote.exitCode == 0 {
                gitRemote = Self.sanitizedRemoteURL(remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let provenance = Provenance(
            tool: "munkipkg",
            toolVersion: VERSION,
            builtAt: formatter.string(from: Date()),
            name: buildInfo.name,
            identifier: buildInfo.identifier,
            version: buildInfo.version,
            pkgSha256: pkgSha256,
            inputSha256: try inputDigest(for: projectURL),
            gitCommit: gitCommit,
            gitRemote: gitRemote
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(provenance)
        let sidecarPath = packagePath + ".provenance.json"
        // Atomic write so an interrupted run or full disk can't leave a partial
        // JSON sidecar next to an otherwise-valid package.
        try data.write(to: URL(fileURLWithPath: sidecarPath), options: .atomic)
        status("munkipkg: wrote provenance to \(sidecarPath)")
    }

    /// Strip any `user:pass@` userinfo from a remote URL so credentials embedded in
    /// the origin URL never get persisted into the provenance sidecar. Non-URL
    /// remotes (scp-style `git@host:path`, local paths) are returned unchanged.
    private static func sanitizedRemoteURL(_ remote: String) -> String {
        guard let schemeRange = remote.range(of: "://") else { return remote }
        let afterScheme = schemeRange.upperBound
        guard let atIndex = remote[afterScheme...].firstIndex(of: "@") else { return remote }
        // Only treat it as userinfo if the '@' precedes the first '/' of the path.
        let pathStart = remote[afterScheme...].firstIndex(of: "/") ?? remote.endIndex
        guard atIndex < pathStart else { return remote }
        return String(remote[..<afterScheme]) + String(remote[remote.index(after: atIndex)...])
    }

    /// A digest over the build inputs: the build-info file plus every file under
    /// payload/ and scripts/, each hashed and keyed by its project-relative path.
    /// Sorted so the result is stable regardless of enumeration order.
    private func inputDigest(for projectURL: URL) throws -> String {
        var lines: [String] = []
        let fm = FileManager.default

        // Hash only the build-info file actually used for the build (same
        // plist > json > yaml precedence as loadBuildInfo), so an ignored
        // second build-info file can't perturb the digest.
        for buildInfoName in ["build-info.plist", "build-info.json", "build-info.yaml"] {
            let path = projectURL.appendingPathComponent(buildInfoName).path
            if fm.fileExists(atPath: path) {
                lines.append("\(buildInfoName):\(try sha256(ofFileAt: path))")
                break
            }
        }

        for subdir in ["payload", "scripts"] {
            let dirURL = projectURL.appendingPathComponent(subdir)
            guard let enumerator = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let relative = String(fileURL.path.dropFirst(projectURL.path.count + 1))
                lines.append("\(relative):\(try sha256(ofFileAt: fileURL.path))")
            }
        }

        let manifest = lines.sorted().joined(separator: "\n")
        var hasher = SHA256()
        hasher.update(data: Data(manifest.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    private func exportBom(for projectURL: URL, buildInfo: BuildInfo) async throws {
        let payloadPath = projectURL.appendingPathComponent("payload").path
        let bomPath = projectURL.appendingPathComponent("Bom.txt").path
        
        let result = await runCliAsync("/usr/bin/lsbom", arguments: ["-p", "MUGsf", payloadPath])
        
        if result.exitCode == 0 {
            try result.stdout.write(toFile: bomPath, atomically: true, encoding: String.Encoding.utf8)
            status("BOM info exported to: \(bomPath)")
        }
    }

    // MARK: - Verify

    /// Assert the built package matches what build-info declared. When signing was
    /// requested, the package must carry a signature; when notarization succeeded,
    /// the package must pass Gatekeeper's install assessment. Either mismatch fails
    /// the build with the matching exit code.
    private func verifyPackage(at packagePath: String, signed: Bool, notarized: Bool) async throws {
        if signed {
            status("munkipkg: verifying package signature")
            let sig = await runCliAsync("/usr/sbin/pkgutil", arguments: ["--check-signature", packagePath])
            if sig.exitCode != 0 {
                printStderr(sig.stdout)
                printStderr(sig.stderr)
                throw MunkiPkgError.signingFailed("--verify: package signature check failed (pkgutil exit code \(sig.exitCode))")
            }
            diagnostic(sig.stdout)
        }

        if notarized {
            status("munkipkg: verifying Gatekeeper assessment")
            let assess = await runCliAsync("/usr/sbin/spctl", arguments: ["-a", "-vvv", "-t", "install", packagePath])
            if assess.exitCode != 0 {
                printStderr(assess.stdout)
                printStderr(assess.stderr)
                throw MunkiPkgError.notarizationFailed("--verify: package failed Gatekeeper assessment (spctl exit code \(assess.exitCode))")
            }
            diagnostic(assess.stderr)
        }
    }

    // MARK: - Lint

    /// Structured result of a `--lint` run, emitted as JSON under `--output-format json`.
    private struct LintReport: Codable {
        let ok: Bool
        let errors: [String]
        let warnings: [String]
    }

    /// Validate a package project without building it. Collects fatal errors and
    /// non-fatal warnings, prints a report, and exits non-zero if any error is found.
    private func lintProject() throws {
        let projectURL = URL(fileURLWithPath: actionOptions.projectPath)
        var errors: [String] = []
        var warnings: [String] = []

        // build-info must exist and parse. A failure here is fatal on its own.
        let buildInfo: BuildInfo
        do {
            buildInfo = try loadBuildInfo(from: projectURL, versionOverride: buildOptions.pkgVersion)
        } catch {
            let message = (error as? MunkiPkgError)?.description ?? error.localizedDescription
            try emitLintReport(LintReport(ok: false, errors: ["build-info: \(message)"], warnings: []))
            throw ExitCode(3)
        }

        // Required fields.
        if buildInfo.name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("build-info: 'name' is empty")
        }
        if buildInfo.identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("build-info: 'identifier' is empty")
        } else if !buildInfo.identifier.contains(".") {
            warnings.append("build-info: 'identifier' (\(buildInfo.identifier)) is not in reverse-domain form (e.g. com.example.app)")
        }
        if buildInfo.version.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("build-info: 'version' is empty")
        }

        // Signing / notarization coherence.
        if let signing = buildInfo.signingInfo, signing.identity.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("signing_info: 'identity' is empty")
        }
        if let notarization = buildInfo.notarizationInfo {
            let hasProfile = !(notarization.keychainProfile?.isEmpty ?? true)
            let hasAppleId = !(notarization.appleId?.isEmpty ?? true)
                && !(notarization.teamId?.isEmpty ?? true)
                && !(notarization.password?.isEmpty ?? true)
            if !hasProfile, !hasAppleId {
                errors.append("notarization_info: need either 'keychain_profile' or all of 'apple_id', 'team_id', 'password'")
            }
            if buildInfo.signingInfo == nil {
                warnings.append("notarization_info is set but signing_info is not — notarization requires a Developer ID-signed package")
            }
        }

        // Scripts must be executable and have a shebang, or pkgbuild won't run them.
        // A missing scripts/ directory is fine; one that exists but can't be read
        // is an error, so lint doesn't report a false OK with checks skipped.
        let scriptsURL = projectURL.appendingPathComponent("scripts")
        var scriptsIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: scriptsURL.path, isDirectory: &scriptsIsDir), scriptsIsDir.boolValue {
            let scriptNames: [String]
            do {
                scriptNames = try FileManager.default.contentsOfDirectory(atPath: scriptsURL.path)
            } catch {
                errors.append("scripts/: could not be read (\(error.localizedDescription))")
                scriptNames = []
            }
            for name in scriptNames.sorted() where !name.hasPrefix(".") {
                let scriptPath = scriptsURL.appendingPathComponent(name).path
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: scriptPath, isDirectory: &isDir)
                if isDir.boolValue { continue }
                if !FileManager.default.isExecutableFile(atPath: scriptPath) {
                    warnings.append("scripts/\(name): not executable (chmod +x) — pkgbuild will not run it")
                }
                if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: scriptPath)) {
                    let head = (try? handle.read(upToCount: 2)) ?? Data()
                    try? handle.close()
                    if head != Data("#!".utf8) {
                        warnings.append("scripts/\(name): missing a #! shebang line")
                    }
                }
            }
        }

        let report = LintReport(ok: errors.isEmpty, errors: errors, warnings: warnings)
        try emitLintReport(report)
        if !errors.isEmpty {
            throw ExitCode(3)
        }
    }

    /// Print a lint report in the requested format. In text mode, findings go to
    /// stderr and the pass/fail line to stdout, mirroring the build output contract.
    private func emitLintReport(_ report: LintReport) throws {
        switch buildOptions.outputFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        case .text:
            for error in report.errors {
                printStderr("ERROR: \(error)\n")
            }
            for warning in report.warnings {
                printStderr("WARNING: \(warning)\n")
            }
            print(report.ok ? "lint: OK (\(report.warnings.count) warning(s))" : "lint: FAILED (\(report.errors.count) error(s), \(report.warnings.count) warning(s))")
        }
    }
    
    // MARK: - Munkiimport functionality
    
    /// Prompts the user for a yes/no response with a timeout
    /// - Parameters:
    ///   - message: The prompt message to display
    ///   - defaultYes: Whether 'yes' is the default (Y/n vs y/N)
    ///   - timeout: Seconds to wait before using the default (default: 60)
    /// - Returns: True if user confirms, false otherwise
    private func promptYesNo(_ message: String, defaultYes: Bool = true, timeout: TimeInterval = 60.0) async throws -> Bool {
        let promptSuffix = defaultYes ? " [Y/n]: " : " [y/N]: "
        print(message + promptSuffix, terminator: "")
        fflush(stdout)

        // If stdin is not a terminal (piped/automated), return the default immediately
        if isatty(STDIN_FILENO) == 0 {
            print(defaultYes ? "Y" : "N")
            return defaultYes
        }

        // Use poll() on stdin so the timeout is handled by the kernel
        // rather than leaving a blocked readLine() thread alive
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let timeoutMs = Int32(timeout * 1000)
                let result = Darwin.poll(&fds, 1, timeoutMs)

                if result > 0, (fds.revents & Int16(POLLIN)) != 0 {
                    // Data available — safe to call readLine() without blocking
                    let response = readLine()?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if let r = response, !r.isEmpty {
                        continuation.resume(returning: r == "y" || r == "yes")
                    } else {
                        continuation.resume(returning: defaultYes)
                    }
                } else {
                    // Timeout (0) or error (-1) — use the default
                    print("\nTimeout reached (\(Int(timeout))s). Using default: \(defaultYes ? "Y" : "N")")
                    fflush(stdout)
                    continuation.resume(returning: defaultYes)
                }
            }
        }
    }
    
    /// Runs munkiimport on the specified package
    /// - Parameter packagePath: Path to the package to import
    private func runMunkiimport(packagePath: String) async throws {
        print("\nmunkipkg: Running munkiimport \(packagePath)\n")
        fflush(stdout)
        
        // Use posix_spawn to run munkiimport with full terminal access
        var pid: pid_t = 0
        let path = "/usr/local/munki/munkiimport"
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(path),
            strdup(packagePath),
            nil
        ]
        
        // Create file actions to inherit stdin/stdout/stderr
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDERR_FILENO)
        
        let status = posix_spawn(&pid, path, &fileActions, nil, argv, environ)
        
        // Clean up argv
        for arg in argv {
            free(arg)
        }
        posix_spawn_file_actions_destroy(&fileActions)
        
        guard status == 0 else {
            throw MunkiPkgError("Failed to spawn munkiimport: \(status)")
        }
        
        // Wait for child process to complete
        var childStatus: Int32 = 0
        waitpid(pid, &childStatus, 0)
        
        let exitCode = (childStatus >> 8) & 0xFF
        if exitCode != 0 {
            print("\nmunkipkg: munkiimport failed with exit code \(exitCode)")
        } else {
            print("\nmunkipkg: Successfully imported package to repo")
        }
    }
}
