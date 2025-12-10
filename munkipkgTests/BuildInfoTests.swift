//
//  BuildInfoTests.swift
//  munkipkgTests
//
//  Created by Greg Neagle on 7/5/25.
//

import Foundation
import Testing
@testable import munkipkg

struct BuildInfoTests {

    @Test func canReadJsonString() async throws {
        let jsonString = """
            {
                "ownership": "recommended",
                "suppress_bundle_relocation": true,
                "identifier": "com.github.munki.pkg.munki_kickstart",
                "postinstall_action": "none",
                "distribution_style": true,
                "version": "1.0",
                "name": "munki_kickstart.pkg",
                "install_location": "/"
            }
            """
        let buildInfo = try BuildInfo(fromJsonString: jsonString)
        #expect(buildInfo.ownership == Ownership.recommended)
        #expect(buildInfo.suppressBundleRelocation == true)
        #expect(buildInfo.identifier == "com.github.munki.pkg.munki_kickstart")
        #expect(buildInfo.postinstallAction == PostInstallAction.none)
        #expect(buildInfo.distributionStyle == true)
        #expect(buildInfo.version == "1.0")
        #expect(buildInfo.name == "munki_kickstart.pkg")
        #expect(buildInfo.installLocation == "/")
        #expect(buildInfo.signingInfo == nil)
        #expect(buildInfo.notarizationInfo == nil)
    }
    
    @Test func extraKeysIgnored() async throws {
        let jsonString = """
            {
                "ownership": "recommended",
                "suppress_bundle_relocation": true,
                "identifier": "com.github.munki.pkg.munki_kickstart",
                "postinstall_action": "none",
                "distribution_style": true,
                "version": "1.0",
                "name": "munki_kickstart.pkg",
                "install_location": "/",
                "_notes": "Some notes"
            }
            """
        let buildInfo = try BuildInfo(fromJsonString: jsonString)
        #expect(buildInfo.name == "munki_kickstart.pkg")
    }

    @Test func throwsErrorOnMissingKey() async throws {
        // name is missing
        let jsonString = """
            {
                "ownership": "recommended",
                "suppress_bundle_relocation": true,
                "identifier": "com.github.munki.pkg.munki_kickstart",
                "postinstall_action": "none",
                "distribution_style": true,
                "version": "1.0",
                "install_location": "/"
            }
            """
        #expect(throws: BuildInfoReadError.self) {
            try BuildInfo(fromJsonString: jsonString)
        }
    }
    
    @Test func throwsErrorOnKeyWithWrongType() async throws {
        // version is a floating point number and not a string
        let jsonString = """
            {
                "ownership": "recommended",
                "suppress_bundle_relocation": true,
                "identifier": "com.github.munki.pkg.munki_kickstart",
                "postinstall_action": "none",
                "distribution_style": true,
                "version": 1.0,
                "name": "munki_kickstart.pkg",
                "install_location": "/"
            }
            """
        #expect(throws: BuildInfoReadError.self) {
            try BuildInfo(fromJsonString: jsonString)
        }
    }
    
    @Test func canReadJsonFile() async throws {
        let filePath = try #require(TestingResource.path(for: "build-info.json"),
                                    "Could not get path for test build-info.json")
        let buildInfo = try BuildInfo(fromFile: filePath)
        #expect(buildInfo.ownership == Ownership.recommended)
        #expect(buildInfo.suppressBundleRelocation == true)
        #expect(buildInfo.identifier == "com.github.munki.pkg.munki_kickstart")
        #expect(buildInfo.postinstallAction == PostInstallAction.none)
        #expect(buildInfo.distributionStyle == true)
        #expect(buildInfo.version == "1.0")
        #expect(buildInfo.name == "munki_kickstart.pkg")
        #expect(buildInfo.installLocation == "/")
        #expect(buildInfo.signingInfo == nil)
        #expect(buildInfo.notarizationInfo == nil)
    }
    
    @Test func canReadPlistString() async throws {
        let plistString = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>distribution_style</key>
                <false/>
                <key>identifier</key>
                <string>com.github.munki.pkg.munkifacts</string>
                <key>install_location</key>
                <string>/</string>
                <key>name</key>
                <string>munkifacts.pkg</string>
                <key>ownership</key>
                <string>recommended</string>
                <key>postinstall_action</key>
                <string>none</string>
                <key>suppress_bundle_relocation</key>
                <true/>
                <key>version</key>
                <string>1.0</string>
            </dict>
            </plist>
            """
        let buildInfo = try BuildInfo(fromPlistString: plistString)
        #expect(buildInfo.ownership == Ownership.recommended)
        #expect(buildInfo.suppressBundleRelocation == true)
        #expect(buildInfo.identifier == "com.github.munki.pkg.munkifacts")
        #expect(buildInfo.postinstallAction == PostInstallAction.none)
        #expect(buildInfo.distributionStyle == false)
        #expect(buildInfo.version == "1.0")
        #expect(buildInfo.name == "munkifacts.pkg")
        #expect(buildInfo.installLocation == "/")
        #expect(buildInfo.signingInfo == nil)
        #expect(buildInfo.notarizationInfo == nil)
    }

    @Test func canReadPlistFile() async throws {
        let filePath = try #require(TestingResource.path(for: "build-info.plist"),
                                    "Could not get path for test build-info.plist")
        let buildInfo = try BuildInfo(fromFile: filePath)
        #expect(buildInfo.ownership == Ownership.recommended)
        #expect(buildInfo.suppressBundleRelocation == true)
        #expect(buildInfo.identifier == "com.github.munki.pkg.munkifacts")
        #expect(buildInfo.postinstallAction == PostInstallAction.none)
        #expect(buildInfo.distributionStyle == false)
        #expect(buildInfo.version == "1.0")
        #expect(buildInfo.name == "munkifacts.pkg")
        #expect(buildInfo.installLocation == "/")
        #expect(buildInfo.signingInfo == nil)
        #expect(buildInfo.notarizationInfo == nil)
    }
    
    @Test func getBuildInfoThrowsErrorIfMultipleFiles() async throws {
        let filePath = try #require(TestingResource.path(for: "build-info.json"),
                                    "Could not get path for test build-info.json")
        let dirPath = (filePath as NSString).deletingLastPathComponent
        #expect(throws: BuildInfoReadError.self) {
            let _ = try getBuildInfo(projectDir: dirPath)
        }
    }
    
    @Test func getBuildInfoReadsPlistFile() async throws {
        let filePath = try #require(TestingResource.path(for: "build-info.json"),
                                    "Could not get path for test build-info.json")
        let dirPath = (filePath as NSString).deletingLastPathComponent
        let buildInfo = try getBuildInfo(projectDir: dirPath, format: "plist")
        #expect(buildInfo.name == "munkifacts.pkg")
    }
    
    @Test func getBuildInfoReadsJsonFile() async throws {
        let filePath = try #require(TestingResource.path(for: "build-info.plist"),
                                    "Could not get path for test build-info.plist")
        let dirPath = (filePath as NSString).deletingLastPathComponent
        let buildInfo = try getBuildInfo(projectDir: dirPath, format: "json")
        #expect(buildInfo.name == "munki_kickstart.pkg")
    }

    @Test func doSubstitutions() async throws {
        let filePath = try #require(TestingResource.path(for: "test-substitution.plist"),
                                    "Could not get path for test-substitution.plist")
        var buildInfo = try BuildInfo(fromFile: filePath)
        buildInfo.doSubstitutions()
        #expect(buildInfo.name == "python-modernize-0.7.pkg")
    }
    
    @Test func dynamicVersionTimestamp() async throws {
        var buildInfo = BuildInfo()
        buildInfo.version = "${TIMESTAMP}"
        buildInfo.name = "test-${version}.pkg"
        buildInfo.doSubstitutions()
        
        // Version should be in YYYY.MM.DD.HHMM format
        let versionPattern = #/^\d{4}\.\d{2}\.\d{2}\.\d{4}$/#
        #expect(buildInfo.version.contains(versionPattern))
        // Name should contain the resolved version
        #expect(buildInfo.name.hasPrefix("test-"))
        #expect(buildInfo.name.hasSuffix(".pkg"))
        #expect(!buildInfo.name.contains("${"))
    }
    
    @Test func dynamicVersionDate() async throws {
        var buildInfo = BuildInfo()
        buildInfo.version = "${DATE}"
        buildInfo.doSubstitutions()
        
        // Version should be in YYYY.MM.DD format
        let versionPattern = #/^\d{4}\.\d{2}\.\d{2}$/#
        #expect(buildInfo.version.contains(versionPattern))
    }
    
    @Test func dynamicVersionDatetime() async throws {
        var buildInfo = BuildInfo()
        buildInfo.version = "${DATETIME}"
        buildInfo.doSubstitutions()
        
        // Version should be in YYYY.MM.DD.HHMMSS format
        let versionPattern = #/^\d{4}\.\d{2}\.\d{2}\.\d{6}$/#
        #expect(buildInfo.version.contains(versionPattern))
    }
    
    @Test func dynamicVersionWithPrefix() async throws {
        var buildInfo = BuildInfo()
        buildInfo.version = "v${DATE}-build"
        buildInfo.doSubstitutions()
        
        // Version should start with "v" and end with "-build"
        #expect(buildInfo.version.hasPrefix("v"))
        #expect(buildInfo.version.hasSuffix("-build"))
        #expect(!buildInfo.version.contains("${"))
    }
    
    @Test func dynamicVersionHelper() async throws {
        // Test DynamicVersion helper directly
        let timestamp = DynamicVersion.timestamp
        let date = DynamicVersion.date
        let datetime = DynamicVersion.datetime
        
        // Verify formats
        #expect(timestamp.count == 15) // YYYY.MM.DD.HHMM
        #expect(date.count == 10) // YYYY.MM.DD
        #expect(datetime.count == 17) // YYYY.MM.DD.HHMMSS
        
        // Verify they start with the current year
        let currentYear = Calendar.current.component(.year, from: Date())
        #expect(timestamp.hasPrefix("\(currentYear)."))
        #expect(date.hasPrefix("\(currentYear)."))
        #expect(datetime.hasPrefix("\(currentYear)."))
    }
}
