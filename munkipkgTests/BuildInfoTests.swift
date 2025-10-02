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
}
