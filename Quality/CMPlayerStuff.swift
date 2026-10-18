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
    let isSpatialAudio: Bool

    var isPriorityAppleMusicFormat: Bool {
        isDolbyAtmos || isSpatialAudio
    }

    init(
        sampleRate: Double,
        bitDepth: Int?,
        date: Date,
        isAppleMusicFormat: Bool = false,
        isDolbyAtmos: Bool = false,
        isSpatialAudio: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.date = date
        self.isAppleMusicFormat = isAppleMusicFormat
        self.isDolbyAtmos = isDolbyAtmos
        self.isSpatialAudio = isSpatialAudio
    }

    static func sampleRateOnly(
        sampleRate: Double,
        bitDepth: Int? = nil,
        date: Date = Date()
    ) -> CMPlayerStats {
        CMPlayerStats(sampleRate: sampleRate, bitDepth: bitDepth, date: date)
    }
}

extension CMPlayerStats: CustomStringConvertible {
    var description: String {
        let bitDepthDescription = bitDepth.map { String($0) } ?? "unknown"
        return "CMPlayerStats(sampleRate: \(sampleRate), bitDepth: \(bitDepthDescription), appleMusicFormat: \(isAppleMusicFormat), dolbyAtmos: \(isDolbyAtmos), spatialAudio: \(isSpatialAudio))"
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
                isDolbyAtmos: evidence.isDolbyAtmos,
                isSpatialAudio: evidence.isSpatialAudio
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
                RateSyncLog.switching.info("detected stat \(stat)")
                break
            }
            
            lastDate = date
            
        }
        return stats
    }

    /// Parses AudioQueue "New output" entries, which report the decoded
    /// (source) sample rate for players that render through AudioQueue
    /// without resampling - e.g. Electron-based apps such as NetEase
    /// Parses AudioQueue console logs.
    /// Priority is given to decoded source format lines from AudioConverter (LPCM lines
    /// reporting "from ... Hz, lpcm ... N-bit"), which represent the true decoded stream format.
    /// "AudioQueueObject ... New output" entries report the AudioQueue output format configured
    /// to match the destination/hardware device.
    ///
    /// Companion correlation:
    /// - An AudioQueueObject output stat is only suppressed if a genuine companion AudioConverter
    ///   stat exists within the same tight initialization window (<= 1.0s) AND converts to
    ///   the same hardware rate (matching session).
    /// - Stale converter logs from previous tracks (e.g. t - 3s) must not suppress new track outputs.
    static func parseAudioQueueConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        parseAudioQueueConsoleLogs(entries, since: nil)
    }

    static func parseAudioQueueConsoleLogs(
        _ entries: [SimpleConsole],
        since: Date?
    ) -> [CMPlayerStats] {
        let kCompanionMaxTimeDelta = 1.0 // seconds

        let filteredEntries = entries.filter { entry in
            guard let since = since else { return true }
            return entry.date >= since
        }

        var converterEvidences: [(stat: CMPlayerStats, targetRate: Double?)] = []
        var queueStats: [CMPlayerStats] = []

        for entry in filteredEntries {
            let date = entry.date
            let rawMessage = entry.message

            // 1. Decoded LPCM source evidence from AudioConverter:
            // "AudioConverter from  2 ch,  96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 48000 Hz, Float32"
            // or "from  2 ch,  96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to ..."
            if rawMessage.contains("lpcm") && rawMessage.contains("from ") && rawMessage.contains(" Hz") {
                var sampleRate: Double?
                var bitDepth: Int?
                var targetRate: Double?

                if let fromRange = rawMessage.range(of: "from "),
                   let hzRange = rawMessage.range(of: " Hz", range: fromRange.upperBound..<rawMessage.endIndex) {
                    let sub = rawMessage[fromRange.upperBound..<hzRange.lowerBound]
                    if let ratePart = sub.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                       let r = Double(ratePart), r > 0 {
                        sampleRate = r
                    }
                }

                if let lpcmRange = rawMessage.range(of: "lpcm"),
                   let bitRange = rawMessage.range(of: "-bit", range: lpcmRange.upperBound..<rawMessage.endIndex) {
                    let sub = rawMessage[lpcmRange.upperBound..<bitRange.lowerBound]
                    if let depthPart = sub.split(separator: " ").last,
                       let bd = Int(depthPart), bd > 0 {
                        bitDepth = bd
                    }
                }

                if let toRange = rawMessage.range(of: "to "),
                   let targetHzRange = rawMessage.range(of: " Hz", range: toRange.upperBound..<rawMessage.endIndex) {
                    let sub = rawMessage[toRange.upperBound..<targetHzRange.lowerBound]
                    if let ratePart = sub.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                       let tr = Double(ratePart), tr > 0 {
                        targetRate = tr
                    }
                }

                if let sr = sampleRate {
                    let stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth, date: date)
                    converterEvidences.append((stat: stat, targetRate: targetRate))
                }
            }

            // 2. AudioQueueObject "New output" output-format log:
            // "AudioQueueObject.cpp:488 New output; format  2 ch,  96000 Hz, Float32, ..."
            if rawMessage.contains("New output") && rawMessage.contains("AudioQueueObject") {
                if let formatRange = rawMessage.range(of: "format "),
                   let hzRange = rawMessage.range(of: " Hz", range: formatRange.upperBound..<rawMessage.endIndex) {
                    let sub = rawMessage[formatRange.upperBound..<hzRange.lowerBound]
                    if let ratePart = sub.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                       let r = Double(ratePart), r > 0 {
                        queueStats.append(CMPlayerStats(sampleRate: r, bitDepth: nil, date: date))
                    }
                }
            }
        }

        // An AudioQueueObject output stat is only retained if no companion LPCM source converter
        // stat exists within the tight initialization window (<= 1.0s) for that playback session.
        let standaloneQueueStats = queueStats.filter { qStat in
            !converterEvidences.contains { conv in
                let timeDelta = abs(conv.stat.date.timeIntervalSince(qStat.date))
                guard timeDelta <= kCompanionMaxTimeDelta else { return false }
                if let targetRate = conv.targetRate {
                    return abs(targetRate - qStat.sampleRate) < 1.0
                }
                return true
            }
        }

        let converterStats = converterEvidences.map { $0.stat }
        let combined = (converterStats + standaloneQueueStats).sorted(by: { $0.date > $1.date })
        if let first = combined.first {
            RateSyncLog.switching.info("detected audioqueue stat \(first)")
        }
        return combined
    }


}
