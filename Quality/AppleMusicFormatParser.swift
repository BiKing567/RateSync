import Foundation

struct AppleMusicLogEntry {
    let date: Date
    let message: String
}

struct AppleMusicFormatEvidence: Equatable {
    let sampleRate: Double
    let bitDepth: Int?
    let date: Date
    let isDolbyAtmos: Bool
    let isSpatialAudio: Bool
}

enum AppleMusicFormatParser {
    static let logWindowSeconds: TimeInterval = 15

    static func parse(_ entries: [AppleMusicLogEntry]) -> [AppleMusicFormatEvidence] {
        let highLevelFormats = entries.compactMap(parseHighLevelFormat)
        let dolbyFormats = highLevelFormats.filter(\.isDolbyAtmos)
        let spatialAudioFormats = highLevelFormats.filter { !$0.isDolbyAtmos && $0.isSpatialAudio }
        let otherFormats = highLevelFormats.filter { !$0.isDolbyAtmos && !$0.isSpatialAudio }
        return dolbyFormats + spatialAudioFormats + otherFormats
    }

    private static func parseHighLevelFormat(_ entry: AppleMusicLogEntry) -> AppleMusicFormatEvidence? {
        guard entry.message.contains("asbdFormatID =") else { return nil }
        guard let rawSampleRate = value(after: "asbdSampleRate = ", before: " kHz", in: entry.message),
              let sampleRateInKHz = Double(rawSampleRate),
              sampleRateInKHz.isFinite,
              sampleRateInKHz > 0 else {
            return nil
        }

        let rawBitDepth = value(after: "sdBitDepth = ", before: " bit", in: entry.message)
        let bitDepth = rawBitDepth.flatMap(Int.init)
        let isSpatialAudio = entry.message.localizedCaseInsensitiveContains("is rendering spatial audio")
        let isDolbyAtmos = entry.message.localizedCaseInsensitiveContains("original is Atmos")
            || entry.message.localizedCaseInsensitiveContains("Dolby Atmos")
            || entry.message.localizedCaseInsensitiveContains("is Atmos")
        return AppleMusicFormatEvidence(
            sampleRate: sampleRateInKHz * 1_000,
            bitDepth: bitDepth,
            date: entry.date,
            isDolbyAtmos: isDolbyAtmos,
            isSpatialAudio: isSpatialAudio
        )
    }

    private static func value(after marker: String, before terminator: String, in message: String) -> String? {
        guard let start = message.range(of: marker)?.upperBound,
              let end = message.range(of: terminator, range: start..<message.endIndex)?.lowerBound else {
            return nil
        }
        return String(message[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
