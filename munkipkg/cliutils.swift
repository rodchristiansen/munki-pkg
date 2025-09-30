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

struct CLIResults {
    var exitCode: Int = 0
    var stdout: String = "" // process stdout
    var stderr: String = "" // process stderr
    var timedOut: Bool = false
    var failureDetail: String = "" // error text from this code
}

enum ProcessError: Error {
    case error(description: String)
    case timeout
}

/// like Python's subprocess.check_output
func checkOutput(_ tool: String,
                 arguments: [String] = [],
                 environment: [String: String] = [:],
                 stdIn: String = "") throws -> String
{
    let result = runCLI(
        tool,
        arguments: arguments,
        environment: environment,
        stdIn: stdIn
    )
    if result.exitCode != 0 {
        throw ProcessError.error(description: result.stderr)
    }
    return result.stdout
}

/// a basic wrapper intended to be used just as you would runCLI, but async
func runCliAsync(_ tool: String,
                 arguments: [String] = [],
                 environment: [String: String] = [:],
                 stdIn: String = "") async -> CLIResults
{
    var results = CLIResults()

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
        } else {
            results.stdout.append(String(data: data, encoding: .utf8)!)
        }
    }
    let errorPipe = Pipe()
    errorPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            errorPipe.fileHandleForReading.readabilityHandler = nil
        } else {
            results.stderr.append(String(data: data, encoding: .utf8)!)
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
        results.exitCode = -1
        return results
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

    results.exitCode = Int(task.terminationStatus)

    results.stdout = trimTrailingNewline(results.stdout)
    results.stderr = trimTrailingNewline(results.stderr)

    return results
}

/// Runs a command line tool synchronously, returns CLIResults
func runCLI(_ tool: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            stdIn: String = "") -> CLIResults
{
    var results = CLIResults()

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
        } else {
            results.stdout.append(String(data: data, encoding: .utf8)!)
        }
    }
    let errorPipe = Pipe()
    errorPipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty { // EOF on the pipe
            errorPipe.fileHandleForReading.readabilityHandler = nil
        } else {
            results.stderr.append(String(data: data, encoding: .utf8)!)
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
        results.exitCode = -1
        return results
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

    results.exitCode = Int(task.terminationStatus)

    results.stdout = trimTrailingNewline(results.stdout)
    results.stderr = trimTrailingNewline(results.stderr)

    return results
}
