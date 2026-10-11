//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

@preconcurrency import OSLog
import Cocoa

struct SimpleConsole {
    let date: Date
    let message: String
}

enum EntryType: String {
    case coreAudio = "com.apple.coreaudio"
    case appleMusic = "com.apple.Music"
}

class Console {
    static func getRecentEntries(type: EntryType, process: String = PlayerProfile.appleMusic.processName, durationSeconds: TimeInterval = 5.0) throws -> [SimpleConsole] {
        try getRecentEntries(types: [type], process: process, durationSeconds: durationSeconds)
    }

    static func getRecentEntries(types: [EntryType], process: String, durationSeconds: TimeInterval) throws -> [SimpleConsole] {
        var messages = [SimpleConsole]()
        let store = try OSLogStore.local()
        let duration = store.position(timeIntervalSinceEnd: -durationSeconds)
        let subsystems = types.map(\.rawValue)
        let predicate = NSPredicate(format: "(subsystem IN %@) AND (process = %@)", argumentArray: [subsystems, process])
        let entries = try store.getEntries(with: [], at: duration, matching: predicate)
        for entry in entries {
            if let logEntry = entry as? OSLogEntryLog {
                if !isTrustedLogEntry(logEntry, expectedProcess: process) {
                    RateSyncLog.switching.info("[LogVerify] dropped untrusted entry pid=\(logEntry.processIdentifier, privacy: .public) process=\(logEntry.process, privacy: .public)")
                    continue
                }
            }
            let consoleMessage = SimpleConsole(date: entry.date, message: entry.composedMessage)
            messages.append(consoleMessage)
        }
        return messages.reversed()
    }

    private static func isTrustedLogEntry(_ entry: OSLogEntryLog, expectedProcess: String) -> Bool {
        let pid = entry.processIdentifier
        guard pid > 0 else { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        let expectedBundle = PlayerProfile.bundleIdentifier(forProcessName: expectedProcess)
        if let expectedBundle {
            guard let actualBundle = app.bundleIdentifier, actualBundle == expectedBundle else {
                return false
            }
        }
        guard let execName = app.executableURL?.lastPathComponent,
              execName == expectedProcess else {
            return false
        }
        return true
    }
}
