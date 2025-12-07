//
//  MPKconvert.swift
//  munkipkg
//
//  Created by Rod Christiansen on 12/6/25.
//
//  Copyright 2025 The Munki Project
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//       https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import Foundation

// MARK: - Convert functionality
extension MunkiPkg {
    
    func convertBuildInfo() throws {
        let projectPath = actionOptions.projectPath
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Determine target format
        let targetFormat: String
        if convertOptions.toYaml {
            targetFormat = "yaml"
        } else if convertOptions.toPlist {
            targetFormat = "plist"
        } else {
            targetFormat = "json"
        }
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory) else {
            throw MunkiPkgError.invalidProject("Path does not exist: \(projectPath)")
        }
        
        guard isDirectory.boolValue else {
            throw MunkiPkgError.invalidProject("Path must be a directory: \(projectPath)")
        }
        
        // Check if this is a single project or parent directory
        if isPackageProject(at: projectURL) {
            // Single project
            try convertSingleProject(at: projectURL, to: targetFormat)
        } else {
            // Parent directory - convert all subprojects
            try convertAllProjects(in: projectURL, to: targetFormat)
        }
    }
    
    private func isPackageProject(at projectURL: URL) -> Bool {
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
    
    private func convertSingleProject(at projectURL: URL, to targetFormat: String) throws {
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
        
        if convertOptions.dryRun {
            print("Would convert \(projectURL.lastPathComponent): \(sourceFormat) → \(normalizedTarget)")
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
            print("✓ Converted \(projectURL.lastPathComponent): \(sourceFormat) → \(normalizedTarget)")
        }
    }
    
    private func convertAllProjects(in parentURL: URL, to targetFormat: String) throws {
        let fileManager = FileManager.default
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MunkiPkgError.invalidProject("Cannot read directory: \(parentURL.path)")
        }
        
        var convertedCount = 0
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
                    let wasAlreadyInFormat = checkIfAlreadyInFormat(at: itemURL, format: targetFormat)
                    try convertSingleProject(at: itemURL, to: targetFormat)
                    if wasAlreadyInFormat {
                        skippedCount += 1
                    } else {
                        convertedCount += 1
                    }
                } catch {
                    errorCount += 1
                    if !additionalOptions.quiet {
                        FileHandle.standardError.write(Data("✗ Failed to convert \(itemURL.lastPathComponent): \(error.localizedDescription)\n".utf8))
                    }
                }
            }
        }
        
        if !additionalOptions.quiet {
            print("\nConversion Summary:")
            print("  Converted: \(convertedCount) project(s)")
            if skippedCount > 0 {
                print("  Already in target format: \(skippedCount) project(s)")
            }
            if errorCount > 0 {
                print("  Errors: \(errorCount) project(s)")
            }
            
            if convertOptions.dryRun {
                print("\n(This was a dry run - no files were actually modified)")
            }
        }
        
        if convertedCount == 0 && skippedCount == 0 && errorCount == 0 {
            throw MunkiPkgError.invalidProject("No package projects found in: \(parentURL.path)")
        }
    }
    
    private func checkIfAlreadyInFormat(at projectURL: URL, format: String) -> Bool {
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
}
