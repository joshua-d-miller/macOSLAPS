/*
===============================================================================
 macOSLAPS | Extensions | Logging.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-06-13
 Updated:   2026-11-12

 Purpose:
     The macOSLAPS log. Every message goes to the unified log (subsystem
     com.joshua-d-miller.macoslaps), to the terminal (stderr for commands
     whose output scripts read) and, when root, to
     /Library/Application Support/macOSLAPS/Logs/macOSLAPS.log. That file
     rotates at 5 MB and keeps four old copies. /Library/Logs/macOSLAPS.log
     is a symlink to it, made again on every run, because macOS updates can
     clear /Library/Logs.

 Credits:
     Based on https://stackoverflow.com/questions/24402533/is-there-a-swif
     t-alternative-for-nslogs-pretty-function
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    Log lines can go to stderr so -status,
                        claude    -escrow and -showconfig print only their
                                  result; errors are remembered for -status.
                                  Unified logging; the log file moved to
                                  Application Support with size rotation and a
                                  symlink in /Library/Logs (an old log there is
                                  kept as macOSLAPS-3x.log).

                                  New header and section style.
===============================================================================
*/

import Foundation
import os

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

        /// The matching unified log type. Info is .default so it is kept on disk
        /// (.info messages are only kept in memory unless a profile says otherwise).
        var osType: OSLogType {
            switch self {
            case .info: return .default
            case .debug: return .debug
            case .warn: return .default
            case .error: return .error
            }
        }
    }
    
    public static var minimumLogLevel: logLevel = .info
    /// When true, log lines go to stderr so stdout carries only machine-readable output
    /// (-status, -escrow). The log file is written either way.
    public static var useStandardError = false

    /// log show --predicate 'subsystem == "com.joshua-d-miller.macoslaps"' --info
    static let unified = OSLog(subsystem: "com.joshua-d-miller.macoslaps",
                               category: ProcessInfo.processInfo.arguments.dropFirst().first ?? "run")
    
    public static func print<T>(_ object: T, _ level: logLevel = .debug, filename: String = #file, line: Int = #line, funcname: String = #function) {
        if level == .error { RunState.lastError = "\(object)" }
        if level.rawValue >= laps_log.minimumLogLevel.rawValue {
            let process = ProcessInfo.processInfo
            let text = "\(level.description())|\(date_formatter().string(from: Foundation.Date()))|\(process.processName)|\(object)"
            if useStandardError {
                FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
            } else {
                Swift.print(text)
            }
            // macOSLAPS never logs a password, so the message is public.
            os_log("%{public}@", log: unified, type: level.osType, "\(object)")
            LogFile.append(text)
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------ //
// | Log file | //
// ------------ //
// Appends a line to the log file, rotates it and keeps the symlink.         //
enum LogFile {
    static let folder = "/Library/Application Support/macOSLAPS/Logs"
    static let path = folder + "/macOSLAPS.log"
    static let link = "/Library/Logs/macOSLAPS.log"
    static let maxBytes: UInt64 = 5 * 1024 * 1024
    static let keep = 4
    private static var prepared = false

    /// Once per run, as root: the folder (755), the symlink in /Library/Logs and
    /// rotation. A regular file at the old path (3.x / 845) is kept as macOSLAPS-3x.log.
    static func prepare() {
        guard !prepared, getuid() == 0 else { return }
        prepared = true
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        if let type = (try? fm.attributesOfItem(atPath: link))?[.type] as? FileAttributeType {
            if type == .typeRegular {
                let old = folder + "/macOSLAPS-3x.log"
                try? fm.removeItem(atPath: old)
                try? fm.moveItem(atPath: link, toPath: old)
            } else if type == .typeSymbolicLink,
                      (try? fm.destinationOfSymbolicLink(atPath: link)) != path {
                try? fm.removeItem(atPath: link)
            }
        }
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != path {
            try? fm.createDirectory(atPath: "/Library/Logs", withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: path)
        }
        rotateIfNeeded()
    }

    /// macOSLAPS.log -> .1 -> ... -> .4; the oldest is dropped.
    static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64,
              size >= maxBytes else { return }
        try? fm.removeItem(atPath: "\(path).\(keep)")
        for n in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(path).\(n)", toPath: "\(path).\(n + 1)")
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
    }

    /// O_APPEND so the check daemon and the service can write at the same time.
    static func append(_ line: String) {
        guard getuid() == 0 else { return }   // a user running -version or the app: no file
        prepare()
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
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
