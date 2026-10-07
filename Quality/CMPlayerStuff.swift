//
//  CMPlayerStats.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//

import Foundation
import OSLog
import Sweep

struct CMPlayerStats {
    let sampleRate: Double // Hz
    let bitDepth: Int?
    let date: Date
    let isAppleMusicFormat: Bool
    let isDolbyAtmos: Bool

    init(
        sampleRate: Double,
        bitDepth: Int?,
        date: Date,
        isAppleMusicFormat: Bool = false,
        isDolbyAtmos: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.date = date
        self.isAppleMusicFormat = isAppleMusicFormat
        self.isDolbyAtmos = isDolbyAtmos
    }

    static func sampleRateOnly(sampleRate: Double, date: Date = Date()) -> CMPlayerStats {
        CMPlayerStats(sampleRate: sampleRate, bitDepth: nil, date: date)
    }
}

extension CMPlayerStats: CustomStringConvertible {
    var description: String {
        let bitDepthDescription = bitDepth.map { String($0) } ?? "unknown"
        return "CMPlayerStats(sampleRate: \(sampleRate), bitDepth: \(bitDepthDescription), appleMusicFormat: \(isAppleMusicFormat), dolbyAtmos: \(isDolbyAtmos))"
    }
}

class CMPlayerParser {
    static func parseAppleMusicConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let logEntries = entries.map { AppleMusicLogEntry(date: $0.date, message: $0.message) }
        let highLevelStats = AppleMusicFormatParser.parse(logEntries).map { evidence in
            CMPlayerStats(
                sampleRate: evidence.sampleRate,
                bitDepth: evidence.bitDepth,
                date: evidence.date,
                isAppleMusicFormat: true,
                isDolbyAtmos: evidence.isDolbyAtmos
            )
        }
        return highLevelStats + parseCoreAudioConsoleLogs(entries)
    }

    static func parseCoreAudioConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        var bitDepth: Int?
        
        var stats = [CMPlayerStats]()
        
        for entry in entries {
            let date = entry.date
            let rawMessage = entry.message

            if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                sampleRate = nil
                bitDepth = nil
            }
            
            if rawMessage.contains("ACAppleLosslessDecoder.cpp") && rawMessage.contains("Input format:") {
                if let subSampleRate = rawMessage.firstSubstring(between: "ch, ", and: " Hz") {
                    let strSampleRate = String(subSampleRate).trimmingCharacters(in: .whitespacesAndNewlines)
                    sampleRate = Double(strSampleRate)
                }
                
                if let subBitDepth = rawMessage.firstSubstring(between: "from ", and: "-bit source") {
                    let strBitDepth = String(subBitDepth).trimmingCharacters(in: .whitespacesAndNewlines)
                    bitDepth = Int(strBitDepth)
                }
            }
            
            if let sr = sampleRate,
               let bd = bitDepth {
                let stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: date)
                stats.append(stat)
                sampleRate = nil
                bitDepth = nil
                Logger.switching.info("detected stat \(stat)")
                break
            }
            
            lastDate = date
            
        }
        return stats
    }

    /// Parses AudioQueue "New output" entries, which report the decoded
    /// (source) sample rate for players that render through AudioQueue
    /// without resampling - e.g. Electron-based apps such as NetEase
    /// CloudMusic (process "NeteaseMusic"). Bit depth is taken from the
    /// companion "lpcm ... N-bit" converter line when present.
    static func parseAudioQueueConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        var bitDepth: Int?

        var stats = [CMPlayerStats]()

        for entry in entries {
            let date = entry.date
            let rawMessage = entry.message

            if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                sampleRate = nil
                bitDepth = nil
            }

            // "AudioQueueObject.cpp:488 ... New output; format  2 ch,  96000 Hz, Float32, ..."
            if rawMessage.contains("New output"), rawMessage.contains("AudioQueueObject"),
               let sub = rawMessage.firstSubstring(between: "format ", and: " Hz") {
                let strSampleRate = String(sub).trimmingCharacters(in: .whitespacesAndNewlines)
                if let ratePart = strSampleRate.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) {
                    sampleRate = Double(ratePart)
                }
            }

            // "from  2 ch,  96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to ..."
            if rawMessage.contains("lpcm"),
               let sub = rawMessage.firstSubstring(between: "lpcm", and: "-bit") {
                let strBitDepth = String(sub).trimmingCharacters(in: .whitespacesAndNewlines)
                if let depthPart = strBitDepth.split(separator: " ").last {
                    bitDepth = Int(depthPart)
                }
            }
            // NetEase/QQ via AudioConverter: "from  2 ch,  48000 Hz, lpcm (0x...) 24-bit ... to ..."
            // New output may be missing or reflect hardware rate, so also extract source rate from the
            // converter's "from ... Hz, lpcm" line. Prefer lpcm source rate when present (decoded source).
            if rawMessage.contains("AudioConverter") && rawMessage.contains("from ") && rawMessage.contains("lpcm") {
                if let sub = rawMessage.firstSubstring(between: "from ", and: " Hz,") {
                    let str = String(sub).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let ratePart = str.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                       let r = Double(ratePart), r > 0 {
                        sampleRate = r
                    }
                }
            }

            if let sr = sampleRate, sr > 0 {
                let stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth, date: date)
                stats.append(stat)
                sampleRate = nil
                bitDepth = nil
                Logger.switching.info("detected audioqueue stat \(stat)")
                break
            }

            lastDate = date

        }
        return stats
    }


}
