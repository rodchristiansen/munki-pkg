//
//  envloader.swift
//  munkipkg
//
//  Environment variable loader for injecting secrets into pre/postinstall scripts
//

import Foundation

/// Error type for environment loading failures
public final class EnvLoadError: MunkiPkgError, @unchecked Sendable {
    public override init(_ message: String = "Environment loading error", exitCode: Int = 1) {
        super.init(message, exitCode: exitCode)
    }
}

/// Loads and manages environment variables from .env files
public struct EnvLoader: Sendable {
    
    /// Load environment variables from a .env file
    /// - Parameter path: Path to the .env file
    /// - Returns: Dictionary of environment variable key-value pairs
    /// - Throws: EnvLoadError if file cannot be read (but silently returns empty dict for missing files)
    public static func load(from path: String) throws -> [String: String] {
        var envVars: [String: String] = [:]
        
        // Check if file exists - silently return empty dict if not
        guard FileManager.default.fileExists(atPath: path) else {
            return envVars
        }
        
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw EnvLoadError("Failed to read environment file: \(path)")
        }
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines and comments
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }
            
            // Parse KEY=VALUE or KEY='VALUE' or KEY="VALUE"
            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                // No equals sign - skip line
                continue
            }
            
            let key = String(trimmedLine[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmedLine[trimmedLine.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            
            // Validate key is not empty
            guard !key.isEmpty else {
                continue
            }
            
            // Remove surrounding quotes if present
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                if value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
            }
            
            envVars[key] = value
        }
        
        return envVars
    }
    
    /// Load environment variables from a .env file in a project directory
    /// Auto-detects .env file in the project root
    /// - Parameter projectDir: Path to the project directory
    /// - Returns: Dictionary of environment variable key-value pairs
    public static func loadFromProject(at projectDir: String) throws -> [String: String] {
        let envPath = (projectDir as NSString).appendingPathComponent(".env")
        return try load(from: envPath)
    }
    
    /// Merge environment variables from multiple sources
    /// Priority: .env file values > system environment (MUNKIPKG_ prefixed only)
    /// - Parameters:
    ///   - envFileVars: Variables loaded from .env file
    ///   - includeSysEnv: Whether to include system environment variables
    /// - Returns: Merged dictionary of environment variables
    public static func merge(envFileVars: [String: String], includeSysEnv: Bool = true) -> [String: String] {
        var result: [String: String] = [:]
        
        // Start with system environment if requested (only MUNKIPKG_ prefixed vars)
        if includeSysEnv {
            for (key, value) in ProcessInfo.processInfo.environment {
                // Only include munkipkg-related environment variables from system
                if key.hasPrefix("MUNKIPKG_") {
                    result[key] = value
                }
            }
        }
        
        // Override with .env file variables (highest priority)
        for (key, value) in envFileVars {
            result[key] = value
        }
        
        return result
    }
}

/// Handles placeholder replacement in script content
public struct PlaceholderReplacer: Sendable {
    
    /// Replace placeholders in script content with environment variable values
    /// Supports multiple patterns:
    /// 1. Shell: ${VARIABLE_NAME} -> looks for env var VARIABLE_NAME
    /// 2. Bash: $VARIABLE_NAME -> looks for env var VARIABLE_NAME (word boundary)
    /// 3. Legacy: VARIABLE_NAME_PLACEHOLDER -> looks for env var VARIABLE_NAME
    /// 4. Mustache-style: {{VARIABLE_NAME}} -> looks for env var VARIABLE_NAME
    /// - Parameters:
    ///   - content: The script content to process
    ///   - envVars: Dictionary of environment variable values
    /// - Returns: Content with placeholders replaced
    public static func replace(in content: String, with envVars: [String: String]) -> String {
        var result = content
        
        for (key, value) in envVars {
            guard !value.isEmpty else { continue }
            
            // Pattern 1: Shell style ${VARIABLE_NAME}
            let shellPattern = "${\(key)}"
            result = result.replacingOccurrences(of: shellPattern, with: value)
            
            // Pattern 2: Mustache style {{VARIABLE_NAME}}
            let mustachePattern = "{{\(key)}}"
            result = result.replacingOccurrences(of: mustachePattern, with: value)
            
            // Pattern 3: Legacy placeholder pattern: VARIABLE_NAME_PLACEHOLDER
            let legacyPattern = "\(key)_PLACEHOLDER"
            result = result.replacingOccurrences(of: legacyPattern, with: value)
            
            // Pattern 4: XML/plist safe pattern: __VARIABLE_NAME__
            let xmlSafePattern = "__\(key)__"
            result = result.replacingOccurrences(of: xmlSafePattern, with: value)
        }
        
        return result
    }
    
    /// Process all scripts in a directory, replacing placeholders
    /// Creates processed versions in a temporary location
    /// - Parameters:
    ///   - scriptsDir: Path to the scripts directory
    ///   - envVars: Dictionary of environment variable values
    ///   - tempDir: Temporary directory to write processed scripts
    /// - Returns: Path to the temporary scripts directory (or nil if no scripts processed)
    public static func processScriptsDirectory(
        at scriptsDir: String,
        with envVars: [String: String],
        tempDir: String
    ) throws -> String? {
        let fileManager = FileManager.default
        let scriptsDirURL = URL(fileURLWithPath: scriptsDir)
        let tempScriptsDir = (tempDir as NSString).appendingPathComponent("scripts")
        
        // Check if scripts directory exists
        guard fileManager.fileExists(atPath: scriptsDir) else {
            return nil
        }
        
        // Get list of scripts
        guard let contents = try? fileManager.contentsOfDirectory(atPath: scriptsDir) else {
            return nil
        }
        
        // Filter for script files we care about
        let scriptNames = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preexpansion"]
        let scriptsToProcess = contents.filter { filename in
            scriptNames.contains(filename) || filename.hasSuffix(".sh") || filename.hasSuffix(".py")
        }
        
        // If no env vars and no scripts, nothing to do
        if envVars.isEmpty || scriptsToProcess.isEmpty {
            return nil
        }
        
        // Create temp scripts directory
        try fileManager.createDirectory(atPath: tempScriptsDir, withIntermediateDirectories: true)
        
        // Process each script
        for scriptName in scriptsToProcess {
            let sourcePath = scriptsDirURL.appendingPathComponent(scriptName).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(scriptName)
            
            // Read script content
            guard let data = fileManager.contents(atPath: sourcePath),
                  let content = String(data: data, encoding: .utf8) else {
                // If we can't read as text, just copy the file
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                continue
            }
            
            // Replace placeholders
            let processedContent = replace(in: content, with: envVars)
            
            // Write processed script
            try processedContent.write(toFile: destPath, atomically: true, encoding: .utf8)
            
            // Preserve execute permissions
            let attrs = try fileManager.attributesOfItem(atPath: sourcePath)
            if let permissions = attrs[.posixPermissions] as? Int {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destPath)
            } else {
                // Default to executable
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
            }
        }
        
        // Copy any remaining files from scripts dir that we didn't process
        for item in contents where !scriptsToProcess.contains(item) {
            let sourcePath = scriptsDirURL.appendingPathComponent(item).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(item)
            try? fileManager.copyItem(atPath: sourcePath, toPath: destPath)
        }
        
        return tempScriptsDir
    }
}
