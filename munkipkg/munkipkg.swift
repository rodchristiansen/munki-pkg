//
//  munkipkg.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import Foundation

// Version number for munkipkg (dynamically generated timestamp format: YYYY.MM.DD.HHMM)
private var VERSION: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy.MM.dd.HHmm"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date())
}

// Default .gitignore content for new projects
private let GITIGNORE_DEFAULT = """
# .DS_Store files!
.DS_Store

# our build directory
build/

# Environment files containing secrets
.env
"""

// Helper for printing to stderr
private func printStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
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
        
        // Load build info
        let buildInfo = try loadBuildInfo(from: projectURL)
        
        // Load environment variables for secret injection
        let envVars = try loadEnvironmentVariables(for: projectURL)
        if !envVars.isEmpty && !additionalOptions.quiet {
            print("munkipkg: Loaded \(envVars.count) environment variable(s) for script injection")
        }
        
        // Build the package
        let outputPath = try await performBuild(projectURL: projectURL, buildInfo: buildInfo, envVars: envVars)
        
        if buildOptions.exportBomInfo {
            try await exportBom(for: projectURL, buildInfo: buildInfo)
        }
        
        print("Package built successfully: \(outputPath)")
    }
    
    /// Load environment variables from .env file
    /// - Parameter projectURL: URL to the project directory
    /// - Returns: Dictionary of environment variable key-value pairs
    private func loadEnvironmentVariables(for projectURL: URL) throws -> [String: String] {
        // Determine which .env file to use
        let envFilePath: String
        if let customEnvPath = buildOptions.env {
            // Use explicitly specified path
            envFilePath = customEnvPath
            if !FileManager.default.fileExists(atPath: envFilePath) {
                throw MunkiPkgError("Specified environment file does not exist: \(envFilePath)")
            }
        } else {
            // Auto-detect .env in project directory
            envFilePath = projectURL.appendingPathComponent(".env").path
        }
        
        // Load variables from file
        let envFileVars = try EnvLoader.load(from: envFilePath)
        
        // Merge with system environment (MUNKIPKG_ prefixed only)
        return EnvLoader.merge(envFileVars: envFileVars, includeSysEnv: true)
    }
    
    private func loadBuildInfo(from projectURL: URL) throws -> BuildInfo {
        // Try different build-info file formats
        let possiblePaths = [
            projectURL.appendingPathComponent("build-info.plist"),
            projectURL.appendingPathComponent("build-info.json"),
            projectURL.appendingPathComponent("build-info.yaml")
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return try BuildInfo(fromFile: path.path)
            }
        }
        
        throw MunkiPkgError.invalidProject("No build-info file found")
    }
    
    private func performBuild(projectURL: URL, buildInfo: BuildInfo, envVars: [String: String] = [:]) async throws -> String {
        // Create build directory
        let buildDir = projectURL.appendingPathComponent("build")
        if !FileManager.default.fileExists(atPath: buildDir.path) {
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        }
        
        // Create temp directory for component plist, pkginfo, and processed scripts if needed
        let tempDir = buildDir.appendingPathComponent("tmp")
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Generate component property list if needed
        let componentPlistPath = try await makeComponentPropertyList(buildInfo: buildInfo, tempDir: tempDir)
        
        // Generate PackageInfo if needed
        let pkginfoPath = try makePkgInfo(buildInfo: buildInfo, tempDir: tempDir)
        
        let packageName = buildInfo.name.hasSuffix(".pkg") ? buildInfo.name : "\(buildInfo.name).pkg"
        let componentPackagePath = buildDir.appendingPathComponent(packageName).path
        
        // Build component package with pkgbuild
        var pkgbuildArgs = [
            "--root", projectURL.appendingPathComponent("payload").path,
            "--identifier", buildInfo.identifier,
            "--version", buildInfo.version
        ]
        
        // Add component plist if we created one
        if let componentPlist = componentPlistPath {
            pkgbuildArgs.append(contentsOf: ["--component-plist", componentPlist.path])
        }
        
        // Add pkginfo if we created one
        if let pkginfo = pkginfoPath {
            pkgbuildArgs.append(contentsOf: ["--info", pkginfo.path])
        }
        
        // Add install location if specified
        if let installLocation = buildInfo.installLocation {
            pkgbuildArgs.append(contentsOf: ["--install-location", installLocation])
        }
        
        // Add ownership if specified
        if let ownership = buildInfo.ownership {
            pkgbuildArgs.append(contentsOf: ["--ownership", ownership.rawValue])
        }
        
        // Add scripts if they exist - process with env var substitution if needed
        let scriptsPath = projectURL.appendingPathComponent("scripts").path
        if FileManager.default.fileExists(atPath: scriptsPath) {
            // If we have environment variables, process scripts with placeholder replacement
            if !envVars.isEmpty {
                if let processedScriptsPath = try PlaceholderReplacer.processScriptsDirectory(
                    at: scriptsPath,
                    with: envVars,
                    tempDir: tempDir.path
                ) {
                    if !additionalOptions.quiet {
                        print("munkipkg: Processed scripts with environment variable substitution")
                    }
                    pkgbuildArgs.append(contentsOf: ["--scripts", processedScriptsPath])
                } else {
                    // No scripts needed processing, use original
                    pkgbuildArgs.append(contentsOf: ["--scripts", scriptsPath])
                }
            } else {
                // No env vars, use original scripts
                pkgbuildArgs.append(contentsOf: ["--scripts", scriptsPath])
            }
        }
        
        pkgbuildArgs.append(componentPackagePath)
        
        if !additionalOptions.quiet {
            print("pkgbuild: Building component package...")
        }
        
        let pkgbuildResult = await runCliAsync("/usr/bin/pkgbuild", arguments: pkgbuildArgs)
        
        if pkgbuildResult.exitCode != 0 {
            throw MunkiPkgError.buildFailed("pkgbuild failed: \(pkgbuildResult.stderr)")
        }
        
        if !additionalOptions.quiet {
            print(pkgbuildResult.stdout, terminator: "")
            print(pkgbuildResult.stderr, terminator: "")
        }
        
        var finalPackagePath = componentPackagePath
        
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
                if !additionalOptions.quiet {
                    print("\nmunkipkg: Adding package signing info to command")
                }
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
            
            if !additionalOptions.quiet {
                print("productbuild: Creating distribution package...")
            }
            
            let productbuildResult = await runCliAsync("/usr/bin/productbuild", arguments: productbuildArgs)
            
            // Always print output even if there's an error
            if !additionalOptions.quiet || productbuildResult.exitCode != 0 {
                print(productbuildResult.stdout, terminator: "")
                print(productbuildResult.stderr, terminator: "")
            }
            
            if productbuildResult.exitCode != 0 {
                throw MunkiPkgError.buildFailed("productbuild failed with exit code \(productbuildResult.exitCode)")
            }
            
            // Remove component package
            if !additionalOptions.quiet {
                print("\nmunkipkg: Removing component package \(componentPackagePath)")
            }
            try FileManager.default.removeItem(atPath: componentPackagePath)
            
            // Rename distribution package
            if !additionalOptions.quiet {
                print("munkipkg: Renaming distribution package \(distPackagePath) to \(componentPackagePath)")
            }
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
                if !additionalOptions.quiet {
                    print("munkipkg: Notarization info incomplete - need either keychain_profile or apple_id+team_id+password")
                }
                throw MunkiPkgError("Incomplete notarization authentication information")
            }
            
            notarizeArgs.append("--wait")
            
            if !additionalOptions.quiet {
                print("munkipkg: Uploading package to Apple notary service")
            }
            
            let notarizeResult = await runCliAsync("/usr/bin/xcrun", arguments: notarizeArgs)
            
            // Always print output
            if !additionalOptions.quiet {
                print(notarizeResult.stdout, terminator: "")
                if !notarizeResult.stderr.isEmpty {
                    print(notarizeResult.stderr, terminator: "")
                }
            }
            
            // Check if notarization was successful by looking for "Accepted" status
            let notarizationSucceeded = notarizeResult.exitCode == 0 && 
                                        notarizeResult.stdout.contains("status: Accepted")
            
            if notarizeResult.exitCode != 0 {
                if !additionalOptions.quiet {
                    print("munkipkg: Notarization submission failed")
                }
            } else if !notarizationSucceeded {
                if !additionalOptions.quiet {
                    print("munkipkg: Notarization completed but package was not accepted")
                    if notarizeResult.stdout.contains("status: Invalid") {
                        print("munkipkg: Package notarization returned Invalid status")
                    }
                }
            } else {
                if !additionalOptions.quiet {
                    print("munkipkg: Successfully received submission info")
                }
                
                // Staple if not skipped and notarization was successful
                if !buildOptions.skipStapling {
                    if !additionalOptions.quiet {
                        print("munkipkg: Stapling package")
                    }
                    
                    let stapleResult = await runCliAsync("/usr/bin/xcrun", arguments: [
                        "stapler", "staple", finalPackagePath
                    ])
                    
                    if stapleResult.exitCode == 0 {
                        if !additionalOptions.quiet {
                            print("munkipkg: The staple and validate action worked!")
                        }
                    } else {
                        if !additionalOptions.quiet {
                            print("munkipkg: Stapling failed: \(stapleResult.stderr)")
                        }
                    }
                }
            }
        }
        
        return finalPackagePath
    }
    
    private func exportBom(for projectURL: URL, buildInfo: BuildInfo) async throws {
        let payloadPath = projectURL.appendingPathComponent("payload").path
        let bomPath = projectURL.appendingPathComponent("Bom.txt").path
        
        let result = await runCliAsync("/usr/bin/lsbom", arguments: ["-p", "MUGsf", payloadPath])
        
        if result.exitCode == 0 {
            try result.stdout.write(toFile: bomPath, atomically: true, encoding: String.Encoding.utf8)
            print("BOM info exported to: \(bomPath)")
        }
    }
}
