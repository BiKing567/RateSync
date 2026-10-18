import Foundation
import os

struct SharedAudioFormat: Equatable {
    let sampleRate: Float64
    let bitDepth: Int?
    let updatedAt: Date

    var sampleRateText: String {
        String(format: "%.1f kHz", sampleRate / 1_000)
    }

    var bitDepthText: String {
        bitDepth.map { "\($0) bit" } ?? "— bit"
    }
}

struct SharedNowPlayingTrack: Equatable {
    let title: String?
    let artist: String?
    let artworkDataBase64: String?
    let updatedAt: Date

    var titleText: String {
        normalized(title, fallback: NSLocalizedString("Not Playing", comment: "Widget placeholder when no track is playing"))
    }

    var artistText: String {
        normalized(artist, fallback: NSLocalizedString("No Artist", comment: "Widget placeholder when artist is unavailable"))
    }

    private func normalized(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value
    }
}

enum RateSyncWidgetConfiguration {
    static let widgetKind = "RateSyncAudioFormatWidget"
    static let launchRefreshDelays: [TimeInterval] = [0, 5, 15]
    static let widgetExecutableName = "RateSyncWidget"
    static let fallbackRefreshInterval: TimeInterval = 3
    static let maxArtworkDataBytes = 4 * 1024 * 1024
    static let maxArtworkBase64Length = ((maxArtworkDataBytes + 2) / 3) * 4
    private static let widgetBundleIdentifier = "com.biking.RateSync.Widget"

    struct WidgetState: Codable, Equatable {
        var sampleRate: Double?
        var bitDepth: Int?
        var formatUpdatedAt: Date?
        var title: String?
        var artist: String?
        var artworkDataBase64: String?
        var trackUpdatedAt: Date?
        var formatClearedAt: Date?
        var trackClearedAt: Date?

        init(
            sampleRate: Double? = nil,
            bitDepth: Int? = nil,
            formatUpdatedAt: Date? = nil,
            title: String? = nil,
            artist: String? = nil,
            artworkDataBase64: String? = nil,
            trackUpdatedAt: Date? = nil,
            formatClearedAt: Date? = nil,
            trackClearedAt: Date? = nil
        ) {
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.formatUpdatedAt = formatUpdatedAt
            self.title = title
            self.artist = artist
            self.artworkDataBase64 = artworkDataBase64
            self.trackUpdatedAt = trackUpdatedAt
            self.formatClearedAt = formatClearedAt
            self.trackClearedAt = trackClearedAt
        }
    }

    private static let sampleRateKey = "widgetSampleRate"
    private static let bitDepthKey = "widgetBitDepth"
    private static let formatUpdatedAtKey = "widgetUpdatedAt"
    private static let titleKey = "nowPlaying.title"
    private static let artistKey = "nowPlaying.artist"
    private static let artworkKey = "nowPlaying.artworkDataBase64"
    private static let updatedAtKey = "nowPlaying.updatedAt"
    private static let formatClearedAtKey = "widgetFormatClearedAt"
    private static let trackClearedAtKey = "nowPlaying.clearedAt"
    private static let stateFileName = "ratesync-widget-state.plist"
    private static let legacyGroupIdentifier = "group.com.biking.RateSync"
    private static let logger = Logger(subsystem: "com.biking.RateSync", category: "widget-storage")

    private static var realUserHomeURL: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let path = FileManager.default.string(withFileSystemRepresentation: home, length: Int(strlen(home)))
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var sharedApplicationSupportStateURL: URL {
        realUserHomeURL
            .appendingPathComponent("Library/Application Support/RateSync", isDirectory: true)
            .appendingPathComponent(stateFileName)
    }

    static var localWidgetStateURL: URL {
        let applicationSupportURL: URL
        if Bundle.main.bundleIdentifier == widgetBundleIdentifier,
           let extensionApplicationSupportURL = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first {
            applicationSupportURL = extensionApplicationSupportURL
        } else {
            applicationSupportURL = realUserHomeURL
                .appendingPathComponent(
                    "Library/Containers/\(widgetBundleIdentifier)/Data/Library/Application Support",
                    isDirectory: true
                )
        }
        return applicationSupportURL
            .appendingPathComponent("RateSync", isDirectory: true)
            .appendingPathComponent(stateFileName)
    }

    static func nextRefreshDate(after date: Date) -> Date {
        date.addingTimeInterval(fallbackRefreshInterval)
    }

    static func preferredAudioFormat(
        persisted: SharedAudioFormat?,
        live: SharedAudioFormat?
    ) -> SharedAudioFormat? {
        live ?? persisted
    }

    static func widgetAudioFormat(persisted: SharedAudioFormat?) -> SharedAudioFormat? {
        persisted
    }

    static func loadNowPlayingTrack() -> SharedNowPlayingTrack? {
        guard let state = loadState(), let updatedAt = state.trackUpdatedAt else {
            return nil
        }
        if let clearedAt = state.trackClearedAt, clearedAt >= updatedAt {
            return nil
        }
        return SharedNowPlayingTrack(
            title: state.title,
            artist: state.artist,
            artworkDataBase64: state.artworkDataBase64,
            updatedAt: updatedAt
        )
    }

    static func loadAudioFormat() -> SharedAudioFormat? {
        guard let state = loadState(),
              let sampleRate = state.sampleRate,
              let updatedAt = state.formatUpdatedAt else {
            return nil
        }
        if let clearedAt = state.formatClearedAt, clearedAt >= updatedAt {
            return nil
        }
        return SharedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: state.bitDepth,
            updatedAt: updatedAt
        )
    }

    static func migrateLegacyState() {
        guard Bundle.main.bundleIdentifier != widgetBundleIdentifier else { return }

        let existing = loadState()
        let legacyStates = legacyStateURLs.compactMap { readState(at: $0) }
        let legacyPreferenceStates = legacyPreferencesURLs
            .compactMap { loadLegacyValues(at: $0) }
            .compactMap { state(from: $0) }
        guard let state = mergeStates(
            ([existing] + legacyStates + legacyPreferenceStates).compactMap { $0 }
        ), state != existing else { return }
        saveState(state)
    }

    static func saveAudioFormat(sampleRate: Double, bitDepth: Int?, updatedAt: Date = Date()) {
        guard sampleRate.isFinite, sampleRate > 0 else {
            clearAudioFormat(clearedAt: updatedAt)
            return
        }
        var state = loadState() ?? WidgetState()
        state.sampleRate = sampleRate
        state.bitDepth = bitDepth
        state.formatUpdatedAt = updatedAt
        state.formatClearedAt = nil
        saveState(state)
    }

    static func clearAudioFormat(clearedAt: Date = Date()) {
        var state = loadState() ?? WidgetState()
        state.sampleRate = nil
        state.bitDepth = nil
        state.formatUpdatedAt = nil
        state.formatClearedAt = clearedAt
        saveState(state)
    }

    static func saveNowPlayingTrack(
        title: String?,
        artist: String?,
        artworkDataBase64: String?,
        updatedAt: Date = Date()
    ) {
        var state = loadState() ?? WidgetState()
        state.title = title
        state.artist = artist
        state.artworkDataBase64 = sanitizedArtworkDataBase64(artworkDataBase64)
        state.trackUpdatedAt = updatedAt
        state.trackClearedAt = nil
        saveState(state)
    }

    static func clearNowPlayingTrack(clearedAt: Date = Date()) {
        var state = loadState() ?? WidgetState()
        state.title = nil
        state.artist = nil
        state.artworkDataBase64 = nil
        state.trackUpdatedAt = nil
        state.trackClearedAt = clearedAt
        saveState(state)
    }

    static func sanitizedArtworkDataBase64(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= maxArtworkBase64Length,
              let data = Data(base64Encoded: value),
              data.count <= maxArtworkDataBytes else {
            return nil
        }
        return value
    }

    private static var legacyGroupContainerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(legacyGroupIdentifier, isDirectory: true)
    }

    private static var legacyStateURLs: [URL] {
        [
            legacyGroupContainerURL
                .appendingPathComponent("Library/Application Support/RateSync", isDirectory: true)
                .appendingPathComponent(stateFileName),
        ]
    }

    private static var legacyPreferencesURLs: [URL] {
        [
            legacyGroupContainerURL
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(legacyGroupIdentifier).plist"),
        ]
    }

    private static var stateURLs: [URL] {
        [sharedApplicationSupportStateURL, localWidgetStateURL]
    }

    static var stateStorageURLs: [URL] {
        stateURLs
    }

    private static func readState(at url: URL) -> WidgetState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(WidgetState.self, from: data)
    }

    private static func loadLegacyValues(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) else { return nil }
        return propertyList as? [String: Any]
    }

    static func mergeStates(_ states: [WidgetState]) -> WidgetState? {
        guard !states.isEmpty else { return nil }

        // Format resolution: compare newest set vs newest cleared
        let newestFormatSet = states
            .filter { state in
                guard let sampleRate = state.sampleRate,
                      sampleRate.isFinite,
                      sampleRate > 0 else {
                    return false
                }
                return state.formatUpdatedAt != nil
            }
            .max {
                ($0.formatUpdatedAt ?? .distantPast) < ($1.formatUpdatedAt ?? .distantPast)
            }

        let newestFormatCleared = states
            .filter { $0.formatClearedAt != nil }
            .max {
                ($0.formatClearedAt ?? .distantPast) < ($1.formatClearedAt ?? .distantPast)
            }

        let isFormatCleared: Bool = {
            guard let clearedAt = newestFormatCleared?.formatClearedAt else { return false }
            let setAt = newestFormatSet?.formatUpdatedAt ?? .distantPast
            return clearedAt >= setAt
        }()

        let effectiveFormat = isFormatCleared ? nil : newestFormatSet
        let effectiveFormatClearedAt = isFormatCleared ? newestFormatCleared?.formatClearedAt : nil

        // Track resolution: compare newest set vs newest cleared
        let newestTrackSet = states
            .filter { $0.trackUpdatedAt != nil }
            .max {
                ($0.trackUpdatedAt ?? .distantPast) < ($1.trackUpdatedAt ?? .distantPast)
            }

        let newestTrackCleared = states
            .filter { $0.trackClearedAt != nil }
            .max {
                ($0.trackClearedAt ?? .distantPast) < ($1.trackClearedAt ?? .distantPast)
            }

        let isTrackCleared: Bool = {
            guard let clearedAt = newestTrackCleared?.trackClearedAt else { return false }
            let setAt = newestTrackSet?.trackUpdatedAt ?? .distantPast
            return clearedAt >= setAt
        }()

        let effectiveTrack = isTrackCleared ? nil : newestTrackSet
        let effectiveTrackClearedAt = isTrackCleared ? newestTrackCleared?.trackClearedAt : nil

        let merged = WidgetState(
            sampleRate: effectiveFormat?.sampleRate,
            bitDepth: effectiveFormat?.bitDepth,
            formatUpdatedAt: effectiveFormat?.formatUpdatedAt,
            title: effectiveTrack?.title,
            artist: effectiveTrack?.artist,
            artworkDataBase64: effectiveTrack?.artworkDataBase64,
            trackUpdatedAt: effectiveTrack?.trackUpdatedAt,
            formatClearedAt: effectiveFormatClearedAt,
            trackClearedAt: effectiveTrackClearedAt
        )
        return merged.formatUpdatedAt != nil || merged.trackUpdatedAt != nil ||
               merged.formatClearedAt != nil || merged.trackClearedAt != nil
            ? merged
            : nil
    }

    static func mergePersistedStates(
        fileStates: [WidgetState],
        sharedDefaultsState: WidgetState?
    ) -> WidgetState? {
        mergeStates(fileStates + [sharedDefaultsState].compactMap { $0 })
    }

    private static func loadState() -> WidgetState? {
        let fileStates = stateURLs.compactMap { readState(at: $0) }
        return mergeStates(fileStates)
    }

    private static func state(from values: [String: Any]) -> WidgetState? {
        let state = WidgetState(
            sampleRate: (values[sampleRateKey] as? NSNumber)?.doubleValue,
            bitDepth: (values[bitDepthKey] as? NSNumber)?.intValue,
            formatUpdatedAt: values[formatUpdatedAtKey] as? Date,
            title: values[titleKey] as? String,
            artist: values[artistKey] as? String,
            artworkDataBase64: sanitizedArtworkDataBase64(values[artworkKey] as? String),
            trackUpdatedAt: values[updatedAtKey] as? Date,
            formatClearedAt: values[formatClearedAtKey] as? Date,
            trackClearedAt: values[trackClearedAtKey] as? Date
        )
        guard state.formatUpdatedAt != nil || state.trackUpdatedAt != nil ||
              state.formatClearedAt != nil || state.trackClearedAt != nil else {
            return nil
        }
        return state
    }

    private static func saveState(_ state: WidgetState) {
        guard let data = try? PropertyListEncoder().encode(state) else {
            logger.error("Failed to encode widget state")
            return
        }
        for stateURL in stateURLs {
            do {
                try FileManager.default.createDirectory(
                    at: stateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: stateURL, options: .atomic)
            } catch {
                logger.debug("Failed to write widget state to \(stateURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

}
