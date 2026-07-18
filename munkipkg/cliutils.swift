//
//  cliutils.swift
//
//  Created by Greg Neagle on 6/26/24.
//
//  Copyright 2024-2025 Greg Neagle.
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

import Darwin
import Foundation

/// Removes a final newline character from a string if present
func trimTrailingNewline(_ s: String) -> String {
    var trimmedString = s
    if trimmedString.last == "\n" {
        trimmedString = String(trimmedString.dropLast())
    }
    return trimmedString
}

struct CLIResults: Sendable {
    var exitCode: Int = 0
    var stdout: String = "" // process stdout
    var stderr: String = "" // process stderr
    var timedOut: Bool = false
    var failureDetail: String = "" // error text from this code
}

enum ProcessError: Error, Sendable {
    case error(description: String)
    case timeout
}

/// like Python's subprocess.check_output
func checkOutput(_ tool: String,
                 arguments: [String] = [],
                 environment: [String: String] = [:],
                 stdIn: String = "") throws(ProcessError) -> String
{
    let result = runCLI(
        tool,
        arguments: arguments,
        environment: environment,
        stdIn: stdIn
    )
    if result.exitCode != 0 {
        throw .error(description: result.stderr)
    }
    return result.stdout
}

/// Runs a command-line tool to completion, capturing stdout and stderr.
///
/// stdout and stderr are drained concurrently on background queues while the
/// process runs, so a child that writes more than the ~64 KB pipe buffer to
/// either stream can't deadlock against us (the earlier readabilityHandler +
/// busy-wait implementation risked exactly that, and spun a CPU core hot while
/// polling). stdin, if any, is written on its own queue for the same reason.
/// This is the same drain-and-join pattern used by `runGitProbe`, factored so
/// both the sync (`runCLI`) and async (`runCliAsync`) entry points share it.
private func runCLICore(_ tool: String,
                        arguments: [String],
                        environment: [String: String],
                        stdIn: String) -> CLIResults
{
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    if !environment.isEmpty {
        task.environment = environment
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe
    task.standardInput = inputPipe

    do {
        try task.run()
    } catch {
        // task didn't launch — surface why instead of a bare -1
        return CLIResults(exitCode: -1, failureDetail: "Failed to launch \(tool): \(error)")
    }

    // Hold the captured Data in a Sendable box so the concurrent reader closures
    // can each write their own field. Every field is written exactly once by a
    // single closure, and the parent reads only after `group.wait()`, so there is
    // no concurrent mutation.
    final class DataBox: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }
    let box = DataBox()
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        box.stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        box.stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    // Write stdin (if any) concurrently, then close so the child sees EOF.
    let inputHandle = inputPipe.fileHandleForWriting
    if !stdIn.isEmpty, let data = stdIn.data(using: .utf8) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            try? inputHandle.write(contentsOf: data)
            try? inputHandle.close()
            group.leave()
        }
    } else {
        try? inputHandle.close()
    }

    task.waitUntilExit()
    group.wait()

    return CLIResults(
        exitCode: Int(task.terminationStatus),
        stdout: trimTrailingNewline(String(data: box.stdout, encoding: .utf8) ?? ""),
        stderr: trimTrailingNewline(String(data: box.stderr, encoding: .utf8) ?? "")
    )
}

/// a basic wrapper intended to be used just as you would runCLI, but async
func runCliAsync(_ tool: String,
                 arguments: [String] = [],
                 environment: [String: String] = [:],
                 stdIn: String = "") async -> CLIResults
{
    // Run the blocking core on a background queue and resume the continuation
    // when it finishes — no busy-wait, so a long child (e.g. `notarytool --wait`)
    // suspends the task instead of pinning a CPU core.
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let result = runCLICore(tool, arguments: arguments, environment: environment, stdIn: stdIn)
            continuation.resume(returning: result)
        }
    }
}

/// Runs a command line tool synchronously, returns CLIResults
func runCLI(_ tool: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            stdIn: String = "") -> CLIResults
{
    return runCLICore(tool, arguments: arguments, environment: environment, stdIn: stdIn)
}
