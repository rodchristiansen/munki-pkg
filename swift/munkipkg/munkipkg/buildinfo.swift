//
//  buildinfo.swift
//  munkipkg
//
//  Created by Greg Neagle on 7/4/25.
//

import Foundation

class BuildInfoError: MunkiPkgError {}

class BuildInfoReadError: BuildInfoError {}

class BuildInfoWriteError: BuildInfoError {}

struct SigningInfo: Codable {
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

struct NotarizationInfo: Codable {
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

enum Ownership: String, Codable {
    case recommended = "recommended"
    case preserve = "preserve"
    case preserveOther = "preserve-other"
}

enum PostInstallAction: String, Codable {
    case none = "none"
    case logout = "logout"
    case restart = "restart"
}

enum CompressionOption: String, Codable {
    case legacy = "legacy"
    case latest = "latest"
}

struct BuildInfo: Codable {
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
        case signingInfo = "signing_info"
        case notarizationInfo = "notarization_info"
    }
    
    init(fromPlistData data: Data) throws {
        let decoder = PropertyListDecoder()
        self = try decoder.decode(BuildInfo.self, from: data)
    }
    
    init(fromPlistString plistString: String) throws {
        let decoder = PropertyListDecoder()
        if let data = plistString.data(using: .utf8) {
            self = try decoder.decode(BuildInfo.self, from: data)
        } else {
            throw BuildInfoReadError("Invalid plist string")
        }
    }
    
    init(fromJsonData data: Data) throws {
        let decoder = JSONDecoder()
        self = try decoder.decode(BuildInfo.self, from: data)
    }
    
    init(fromJsonString jsonString: String) throws {
        let decoder = JSONDecoder()
        if let data = jsonString.data(using: .utf8) {
            self = try decoder.decode(BuildInfo.self, from: data)
        } else {
            throw BuildInfoReadError("Invalid json string")
        }
    }
    
    init(fromFile filename: String) throws {
        guard let data = NSData(contentsOfFile: filename) as? Data else {
            throw BuildInfoReadError("Could not read data from file")
        }
        let ext = (filename as NSString).pathExtension
        if ext == "plist" {
            let decoder = PropertyListDecoder()
            self = try decoder.decode(BuildInfo.self, from: data)
        } else if ext == "json" {
            let decoder = JSONDecoder()
            self = try decoder.decode(BuildInfo.self, from: data)
        } else if ["yaml", "yml"].contains(ext) {
            throw BuildInfoReadError("YAML format is currently unsupported")
        } else {
            throw BuildInfoReadError("Unsupported file format")
        }
    }
    
    mutating func doSubstitutions() {
        if name.contains("${version}") {
            name = name.replacingOccurrences(of: "${version}", with: version)
        }
    }
    
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    
    func jsonString() throws -> String {
        return String(data: try jsonData(), encoding: .utf8)!
    }
    
    func plistData() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }
    
    func plistString() throws -> String {
        return String(data: try plistData(), encoding: .utf8)!
    }
}

func getBuildInfo(projectDir: String, format: String = "") throws -> BuildInfo {
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
