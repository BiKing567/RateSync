//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

import OSLog
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
    static func getRecentEntries(type: EntryType, process: String = "Music") throws -> [SimpleConsole] {
        var messages = [SimpleConsole]()
        let store = try OSLogStore.local()
        let duration = store.position(timeIntervalSinceEnd: -5.0)
        let predicate = NSPredicate(format: "(subsystem = %@) AND (process = %@)", argumentArray: [type.rawValue, process])
        let entries = try store.getEntries(with: [], at: duration, matching: predicate)
        // for some reason AnySequence to Array turns it into a empty array?
        for entry in entries {
            let consoleMessage = SimpleConsole(date: entry.date, message: entry.composedMessage)
            //Logger.switching.info((date: entry.date, message: entry.composedMessage))
            messages.append(consoleMessage)
        }
        
        return messages.reversed()
    }
}
