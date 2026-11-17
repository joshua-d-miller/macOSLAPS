/*
===============================================================================
 macOSLAPS | Extensions | Shell.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2021-02-21
 Updated:   2026-11-17

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
 4.0.0     2026-11-17   joshua    stderr apart when asked (used by the
                        claude    migration helper); output collected under
                                  a lock.
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
        /// stdout and stderr together, trailing newline trimmed (only stdout with
        /// separateErrors).
        let output: String
        let timedOut: Bool
        /// stdout as bytes (for output that isn't text, such as JSON with a password).
        var data = Data()
        /// stderr, with separateErrors.
        var errors = ""
    }

    /// Collects a pipe's bytes on another thread while the tool runs.
    private final class Reader {
        private var bytes = Data()
        private let lock = NSLock()
        private let done = DispatchGroup()
        init(_ pipe: Pipe) {
            done.enter()
            DispatchQueue.global(qos: .utility).async {
                let read = pipe.fileHandleForReading.readDataToEndOfFile()
                self.lock.lock(); self.bytes = read; self.lock.unlock()
                self.done.leave()
            }
        }
        /// The bytes, once the tool has exited (the write end closes); empty if the
        /// reader doesn't finish in time.
        func finish() -> Data {
            _ = done.wait(timeout: .now() + 5)
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }

    /// Runs `launchPath` with `arguments`, capturing stdout and stderr (together, or
    /// apart with `separateErrors`). Returns status -1 if the tool couldn't be started
    /// or timed out.
    class func execute(launchPath: String, arguments: [String], timeout: TimeInterval = 60,
                       separateErrors: Bool = false) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let out = Pipe(), err = separateErrors ? Pipe() : out
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return Result(status: -1, output: "", timedOut: false)
        }
        let outReader = Reader(out)
        let errReader = separateErrors ? Reader(err) : nil

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

        let data = outReader.finish()
        var output = String(decoding: data, as: UTF8.self)
        if output.hasSuffix("\n") { output.removeLast() }
        let errors = errReader.map { String(decoding: $0.finish(), as: UTF8.self) } ?? ""
        return Result(status: timedOut ? -1 : task.terminationStatus, output: output, timedOut: timedOut,
                      data: data, errors: errors.trimmingCharacters(in: .whitespacesAndNewlines))
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
