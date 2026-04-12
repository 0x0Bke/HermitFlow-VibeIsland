//
//  Logger.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

enum LoggerCategory: String {
    case app
    case store
    case approval
    case source
    case window
    case menuBar
    case monitoring
}

struct Logger {
    static let defaultLogURL = URL(fileURLWithPath: "/tmp/hermitflow-debug.log")

    // TODO: Migrate old ad-hoc log writers in AppDelegate and ProgressStore here in Phase 2.
    static func log(_ message: String, category: LoggerCategory, logURL: URL = defaultLogURL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(category.rawValue)] \(message)\n"
        let data = Data(line.utf8)
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Logging should never affect app behavior in Phase 1.
        }
    }
}
