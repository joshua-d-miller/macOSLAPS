/*
===============================================================================
 macOSLAPS | Extensions | Shell.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2021-02-21
 Updated:   2026-11-11

 Purpose:
     Runs a system tool (sysadminctl, fdesetup, profiles, ...) and returns
     its output. Output is read while the tool runs, so tools that print
     more than the pipe buffer (64 KB) can't deadlock, and every call has
     a timeout so a stuck tool can never hang macOSLAPS or the MDM script
     that called it.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    Reads output while the tool runs, with a
                        claude    timeout (fixes the -status deadlock).

                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Running system tools | //
// ------------------------ //
// execute returns the status and output; run only the output.               //
class Shell: NSObject {
    struct Result {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    /// Runs `launchPath` with `arguments`, capturing stdout and stderr together.
    /// Returns status -1 if the tool couldn't be started or timed out.
    class func execute(launchPath: String, arguments: [String], timeout: TimeInterval = 60) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return Result(status: -1, output: "", timedOut: false)
        }

        // Drain the pipe on another thread while the tool runs.
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if task.isRunning {
            timedOut = true
            task.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
        task.waitUntilExit()
        // The write end closes when the tool exits; give the reader a moment to finish.
        _ = reader.wait(timeout: .now() + 5)

        var output = String(decoding: data, as: UTF8.self)
        if output.hasSuffix("\n") { output.removeLast() }
        return Result(status: timedOut ? -1 : task.terminationStatus, output: output, timedOut: timedOut)
    }

    /// Output only (the original API). Empty string if the tool failed to start or timed out.
    class func run(launchPath: String, arguments: [String], timeout: TimeInterval = 60) -> String {
        let result = execute(launchPath: launchPath, arguments: arguments, timeout: timeout)
        if result.timedOut {
            laps_log_shell_timeout(launchPath, timeout)
        }
        return result.output
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Timeout logging hook | //
// ------------------------ //
// Kept separate so this file also compiles in the standalone tests.         //
/// Logging hook kept separate so Shell.swift also compiles in the standalone tests.
var laps_log_shell_timeout: (String, TimeInterval) -> Void = { path, timeout in
    FileHandle.standardError.write("Warning: \(path) did not finish within \(Int(timeout)) seconds and was stopped.\n".data(using: .utf8)!)
}
