//
//  EnvLoaderTests.swift
//  munkipkgTests
//

import Foundation
import Testing
@testable import munkipkg

struct EnvLoaderTests {

    // MARK: - .env parsing

    @Test func parsesBasicKeyValuePairs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = (dir as NSString).appendingPathComponent(".env")
        try "SERVER=https://example.com\nORG=Acme".write(toFile: envPath, atomically: true, encoding: .utf8)

        let vars = try EnvLoader.load(from: envPath)
        #expect(vars["SERVER"] == "https://example.com")
        #expect(vars["ORG"] == "Acme")
    }

    @Test func stripsSurroundingQuotes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = (dir as NSString).appendingPathComponent(".env")
        try #"A="hello"\#nB='world'\#nC="with \"quotes\" inside""#.write(toFile: envPath, atomically: true, encoding: .utf8)

        let vars = try EnvLoader.load(from: envPath)
        #expect(vars["A"] == "hello")
        #expect(vars["B"] == "world")
        // Inner escaped quotes are kept literally — we don't process escapes.
        #expect(vars["C"]?.contains("quotes") == true)
    }

    @Test func ignoresCommentsAndBlankLines() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = (dir as NSString).appendingPathComponent(".env")
        try """
        # a comment

        KEY=value
        # another comment
        """.write(toFile: envPath, atomically: true, encoding: .utf8)

        let vars = try EnvLoader.load(from: envPath)
        #expect(vars.count == 1)
        #expect(vars["KEY"] == "value")
    }

    @Test func skipsInvalidKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = (dir as NSString).appendingPathComponent(".env")
        try """
        VALID=ok
        9STARTS_WITH_DIGIT=bad
        HAS SPACE=bad
        HAS-DASH=bad
        """.write(toFile: envPath, atomically: true, encoding: .utf8)

        let vars = try EnvLoader.load(from: envPath, warnOnPermissiveMode: false)
        #expect(vars["VALID"] == "ok")
        #expect(vars["9STARTS_WITH_DIGIT"] == nil)
        #expect(vars["HAS SPACE"] == nil)
        #expect(vars["HAS-DASH"] == nil)
    }

    @Test func returnsEmptyForMissingFile() throws {
        let vars = try EnvLoader.load(from: "/nonexistent/path/.env")
        #expect(vars.isEmpty)
    }

    @Test func rejectsOversizedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = (dir as NSString).appendingPathComponent(".env")
        let big = String(repeating: "A=1\n", count: EnvLoader.maxFileSize / 4 + 100)
        try big.write(toFile: envPath, atomically: true, encoding: .utf8)

        #expect(throws: EnvLoadError.self) {
            _ = try EnvLoader.load(from: envPath)
        }
    }

    // MARK: - merge

    @Test func mergePrefersFileOverSystem() {
        let merged = EnvLoader.merge(envFileVars: ["MUNKIPKG_FOO": "from-file"], includeSysEnv: true)
        // Whatever system has, file value wins.
        #expect(merged.vars["MUNKIPKG_FOO"] == "from-file")
    }

    @Test func mergeSkipsSystemWhenDisabled() {
        // Set a sentinel system env var via ProcessInfo isn't trivial in-process; the
        // important behavior is that we don't pick up anything when disabled.
        let merged = EnvLoader.merge(envFileVars: ["LOCAL_KEY": "value"], includeSysEnv: false)
        #expect(merged.systemEnvKeys.isEmpty)
        #expect(merged.vars["LOCAL_KEY"] == "value")
    }

    // MARK: - PlaceholderReplacer

    @Test func replacesAllFourPatterns() {
        let content = """
        shell=${SERVER}
        mustache={{SERVER}}
        xml=__SERVER__
        legacy=SERVER_PLACEHOLDER
        """
        let result = PlaceholderReplacer.replace(in: content, with: ["SERVER": "ok"])
        #expect(result.content.contains("shell=ok"))
        #expect(result.content.contains("mustache=ok"))
        #expect(result.content.contains("xml=ok"))
        #expect(result.content.contains("legacy=ok"))
        #expect(result.unresolved.isEmpty)
    }

    @Test func reportsUnresolvedPlaceholders() {
        let content = "hello ${MISSING} world {{ALSO_MISSING}}"
        let result = PlaceholderReplacer.replace(in: content, with: [:])
        #expect(result.content == content)
        #expect(result.unresolved == ["MISSING", "ALSO_MISSING"])
    }

    @Test func doesNotRecursivelyExpand() {
        // The previous multi-pass implementation expanded values containing
        // placeholder syntax against other keys. Single-pass replacement must not.
        let content = "value=${A}"
        let result = PlaceholderReplacer.replace(in: content, with: [
            "A": "${SECRET}",
            "SECRET": "leaked",
        ])
        // The literal "${SECRET}" should remain — it must NOT be further expanded.
        #expect(result.content == "value=${SECRET}")
    }

    @Test func legacyPatternRequiresWordBoundary() {
        // FOO_PLACEHOLDER should match; XFOO_PLACEHOLDER should not.
        let content = "a=FOO_PLACEHOLDER\nb=XFOO_PLACEHOLDER\nc=FOO_PLACEHOLDERX"
        let result = PlaceholderReplacer.replace(in: content, with: ["FOO": "ok"])
        #expect(result.content.contains("a=ok"))
        #expect(result.content.contains("b=XFOO_PLACEHOLDER"))
        #expect(result.content.contains("c=FOO_PLACEHOLDERX"))
    }

    @Test func emptyValuesLeavePlaceholderAsUnresolved() {
        let result = PlaceholderReplacer.replace(in: "x=${EMPTY}", with: ["EMPTY": ""])
        #expect(result.content == "x=${EMPTY}")
        #expect(result.unresolved.contains("EMPTY"))
    }

    @Test func valuesWithShellMetacharactersAreSpliedVerbatim() {
        // Documenting current behavior: values are NOT escaped. Callers must not put
        // untrusted data in .env. This test exists so that future changes that DO
        // introduce escaping break it visibly and force a conscious choice.
        let result = PlaceholderReplacer.replace(in: "echo ${VAL}", with: ["VAL": "$(whoami)"])
        #expect(result.content == "echo $(whoami)")
    }

    // MARK: - helpers

    private func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("envloader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
