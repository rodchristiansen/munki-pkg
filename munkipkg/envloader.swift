//
//  envloader.swift
//  munkipkg
//
//  Build-time variable substitution for pre/postinstall scripts.
//
//  IMPORTANT: substituted values are embedded verbatim in scripts, which end up
//  as plain text inside the resulting .pkg. Anyone with the package file can read
//  them via `pkgutil --expand`. This is for build-time variables (server URLs,
//  org identifiers, version metadata) — NOT for secrets. For runtime secrets,
//  fetch from Keychain or an MDM-delivered profile inside the script itself.
//

import Foundation

/// Error type for environment loading failures
public final class EnvLoadError: MunkiPkgError, @unchecked Sendable {
    public override init(_ message: String = "Environment loading error", exitCode: Int = 1) {
        super.init(message, exitCode: exitCode)
    }
}

/// Result of merging .env values with system environment.
public struct EnvMergeResult: Sendable {
    public let vars: [String: String]
    /// Names (only) of MUNKIPKG_* keys picked up from the calling process environment.
    public let systemEnvKeys: [String]
}

/// Loads and merges build-time variables from `.env` files.
public struct EnvLoader: Sendable {

    /// Maximum size for a .env file (1 MB). Larger files are rejected.
    public static let maxFileSize: Int = 1_048_576

    /// Load variables from a `.env` file.
    /// - Parameters:
    ///   - path: Path to the file.
    ///   - warnOnPermissiveMode: If true, prints a stderr warning when the file is
    ///     group- or world-readable. Defaults to true.
    /// - Returns: Dictionary of key/value pairs. Returns empty dict if the file does
    ///   not exist; callers that need a hard error on a missing explicitly-specified
    ///   path should check existence themselves before calling.
    /// - Throws: `EnvLoadError` if the file exists but can't be read or exceeds the
    ///   size limit.
    public static func load(from path: String, warnOnPermissiveMode: Bool = true) throws -> [String: String] {
        var envVars: [String: String] = [:]

        guard FileManager.default.fileExists(atPath: path) else {
            return envVars
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw EnvLoadError("Failed to read attributes of environment file: \(path)")
        }

        if let size = attrs[.size] as? Int, size > maxFileSize {
            throw EnvLoadError("Environment file exceeds maximum size of \(maxFileSize) bytes: \(path)")
        }

        if warnOnPermissiveMode, let perms = attrs[.posixPermissions] as? Int {
            let groupReadable = (perms & 0o040) != 0
            let worldReadable = (perms & 0o004) != 0
            if groupReadable || worldReadable {
                let octal = String(perms, radix: 8)
                let msg = "WARNING: environment file \(path) has permissive mode 0\(octal) (group- or world-readable). Recommend `chmod 600 \(path)`.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw EnvLoadError("Failed to read environment file: \(path)")
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let rawKey = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            guard !rawKey.isEmpty else { continue }

            // Key shape must match placeholder identifier syntax. Anything else
            // (shell-special chars, whitespace, leading digit) is skipped with a
            // warning rather than silently accepted — keys with funny characters
            // can't be referenced from a placeholder anyway.
            if rawKey.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                let msg = "WARNING: skipping environment entry with invalid key: '\(rawKey)'\n"
                FileHandle.standardError.write(Data(msg.utf8))
                continue
            }

            if value.count >= 2 {
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
            }

            envVars[rawKey] = value
        }

        return envVars
    }

    /// Load variables from a `.env` file inside a project directory.
    public static func loadFromProject(at projectDir: String) throws -> [String: String] {
        let envPath = (projectDir as NSString).appendingPathComponent(".env")
        return try load(from: envPath)
    }

    /// Merge `.env` file values with selected system-environment variables.
    /// `.env` values take precedence over system env vars with the same key.
    /// - Parameters:
    ///   - envFileVars: Variables loaded from a `.env` file.
    ///   - includeSysEnv: If true, MUNKIPKG_* prefixed vars from the calling process
    ///     environment are merged in.
    public static func merge(envFileVars: [String: String], includeSysEnv: Bool = true) -> EnvMergeResult {
        var result: [String: String] = [:]
        var sysKeys: [String] = []

        if includeSysEnv {
            for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("MUNKIPKG_") {
                result[key] = value
                sysKeys.append(key)
            }
        }

        for (key, value) in envFileVars {
            result[key] = value
        }

        return EnvMergeResult(vars: result, systemEnvKeys: sysKeys.sorted())
    }
}

/// Replaces build-time variable placeholders in script content.
///
/// Substitution is performed in a single scan over the source: each placeholder
/// in the script is replaced exactly once, so a value containing placeholder
/// syntax is NOT re-expanded against another key's value (the cross-variable
/// leakage that existed in the previous multi-pass implementation).
public struct PlaceholderReplacer: Sendable {

    public struct Result: Sendable {
        public let content: String
        /// Placeholder names that appeared in the script but had no matching env var.
        public let unresolved: Set<String>
    }

    public struct DirectoryResult: Sendable {
        public let scriptsDir: String
        /// Map of script filename → set of placeholder names that were not resolved.
        public let unresolvedByScript: [String: Set<String>]
    }

    // Single regex matching any supported placeholder pattern.
    // Capture groups 1-4 correspond to: ${VAR}, {{VAR}}, __VAR__, VAR_PLACEHOLDER.
    // VAR_PLACEHOLDER uses look-around to avoid matching mid-identifier (e.g.
    // XFOO_PLACEHOLDER should not be matched as FOO_PLACEHOLDER).
    private static let combinedPattern: NSRegularExpression = {
        let pattern =
            #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"# +
            #"|\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"# +
            #"|__([A-Za-z_][A-Za-z0-9_]*)__"# +
            #"|(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)_PLACEHOLDER(?![A-Za-z0-9_])"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    public static func replace(in content: String, with envVars: [String: String]) -> Result {
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = combinedPattern.matches(in: content, range: fullRange)

        if matches.isEmpty {
            return Result(content: content, unresolved: [])
        }

        let output = NSMutableString()
        var cursor = 0
        var unresolved: Set<String> = []

        for match in matches {
            let r = match.range
            if r.location > cursor {
                output.append(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }

            // Find which capture group matched (one of 1-4) and extract the key.
            var key: String?
            for i in 1...4 {
                let g = match.range(at: i)
                if g.location != NSNotFound {
                    key = ns.substring(with: g)
                    break
                }
            }

            let placeholder = ns.substring(with: r)
            // A key that's present in envVars is considered resolved, even if its
            // value is the empty string (an intentional `KEY=` line). Only a missing
            // key counts as unresolved.
            if let key, let value = envVars[key] {
                output.append(value)
            } else {
                output.append(placeholder)
                if let key { unresolved.insert(key) }
            }

            cursor = r.location + r.length
        }

        if cursor < ns.length {
            output.append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }

        return Result(content: output as String, unresolved: unresolved)
    }

    /// Scan a scripts directory for placeholder references without performing any
    /// substitution. Used by `--strict-env` when no variables are available, so
    /// scripts with `${MISSING}` still fail the build.
    public static func scanScriptsDirectory(at scriptsDir: String) -> [String: Set<String>] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scriptsDir),
              let contents = try? fileManager.contentsOfDirectory(atPath: scriptsDir) else {
            return [:]
        }

        let scriptNames: Set<String> = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preexpansion"]
        let scriptsToScan = contents.filter { name in
            scriptNames.contains(name) || name.hasSuffix(".sh") || name.hasSuffix(".py")
        }

        var unresolvedByScript: [String: Set<String>] = [:]
        let scriptsURL = URL(fileURLWithPath: scriptsDir)
        for scriptName in scriptsToScan {
            let path = scriptsURL.appendingPathComponent(scriptName).path
            guard let data = fileManager.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }
            let result = replace(in: content, with: [:])
            if !result.unresolved.isEmpty {
                unresolvedByScript[scriptName] = result.unresolved
            }
        }
        return unresolvedByScript
    }

    /// Process scripts in a directory, replacing placeholders. Processed scripts are
    /// written under `tempDir/scripts` with mode 0700; the parent `tempDir` is also
    /// clamped to 0700. Returns nil if there's nothing to process.
    public static func processScriptsDirectory(
        at scriptsDir: String,
        with envVars: [String: String],
        tempDir: String
    ) throws -> DirectoryResult? {
        let fileManager = FileManager.default
        let scriptsURL = URL(fileURLWithPath: scriptsDir)
        let tempScriptsDir = (tempDir as NSString).appendingPathComponent("scripts")

        guard fileManager.fileExists(atPath: scriptsDir),
              let contents = try? fileManager.contentsOfDirectory(atPath: scriptsDir) else {
            return nil
        }

        let scriptNames: Set<String> = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preexpansion"]
        let scriptsToProcess = contents.filter { name in
            scriptNames.contains(name) || name.hasSuffix(".sh") || name.hasSuffix(".py")
        }

        if envVars.isEmpty || scriptsToProcess.isEmpty {
            return nil
        }

        try fileManager.createDirectory(
            atPath: tempScriptsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Clamp the parent temp dir too, in case it was created earlier with default umask.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir)

        var unresolvedByScript: [String: Set<String>] = [:]

        for scriptName in scriptsToProcess {
            let sourcePath = scriptsURL.appendingPathComponent(scriptName).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(scriptName)

            guard let data = fileManager.contents(atPath: sourcePath),
                  let content = String(data: data, encoding: .utf8) else {
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                continue
            }

            let result = replace(in: content, with: envVars)
            try result.content.write(toFile: destPath, atomically: true, encoding: .utf8)

            if !result.unresolved.isEmpty {
                unresolvedByScript[scriptName] = result.unresolved
            }

            // Strip group/other r/w/x — these scripts contain substituted values and
            // shouldn't be readable by other local users during build. Always force the
            // owner execute bit since pkgbuild requires scripts to be executable, and a
            // source file with mode 0644 would otherwise produce a non-runnable 0600
            // destination.
            let sourceAttrs = try fileManager.attributesOfItem(atPath: sourcePath)
            let sourcePerms = (sourceAttrs[.posixPermissions] as? Int) ?? 0o700
            let safePerms = (sourcePerms & 0o700) | 0o100
            try fileManager.setAttributes([.posixPermissions: safePerms], ofItemAtPath: destPath)
        }

        for item in contents where !scriptsToProcess.contains(item) {
            let sourcePath = scriptsURL.appendingPathComponent(item).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(item)
            try? fileManager.copyItem(atPath: sourcePath, toPath: destPath)
        }

        return DirectoryResult(scriptsDir: tempScriptsDir, unresolvedByScript: unresolvedByScript)
    }
}
