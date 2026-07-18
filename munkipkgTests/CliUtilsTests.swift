//
//  CliUtilsTests.swift
//  munkipkgTests
//

import Foundation
import Testing
@testable import munkipkg

struct CliUtilsTests {

    // MARK: - large output (deadlock / ordering regression guard)

    // ~1.1 MB of stdout, far past the ~64 KB pipe buffer. The concurrent drain
    // must capture every line in order without deadlocking; a wait-then-read
    // runner would hang here.
    @Test func runCLICapturesLargeStdoutInOrder() {
        let result = runCLI("/usr/bin/seq", arguments: ["1", "200000"])
        #expect(result.exitCode == 0)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 200_000)
        #expect(lines.first == "1")
        #expect(lines.last == "200000")
    }

    @Test func runCliAsyncCapturesLargeStdoutInOrder() async {
        let result = await runCliAsync("/usr/bin/seq", arguments: ["1", "200000"])
        #expect(result.exitCode == 0)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 200_000)
        #expect(lines.last == "200000")
    }

    // MARK: - stream separation

    @Test func runCLISeparatesStderrAndExitCode() {
        // ls of a missing path writes to stderr and exits non-zero.
        let result = runCLI("/bin/ls", arguments: ["/no/such/path/munkipkg-test-xyz"])
        #expect(result.exitCode != 0)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }

    // MARK: - stdin round-trip (large input must not deadlock)

    @Test func runCLIRoundTripsLargeStdin() {
        // ~600 KB written to stdin while stdout is drained concurrently.
        let input = (0 ..< 60000).map { "line \($0)" }.joined(separator: "\n")
        let result = runCLI("/bin/cat", stdIn: input)
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }

    // MARK: - launch failure surfaces a reason

    @Test func runCLIReportsLaunchFailure() {
        let result = runCLI("/nonexistent/tool/munkipkg-should-not-exist")
        #expect(result.exitCode == -1)
        #expect(!result.failureDetail.isEmpty)
    }
}
