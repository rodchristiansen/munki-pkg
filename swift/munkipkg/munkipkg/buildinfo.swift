//
//  buildinfo.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/4/25.
//

import Foundation
import Yams

public final class BuildInfoError: MunkiPkgError, @unchecked Sendable {
    public override init(_ message: String = "Build info error", exitCode: Int = 1) {
        super.init(message, exitCode: exitCode)
    }
}

public final class BuildInfoReadError: MunkiPkgError, @unchecked Sendable {
    public override init(_ message: String = "Build info read error", exitCode: Int = 1) {
        super.init(message, exitCode: exitCode)
    }
}

public final class BuildInfoWriteError: MunkiPkgError, @unchecked Sendable {
    public override init(_ message: String = "Build info write error", exitCode: Int = 1) {
        super.init(message, exitCode: exitCode)
    }
}

public struct SigningInfo: Codable, Sendable {
    var identity: String
    var keychain: String?
    var additionalCertNames: [String]?
    var timestamp: Bool? = true
    
    enum CodingKeys: String, CodingKey {
        case identity
        case keychain
        case additionalCertNames = "additional_cert_names"
        case timestamp
    }
}

public struct NotarizationInfo: Codable, Sendable {
    var appleId: String?
    var teamId: String?
    var password: String?
    var keychainProfile: String?
    var ascProvider: String?
    var stapleTimeout: Int? = 300
    
    enum CodingKeys: String, CodingKey {
        case appleId = "apple_id"
        case teamId = "team_id"
        case password
        case keychainProfile = "keychain_profile"
        case ascProvider = "asc_provider"
        case stapleTimeout = "staple_timeout"
    }
}

public enum Ownership: String, Codable, Sendable {
    case recommended = "recommended"
    case preserve = "preserve"
    case preserveOther = "preserve-other"
}

public enum PostInstallAction: String, Codable, Sendable {
    case none = "none"
    case logout = "logout"
    case restart = "restart"
}

public enum CompressionOption: String, Codable, Sendable {
    case legacy = "legacy"
    case latest = "latest"
}

public struct BuildInfo: Codable, Sendable {
    var name: String = ""
    var identifier: String = ""
    var version: String = "1.0"
    var distributionStyle: Bool? = false
    var installLocation: String? = "/"
    var ownership: Ownership? = .recommended
    var postinstallAction: PostInstallAction? = PostInstallAction.none
    var preserveXattr: Bool? = false
    var productId: String? = ""
    var suppressBundleRelocation: Bool? = false
    var compression: CompressionOption? = .legacy
    var minOSVersion: String? = "10.5"
    var largePayload: Bool? = false
    var installKbytes: Int?
    var signingInfo: SigningInfo?
    var notarizationInfo: NotarizationInfo?
    
    enum CodingKeys: String, CodingKey {
        case name
        case identifier
        case version
        case distributionStyle = "distribution_style"
        case installLocation = "install_location"
        case ownership
        case postinstallAction = "postinstall_action"
        case preserveXattr = "preserve_xattr"
        case productId = "product_id"
        case suppressBundleRelocation = "suppress_bundle_relocation"
        case compression
        case minOSVersion = "min-os-version"
        case largePayload = "large-payload"
        case installKbytes = "install_kbytes"
        case signingInfo = "signing_info"
        case notarizationInfo = "notarization_info"
    }
    
    public init() {
        // Default initializer with default values already set
    }
    
    public init(fromPlistData data: Data) throws(BuildInfoReadError) {
        let decoder = PropertyListDecoder()
        do {
            self = try decoder.decode(BuildInfo.self, from: data)
        } catch {
            throw BuildInfoReadError("Failed to decode plist: \(error.localizedDescription)")
        }
    }
    
    public init(fromPlistString plistString: String) throws(BuildInfoReadError) {
        let decoder = PropertyListDecoder()
        guard let data = plistString.data(using: .utf8) else {
            throw BuildInfoReadError("Invalid plist string")
        }
        do {
            self = try decoder.decode(BuildInfo.self, from: data)
        } catch {
            throw BuildInfoReadError("Failed to decode plist: \(error.localizedDescription)")
        }
    }
    
    public init(fromJsonData data: Data) throws(BuildInfoReadError) {
        let decoder = JSONDecoder()
        do {
            self = try decoder.decode(BuildInfo.self, from: data)
        } catch {
            throw BuildInfoReadError("Failed to decode JSON: \(error.localizedDescription)")
        }
    }
    
    public init(fromJsonString jsonString: String) throws(BuildInfoReadError) {
        let decoder = JSONDecoder()
        guard let data = jsonString.data(using: .utf8) else {
            throw BuildInfoReadError("Invalid json string")
        }
        do {
            self = try decoder.decode(BuildInfo.self, from: data)
        } catch {
            throw BuildInfoReadError("Failed to decode JSON: \(error.localizedDescription)")
        }
    }
    
    public init(fromYamlData data: Data) throws(BuildInfoReadError) {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw BuildInfoReadError("Invalid YAML data encoding")
        }
        let decoder = YAMLDecoder()
        do {
            self = try decoder.decode(BuildInfo.self, from: yamlString)
        } catch {
            throw BuildInfoReadError("Failed to decode YAML: \(error.localizedDescription)")
        }
    }
    
    public init(fromYamlString yamlString: String) throws(BuildInfoReadError) {
        let decoder = YAMLDecoder()
        do {
            self = try decoder.decode(BuildInfo.self, from: yamlString)
        } catch {
            throw BuildInfoReadError("Failed to decode YAML: \(error.localizedDescription)")
        }
    }
    
    public init(fromFile filename: String) throws(BuildInfoReadError) {
        guard let data = NSData(contentsOfFile: filename) as? Data else {
            throw BuildInfoReadError("Could not read data from file")
        }
        let ext = (filename as NSString).pathExtension
        if ext == "plist" {
            self = try BuildInfo(fromPlistData: data)
        } else if ext == "json" {
            self = try BuildInfo(fromJsonData: data)
        } else if ["yaml", "yml"].contains(ext) {
            self = try BuildInfo(fromYamlData: data)
        } else {
            throw BuildInfoReadError("Unsupported file format")
        }
    }
    
    public mutating func doSubstitutions() {
        if name.contains("${version}") {
            name = name.replacingOccurrences(of: "${version}", with: version)
        }
    }
    
    func jsonData() throws(BuildInfoWriteError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw BuildInfoWriteError("Failed to encode JSON: \(error.localizedDescription)")
        }
    }
    
    func jsonString() throws(BuildInfoWriteError) -> String {
        let data = try jsonData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw BuildInfoWriteError("Failed to convert JSON data to string")
        }
        return string
    }
    
    func plistData() throws(BuildInfoWriteError) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        do {
            return try encoder.encode(self)
        } catch {
            throw BuildInfoWriteError("Failed to encode plist: \(error.localizedDescription)")
        }
    }
    
    func plistString() throws(BuildInfoWriteError) -> String {
        let data = try plistData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw BuildInfoWriteError("Failed to convert plist data to string")
        }
        return string
    }
    
    func yamlData() throws(BuildInfoWriteError) -> Data {
        let yamlString = try yamlString()
        guard let data = yamlString.data(using: .utf8) else {
            throw BuildInfoWriteError("Failed to convert YAML string to data")
        }
        return data
    }
    
    func yamlString() throws(BuildInfoWriteError) -> String {
        let encoder = YAMLEncoder()
        do {
            return try encoder.encode(self)
        } catch {
            throw BuildInfoWriteError("Failed to encode YAML: \(error.localizedDescription)")
        }
    }
}

public func getBuildInfo(projectDir: String, format: String = "") throws(BuildInfoReadError) -> BuildInfo {
    var filetype = ""
    let filenameWithoutExtension = (projectDir as NSString).appendingPathComponent("build-info")
    if format != "" {
        filetype = format
    } else {
        let fileTypes = ["plist", "json", "yaml", "yml"]
        for ext in fileTypes {
            if FileManager.default.fileExists(atPath: "\(filenameWithoutExtension).\(ext)") {
                if filetype == "" {
                    filetype = ext
                } else {
                    throw BuildInfoReadError("Multiple build-info files found!")
                }
            }
        }
    }
    if filetype == "" {
        throw BuildInfoReadError("No build-info file found!")
    }
    let filename = "\(filenameWithoutExtension).\(filetype)"
    var buildinfo = try BuildInfo(fromFile: filename)
    buildinfo.doSubstitutions()
    return buildinfo
}
