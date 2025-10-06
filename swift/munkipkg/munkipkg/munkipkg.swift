//
//  munkipkg.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/3/25.
//

import ArgumentParser
import Foundation

let GITIGNORE_DEFAULT = """
.DS_Store
build/
"""

func printStderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
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

    @OptionGroup(title: "Additional options")
    var additionalOptions: AdditionalOptions

    mutating func validate() throws {
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
        do {
            // Handle different actions
            if actionOptions.create {
                try createPackageProject()
            } else if let importPath = actionOptions.importPath {
                try await importPackage(from: importPath)
            } else if actionOptions.sync {
                try await syncPackageProject()
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
        
        // Create default .gitignore
        try createDefaultGitignore(at: projectURL)
        
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
    
    // MARK: - Sync functionality
    private func syncPackageProject() async throws {
        let projectPath = actionOptions.projectPath
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Validate project exists
        guard FileManager.default.fileExists(atPath: projectPath) else {
            throw MunkiPkgError.invalidProject("Project directory does not exist: \(projectPath)")
        }
        
        try await syncFromBomInfo(projectURL: projectURL)
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
        
        // Sync from BOM if it exists
        let bomPath = projectURL.appendingPathComponent("Bom.txt")
        if FileManager.default.fileExists(atPath: bomPath.path) {
            try await syncFromBomInfo(projectURL: projectURL)
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
        // Create build directory
        let buildDir = projectURL.appendingPathComponent("build")
        if !FileManager.default.fileExists(atPath: buildDir.path) {
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        }
        
        let packageName = buildInfo.name.hasSuffix(".pkg") ? buildInfo.name : "\(buildInfo.name).pkg"
        let componentPackagePath = buildDir.appendingPathComponent(packageName).path
        
        // Build component package with pkgbuild
        var pkgbuildArgs = [
            "--root", projectURL.appendingPathComponent("payload").path,
            "--identifier", buildInfo.identifier,
            "--version", buildInfo.version
        ]
        
        // Add install location if specified
        if let installLocation = buildInfo.installLocation {
            pkgbuildArgs.append(contentsOf: ["--install-location", installLocation])
        }
        
        // Add ownership if specified
        if let ownership = buildInfo.ownership {
            pkgbuildArgs.append(contentsOf: ["--ownership", ownership.rawValue])
        }
        
        // Add scripts if they exist
        let scriptsPath = projectURL.appendingPathComponent("scripts").path
        if FileManager.default.fileExists(atPath: scriptsPath) {
            pkgbuildArgs.append(contentsOf: ["--scripts", scriptsPath])
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
                    print("munkipkg: Adding package signing info to command")
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
                if let additionalCertNames = signingInfo.additionalCertNames {
                    for certName in additionalCertNames {
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
                print("munkipkg: Removing component package \(componentPackagePath)")
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
            
            if !additionalOptions.quiet {
                print("munkipkg: Uploading package to Apple notary service")
            }
            
            // Build notarization arguments based on authentication method
            var notarizeArgs = ["notarytool", "submit", finalPackagePath]
            
            if let keychainProfile = notarizationInfo.keychainProfile {
                // Use keychain profile authentication
                notarizeArgs.append(contentsOf: ["--keychain-profile", keychainProfile])
            } else if let appleId = notarizationInfo.appleId,
                      let teamId = notarizationInfo.teamId,
                      let password = notarizationInfo.password {
                // Use Apple ID authentication
                notarizeArgs.append(contentsOf: [
                    "--apple-id", appleId,
                    "--team-id", teamId,
                    "--password", password
                ])
                
                // Add ASC provider if specified
                if let ascProvider = notarizationInfo.ascProvider {
                    notarizeArgs.append(contentsOf: ["--asc-provider", ascProvider])
                }
            } else {
                if !additionalOptions.quiet {
                    print("munkipkg: Notarization info incomplete - skipping notarization")
                }
                return finalPackagePath
            }
            
            notarizeArgs.append("--wait")
            
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
    
    private func createDefaultGitignore(at projectURL: URL) throws {
        let gitignorePath = projectURL.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignorePath.path) {
            try GITIGNORE_DEFAULT.write(to: gitignorePath, atomically: true, encoding: .utf8)
            if !additionalOptions.quiet {
                print("Created default .gitignore")
            }
        }
    }
    
    private func analyzePermissionsInBom(bomPath: String) async -> [String: [String: Any]] {
        let result = await runCliAsync("/usr/bin/lsbom", arguments: ["-p", "MUGsf", bomPath])
        
        var permissionsMap: [String: [String: Any]] = [:]
        
        if result.exitCode == 0 {
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            for line in lines {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 5 {
                    let filePath = parts[0]
                    let mode = parts[1]
                    let uid = parts[2]
                    let gid = parts[3]
                    let size = parts[4]
                    
                    permissionsMap[filePath] = [
                        "mode": mode,
                        "uid": uid,
                        "gid": gid,
                        "size": size
                    ]
                }
            }
        }
        
        return permissionsMap
    }
    
    private func syncFromBomInfo(projectURL: URL) async throws {
        let bomPath = projectURL.appendingPathComponent("Bom.txt").path
        
        guard FileManager.default.fileExists(atPath: bomPath) else {
            throw MunkiPkgError.missingBomFile("Cannot sync from BOM: Bom.txt does not exist")
        }
        
        // Read and analyze permissions from BOM (analysis is used for logging/validation)
        _ = await analyzePermissionsInBom(bomPath: bomPath)
        
        // Read the entire Bom.txt file
        let bomContent = try String(contentsOfFile: bomPath, encoding: .utf8)
        let lines = bomContent.components(separatedBy: "\n")
        
        let payloadDir = projectURL.appendingPathComponent("payload")
        let fileManager = FileManager.default
        
        // Track actual owner/group for ownership recommendation
        var ownerCounts: [String: Int] = [:]
        
        for line in lines {
            guard !line.isEmpty else { continue }
            
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            
            let relativePath = parts[0]
            let permissions = parts[1]
            let uid = parts[2]
            let gid = parts[3]
            
            // Track owner/group occurrences
            let ownerKey = "\(uid)/\(gid)"
            ownerCounts[ownerKey, default: 0] += 1
            
            // Skip directories - we only want to track files for ownership
            if !permissions.hasPrefix("d") {
                ownerCounts[ownerKey, default: 0] += 1
            }
            
            let fullPath = payloadDir.appendingPathComponent(relativePath)
            
            // Skip if the file/directory doesn't exist
            guard fileManager.fileExists(atPath: fullPath.path) else {
                continue
            }
            
            // Try to apply the permissions
            do {
                // Convert permissions from octal string
                if permissions.count >= 4 {
                    // Remove the first character (file type) if present
                    let permString = permissions.hasPrefix("0") ? permissions : String(permissions.dropFirst())
                    
                    if let octalValue = Int(permString, radix: 8) {
                        let attributes: [FileAttributeKey: Any] = [
                            .posixPermissions: octalValue
                        ]
                        try fileManager.setAttributes(attributes, ofItemAtPath: fullPath.path)
                    }
                }
                
                // Note: We're not setting ownership here as that would require root
                // The BOM file documents the intended ownership
            } catch {
                if !additionalOptions.quiet {
                    printStderr("Warning: Could not set permissions for \(relativePath): \(error.localizedDescription)")
                }
            }
        }
        
        // Determine most common owner/group
        if let mostCommonOwner = ownerCounts.max(by: { $0.value < $1.value })?.key {
            let parts = mostCommonOwner.components(separatedBy: "/")
            if parts.count == 2 {
                let uid = parts[0]
                let gid = parts[1]
                
                // Only show recommendation if not root/wheel (0/0)
                if uid != "0" || gid != "0" {
                    if !additionalOptions.quiet {
                        print("\nRecommendation: Most files are owned by \(uid):\(gid)")
                        print("Consider adding ownership info to build-info:")
                        print("  \"ownership\": \"recommended\"")
                    }
                }
            }
        }
        
        if !additionalOptions.quiet {
            print("Synchronized permissions from Bom.txt to payload directory")
        }
    }
}
