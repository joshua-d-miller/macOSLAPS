/*
===============================================================================
 macOSLAPS | Extensions | Logging.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-06-13
 Updated:   2026-11-11

 Purpose:
     The macOSLAPS log: messages go to /Library/Logs/macOSLAPS.log and to
     the terminal (stderr for commands whose output scripts read).

 Credits:
     Based on https://stackoverflow.com/questions/24402533/is-there-a-swif
     t-alternative-for-nslogs-pretty-function
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    Log lines can go to stderr so -status,
                        claude    -escrow and -showconfig print only their
                                  result; errors are remembered for -status.

                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------- //
// | Log | //
// ------- //
// Levels, formatting and where each message goes.                           //
// Logging Module - from Stack Overflow
// https://stackoverflow.com/questions/24402533/is-there-a-swift-alternative-for-nslogs-pretty-function
public class laps_log {
    
    public enum logLevel: Int {
        case info = 1
        case debug = 2
        case warn = 3
        case error = 4
        
        public func description() -> String {
            switch self {
            case .info:
                return "Info"
            case .debug:
                return "Debug"
            case .warn:
                return "Warning"
            case .error:
                return "Error"
            }
        }
    }
    
    public static var minimumLogLevel: logLevel = .info
    /// When true, log lines go to stderr so stdout carries only machine-readable output
    /// (-status, -escrow). The log file is written either way.
    public static var useStandardError = false
    
    public static func print<T>(_ object: T, _ level: logLevel = .debug, filename: String = #file, line: Int = #line, funcname: String = #function) {
        if level == .error { RunState.lastError = "\(object)" }
        if level.rawValue >= laps_log.minimumLogLevel.rawValue {
            let process = ProcessInfo.processInfo
            let line = "\(level.description())|\(date_formatter().string(from: Foundation.Date()))|\(process.processName)|\(object)"
            if useStandardError {
                FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            } else {
                Swift.print(line)
            }
            let text = "\(level.description())|\(date_formatter().string(from: Foundation.Date()))|\(process.processName)|\(object)"
            writeToFile(content: text, fileName: "macOSLAPS.log")
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------ //
// | Log file | //
// ------------ //
// Appends a line to the log file.                                           //
// Append to file which allows to write to the log file - from Stack Overflow
// https://stackoverflow.com/questions/36736215/append-new-string-to-txt-file-in-swift-2
func writeToFile(content: String, fileName: String) {
    
    let contentToAppend = content+"\n"
    let filePath = "/Library/Logs/" + fileName
    
    // Check if file exists
    if let fileHandle = FileHandle(forWritingAtPath: filePath) {
        // Append to file
        fileHandle.seekToEndOfFile()
        fileHandle.write(contentToAppend.data(using: String.Encoding.utf8)!)
    }
    else {
        // Create new file
        do {
            try contentToAppend.write(toFile: filePath, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            // Not root (e.g. -version or -showConfig run by a user): the log file is optional.
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | Error text | //
// -------------- //
// A readable description of an error.                                       //
/// Error details for logs: domain, code and message (catch blocks used to drop these).
func describe(_ error: Error) -> String {
    let e = error as NSError
    return "\(e.domain) \(e.code): \(e.localizedDescription)"
}
