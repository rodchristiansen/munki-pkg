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

/// Actor to safely accumulate process output from concurrent callbacks
private actor ProcessOutputAccumulator {
    var stdout: String = ""
    var stderr: String = ""
    
    func appendStdout(_ text: String) {
        stdout.append(text)
    }
    
    func appendStderr(_ text: String) {
        stderr.append(text)
    }
    
    func getOutput() -> (stdout: String, stderr: String) {
        return (stdout, stderr)
    }
}

/// a basic wrapper intended to be used just as you would runCLI, but async
func runCliAsync(_ tool: String,
                 arguments: [String] = [],
                 environment: [String: String] = [:],
                 stdIn: String = "") async -> CLIResults
{
    let accumulator = ProcessOutputAccumulator()
    var exitCode: Int = 0

    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    if !environment.isEmpty {
        task.environment = environment
    }

    // set up our stdout and stderr pipes and handlers
    let outputPipe = Pipe()
    outputPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            outputPipe.fileHandleForReading.readabilityHandler = nil
        } else if let text = String(data: data, encoding: .utf8) {
            Task {
                await accumulator.appendStdout(text)
            }
        }
    }
    let errorPipe = Pipe()
    errorPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            errorPipe.fileHandleForReading.readabilityHandler = nil
        } else if let text = String(data: data, encoding: .utf8) {
            Task {
                await accumulator.appendStderr(text)
            }
        }
    }
    let inputPipe = Pipe()
    inputPipe.fileHandleForWriting.writeabilityHandler = { fh in
        if !stdIn.isEmpty {
            if let data = stdIn.data(using: .utf8) {
                fh.write(data)
            }
        }
        fh.closeFile()
        inputPipe.fileHandleForWriting.writeabilityHandler = nil
    }
    task.standardOutput = outputPipe
    task.standardError = errorPipe
    task.standardInput = inputPipe

    do {
        try task.run()
    } catch {
        // task didn't launch
        return CLIResults(exitCode: -1)
    }
    
    // Wait for process to complete
    while task.isRunning {
        await Task.yield()
    }

    // Wait for pipes to close
    while outputPipe.fileHandleForReading.readabilityHandler != nil ||
        errorPipe.fileHandleForReading.readabilityHandler != nil
    {
        await Task.yield()
    }

    exitCode = Int(task.terminationStatus)

    let output = await accumulator.getOutput()
    return CLIResults(
        exitCode: exitCode,
        stdout: trimTrailingNewline(output.stdout),
        stderr: trimTrailingNewline(output.stderr)
    )
}

/// Thread-safe accumulator using locks for synchronous CLI
private final class SynchronousOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout: String = ""
    private var _stderr: String = ""
    
    func appendStdout(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _stdout.append(text)
    }
    
    func appendStderr(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _stderr.append(text)
    }
    
    func getOutput() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (_stdout, _stderr)
    }
}

/// Runs a command line tool synchronously, returns CLIResults
func runCLI(_ tool: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            stdIn: String = "") -> CLIResults
{
    let accumulator = SynchronousOutputAccumulator()
    var exitCode: Int = 0

    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    if !environment.isEmpty {
        task.environment = environment
    }

    // set up our stdout and stderr pipes and handlers
    let outputPipe = Pipe()
    outputPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            outputPipe.fileHandleForReading.readabilityHandler = nil
        } else if let text = String(data: data, encoding: .utf8) {
            accumulator.appendStdout(text)
        }
    }
    let errorPipe = Pipe()
    errorPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            errorPipe.fileHandleForReading.readabilityHandler = nil
        } else if let text = String(data: data, encoding: .utf8) {
            accumulator.appendStderr(text)
        }
    }
    let inputPipe = Pipe()
    inputPipe.fileHandleForWriting.writeabilityHandler = { fh in
        if !stdIn.isEmpty {
            if let data = stdIn.data(using: .utf8) {
                fh.write(data)
            }
        }
        fh.closeFile()
        inputPipe.fileHandleForWriting.writeabilityHandler = nil
    }
    task.standardOutput = outputPipe
    task.standardError = errorPipe
    task.standardInput = inputPipe

    do {
        try task.run()
    } catch {
        // task didn't launch
        return CLIResults(exitCode: -1)
    }
    
    // task.waitUntilExit()
    while task.isRunning {
        // loop until process exits
        usleep(10000)
    }

    while outputPipe.fileHandleForReading.readabilityHandler != nil ||
        errorPipe.fileHandleForReading.readabilityHandler != nil
    {
        // loop until stdout and stderr pipes close
        usleep(10000)
    }

    exitCode = Int(task.terminationStatus)

    let output = accumulator.getOutput()
    return CLIResults(
        exitCode: exitCode,
        stdout: trimTrailingNewline(output.stdout),
        stderr: trimTrailingNewline(output.stderr)
    )
}
