//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

@preconcurrency import OSLog
import Cocoa

/// Central logging for the sample-rate switching pipeline. Visible via
/// `log stream --predicate 'subsystem == "com.biking.RateSync"'`
extension Logger {
    static let switching = Logger(subsystem: "com.biking.RateSync", category: "switching")
}

struct SimpleConsole {
    let date: Date
    let message: String
}

enum EntryType: String {
    case coreAudio = "com.apple.coreaudio"
}

class Console {
    static func getRecentEntries(type: EntryType, process: String = "Music", durationSeconds: TimeInterval = 5.0) throws -> [SimpleConsole] {
        var messages = [SimpleConsole]()
        let store = try OSLogStore.local()
        let duration = store.position(timeIntervalSinceEnd: -durationSeconds)
        let predicate = NSPredicate(format: "(subsystem = %@) AND (process = %@)", argumentArray: [type.rawValue, process])
        let entries = try store.getEntries(with: [], at: duration, matching: predicate)
        for entry in entries {
            if let logEntry = entry as? OSLogEntryLog {
                if !isTrustedLogEntry(logEntry, expectedProcess: process) {
                    Logger.switching.info("[LogVerify] dropped untrusted entry pid=\(logEntry.processIdentifier, privacy: .public) process=\(logEntry.process, privacy: .public)")
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
            return true
        }
        let expectedBundle: String? = {
            switch expectedProcess {
            case "Music": return Defaults.appleMusicBundleIdentifier
            case "NeteaseMusic": return Defaults.neteaseMusicBundleIdentifier
            case "Spotify": return Defaults.spotifyBundleIdentifier
            case "QQMusic": return Defaults.qqMusicBundleIdentifier
            default: return nil
            }
        }()
        if let expectedBundle {
            guard let actualBundle = app.bundleIdentifier, actualBundle == expectedBundle else {
                return false
            }
            return true
        }
        if let execName = app.executableURL?.lastPathComponent, execName != expectedProcess {
            return false
        }
        return true
    }
}
