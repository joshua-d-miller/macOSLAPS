///
///  Logging.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///

import Foundation

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
    
    public static func print<T>(_ object: T, _ level: logLevel = .debug, filename: String = #file, line: Int = #line, funcname: String = #function) {
        if level.rawValue >= laps_log.minimumLogLevel.rawValue {
            let process = ProcessInfo.processInfo
            Swift.print("\(level.description())|\(date_formatter().string(from: Foundation.Date()))|\(process.processName)|\(object)")
            let text = "\(level.description())|\(date_formatter().string(from: Foundation.Date()))|\(process.processName)|\(object)"
            writeToFile(content: text, fileName: "macOSLAPS.log")
        }
    }
}

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
            print("Error creating \(filePath)")
        }
    }
}
