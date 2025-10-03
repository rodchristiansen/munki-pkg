//
//  munkipkg.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import Foundation

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
            } else if let targetFormat = actionOptions.migrate {
                try migrateBuildInfo(to: targetFormat)
            } else if actionOptions.build {
                try await buildPackage()
            } else {
                // Default action - provide help
                print(MunkiPkg.helpMessage())
            }
        } catch let error as MunkiPkgError {
            throw ExitCode(Int32(error.exitCode))
        }
    }
    
    // MARK: - Migration functionality
    
    private func migrateBuildInfo(to targetFormat: String) throws {
        let projectPath = actionOptions.projectPath
        let projectURL = URL(fileURLWithPath: projectPath)
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory) else {
            throw MunkiPkgError.invalidProject("Path does not exist: \(projectPath)")
        }
        
        if isDirectory.boolValue {
            // Check if this is a single project or parent directory
            if isPackageProject(at: projectURL) {
                // Single project
                try migrateSingleProject(at: projectURL, to: targetFormat)
            } else {
                // Parent directory - migrate all subprojects
                try migrateAllProjects(in: projectURL, to: targetFormat)
            }
        } else {
            throw MunkiPkgError.invalidProject("Path must be a directory: \(projectPath)")
        }
    }
    
    private func isPackageProject(at projectURL: URL) -> Bool {
        // A package project should have a build-info file
        let fileManager = FileManager.default
        let formats = ["plist", "json", "yaml", "yml"]
        
        for format in formats {
            let buildInfoPath = projectURL.appendingPathComponent("build-info.\(format)")
            if fileManager.fileExists(atPath: buildInfoPath.path) {
                return true
            }
        }
        
        return false
    }
    
    private func migrateSingleProject(at projectURL: URL, to targetFormat: String) throws {
        let fileManager = FileManager.default
        
        // Find existing build-info file
        let formats = ["plist", "json", "yaml", "yml"]
        var existingFormat: String?
        var existingPath: URL?
        
        for format in formats {
            let buildInfoPath = projectURL.appendingPathComponent("build-info.\(format)")
            if fileManager.fileExists(atPath: buildInfoPath.path) {
                existingFormat = format
                existingPath = buildInfoPath
                break
            }
        }
        
        guard let sourceFormat = existingFormat, let sourcePath = existingPath else {
            throw MunkiPkgError.invalidProject("No build-info file found in: \(projectURL.path)")
        }
        
        // Normalize target format (yml -> yaml)
        let normalizedTarget = targetFormat.lowercased() == "yml" ? "yaml" : targetFormat.lowercased()
        
        // Check if already in target format
        if sourceFormat == normalizedTarget || (sourceFormat == "yml" && normalizedTarget == "yaml") {
            if !additionalOptions.quiet {
                print("✓ \(projectURL.lastPathComponent) already in \(targetFormat) format")
            }
            return
        }
        
        // Load the build info
        let buildInfo = try BuildInfo(fromFile: sourcePath.path)
        
        // Create new file path
        let targetPath = projectURL.appendingPathComponent("build-info.\(normalizedTarget)")
        
        // Write in new format
        let content: String
        switch normalizedTarget {
        case "plist":
            content = try buildInfo.plistString()
        case "json":
            content = try buildInfo.jsonString()
        case "yaml":
            content = try buildInfo.yamlString()
        default:
            throw MunkiPkgError("Invalid target format: \(targetFormat)")
        }
        
        try content.write(to: targetPath, atomically: true, encoding: .utf8)
        
        // Remove old file if different
        if sourcePath != targetPath {
            try fileManager.removeItem(at: sourcePath)
        }
        
        if !additionalOptions.quiet {
            print("✓ Migrated \(projectURL.lastPathComponent): \(sourceFormat) → \(normalizedTarget)")
        }
    }
    
    private func migrateAllProjects(in parentURL: URL, to targetFormat: String) throws {
        let fileManager = FileManager.default
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MunkiPkgError.invalidProject("Cannot read directory: \(parentURL.path)")
        }
        
        var migratedCount = 0
        var skippedCount = 0
        var errorCount = 0
        
        for itemURL in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            
            // Check if this subdirectory is a package project
            if isPackageProject(at: itemURL) {
                do {
                    let wasAlreadyInFormat = try checkIfAlreadyInFormat(at: itemURL, format: targetFormat)
                    try migrateSingleProject(at: itemURL, to: targetFormat)
                    if wasAlreadyInFormat {
                        skippedCount += 1
                    } else {
                        migratedCount += 1
                    }
                } catch {
                    errorCount += 1
                    if !additionalOptions.quiet {
                        print("✗ Failed to migrate \(itemURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        
        if !additionalOptions.quiet {
            print("\nMigration Summary:")
            print("  Migrated: \(migratedCount) project(s)")
            if skippedCount > 0 {
                print("  Already in target format: \(skippedCount) project(s)")
            }
            if errorCount > 0 {
                print("  Errors: \(errorCount) project(s)")
            }
        }
        
        if migratedCount == 0 && skippedCount == 0 && errorCount == 0 {
            throw MunkiPkgError.invalidProject("No package projects found in: \(parentURL.path)")
        }
    }
    
    private func checkIfAlreadyInFormat(at projectURL: URL, format: String) throws -> Bool {
        let fileManager = FileManager.default
        let normalizedFormat = format.lowercased() == "yml" ? "yaml" : format.lowercased()
        
        let formats = ["plist", "json", "yaml", "yml"]
        for fmt in formats {
            let buildInfoPath = projectURL.appendingPathComponent("build-info.\(fmt)")
            if fileManager.fileExists(atPath: buildInfoPath.path) {
                return fmt == normalizedFormat || (fmt == "yml" && normalizedFormat == "yaml")
            }
        }
        
        return false
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
    
    // MARK: - Build functionality
    private func buildPackage() async throws {
        let projectPath = actionOptions.projectPath
        
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Load build info
        let buildInfo = try loadBuildInfo(from: projectURL)
        
        // Build the package
        let outputPath = try await performBuild(projectURL: projectURL, buildInfo: buildInfo)
        
        if buildOptions.exportBomInfo {
            try await exportBom(for: projectURL, buildInfo: buildInfo)
        }
        
        print("Package built successfully: \(outputPath)")
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
    
    private func performBuild(projectURL: URL, buildInfo: BuildInfo) async throws -> String {
        let outputFilename = "\(buildInfo.name)-\(buildInfo.version).pkg"
        let outputPath = projectURL.appendingPathComponent(outputFilename).path
        
        // Use pkgbuild to create the package
        var arguments = [
            "--root", projectURL.appendingPathComponent("payload").path,
            "--identifier", buildInfo.identifier,
            "--version", buildInfo.version,
            outputPath
        ]
        
        // Add scripts if they exist
        let scriptsPath = projectURL.appendingPathComponent("scripts").path
        if FileManager.default.fileExists(atPath: scriptsPath) {
            arguments.insert(contentsOf: ["--scripts", scriptsPath], at: arguments.count - 1)
        }
        
        let result = await runCliAsync("/usr/bin/pkgbuild", arguments: arguments)
        
        if result.exitCode != 0 {
            throw MunkiPkgError.buildFailed("Package build failed: \(result.stderr)")
        }
        
        return outputPath
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
