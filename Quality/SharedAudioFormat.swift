import Foundation

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
    static let fallbackRefreshInterval: TimeInterval = 3
    static let maxArtworkDataBytes = 4 * 1024 * 1024
    static let maxArtworkBase64Length = ((maxArtworkDataBytes + 2) / 3) * 4
    static let appGroupIdentifier = "group.com.biking.RateSync"
    private static let widgetBundleIdentifier = "com.biking.RateSync.Widget"

    struct WidgetState: Codable, Equatable {
        var sampleRate: Double?
        var bitDepth: Int?
        var formatUpdatedAt: Date?
        var title: String?
        var artist: String?
        var artworkDataBase64: String?
        var trackUpdatedAt: Date?
    }

    private static let sampleRateKey = "widgetSampleRate"
    private static let bitDepthKey = "widgetBitDepth"
    private static let formatUpdatedAtKey = "widgetUpdatedAt"
    private static let titleKey = "nowPlaying.title"
    private static let artistKey = "nowPlaying.artist"
    private static let artworkKey = "nowPlaying.artworkDataBase64"
    private static let updatedAtKey = "nowPlaying.updatedAt"
    private static let stateFileName = "ratesync-widget-state.plist"

    static var localWidgetStateURL: URL {
        let applicationSupportURL: URL
        if Bundle.main.bundleIdentifier == widgetBundleIdentifier,
           let extensionApplicationSupportURL = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first {
            applicationSupportURL = extensionApplicationSupportURL
        } else {
            applicationSupportURL = FileManager.default.homeDirectoryForCurrentUser
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

    static func loadNowPlayingTrack() -> SharedNowPlayingTrack? {
        if let state = loadState(), let updatedAt = state.trackUpdatedAt {
            return SharedNowPlayingTrack(
                title: state.title,
                artist: state.artist,
                artworkDataBase64: state.artworkDataBase64,
                updatedAt: updatedAt
            )
        }

        if let values = loadLegacyValues(),
           let updatedAt = values[updatedAtKey] as? Date {
            return SharedNowPlayingTrack(
                title: values[titleKey] as? String,
                artist: values[artistKey] as? String,
                artworkDataBase64: values[artworkKey] as? String,
                updatedAt: updatedAt
            )
        }

        guard let defaults = sharedDefaults,
              let updatedAt = defaults.object(forKey: updatedAtKey) as? Date else {
            return nil
        }

        return SharedNowPlayingTrack(
            title: defaults.string(forKey: titleKey),
            artist: defaults.string(forKey: artistKey),
            artworkDataBase64: defaults.string(forKey: artworkKey),
            updatedAt: updatedAt
        )
    }

    static func loadAudioFormat() -> SharedAudioFormat? {
        if let state = loadState(),
           let sampleRate = state.sampleRate,
           let updatedAt = state.formatUpdatedAt {
            return SharedAudioFormat(
                sampleRate: sampleRate,
                bitDepth: state.bitDepth,
                updatedAt: updatedAt
            )
        }

        if let values = loadLegacyValues(),
           let updatedAt = values[formatUpdatedAtKey] as? Date,
           let sampleRate = (values[sampleRateKey] as? NSNumber)?.doubleValue,
           sampleRate > 0 {
            return SharedAudioFormat(
                sampleRate: sampleRate,
                bitDepth: (values[bitDepthKey] as? NSNumber)?.intValue,
                updatedAt: updatedAt
            )
        }

        guard let defaults = sharedDefaults,
              let updatedAt = defaults.object(forKey: formatUpdatedAtKey) as? Date else {
            return nil
        }
        let sampleRate = defaults.double(forKey: sampleRateKey)
        guard sampleRate > 0 else { return nil }
        return SharedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: defaults.object(forKey: bitDepthKey) as? Int,
            updatedAt: updatedAt
        )
    }

    static func migrateLegacyState() {
        let existing = loadState()
        let values = loadLegacyValues()
        let defaults = sharedDefaults
        let state = WidgetState(
            sampleRate: existing?.sampleRate
                ?? (values?[sampleRateKey] as? NSNumber)?.doubleValue
                ?? defaults?.double(forKey: sampleRateKey),
            bitDepth: existing?.bitDepth
                ?? (values?[bitDepthKey] as? NSNumber)?.intValue
                ?? defaults?.object(forKey: bitDepthKey) as? Int,
            formatUpdatedAt: existing?.formatUpdatedAt
                ?? values?[formatUpdatedAtKey] as? Date
                ?? defaults?.object(forKey: formatUpdatedAtKey) as? Date,
            title: existing?.title
                ?? values?[titleKey] as? String
                ?? defaults?.string(forKey: titleKey),
            artist: existing?.artist
                ?? values?[artistKey] as? String
                ?? defaults?.string(forKey: artistKey),
            artworkDataBase64: existing?.artworkDataBase64
                ?? values?[artworkKey] as? String
                ?? defaults?.string(forKey: artworkKey),
            trackUpdatedAt: existing?.trackUpdatedAt
                ?? values?[updatedAtKey] as? Date
                ?? defaults?.object(forKey: updatedAtKey) as? Date
        )
        guard state.formatUpdatedAt != nil || state.trackUpdatedAt != nil else { return }
        guard state != existing else { return }
        saveState(state)
    }

    static func saveAudioFormat(sampleRate: Double, bitDepth: Int?, updatedAt: Date = Date()) {
        guard sampleRate.isFinite, sampleRate > 0 else {
            clearAudioFormat()
            return
        }
        var state = loadState() ?? WidgetState(
            sampleRate: nil,
            bitDepth: nil,
            formatUpdatedAt: nil,
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        state.sampleRate = sampleRate
        state.bitDepth = bitDepth
        state.formatUpdatedAt = updatedAt
        saveState(state)

        guard let defaults = sharedDefaults else { return }
        defaults.set(sampleRate, forKey: sampleRateKey)
        set(bitDepth, forKey: bitDepthKey, in: defaults)
        defaults.set(updatedAt, forKey: formatUpdatedAtKey)
        defaults.synchronize()
    }

    static func clearAudioFormat() {
        var state = loadState() ?? WidgetState(
            sampleRate: nil,
            bitDepth: nil,
            formatUpdatedAt: nil,
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        state.sampleRate = nil
        state.bitDepth = nil
        state.formatUpdatedAt = nil
        saveState(state)

        guard let defaults = sharedDefaults else { return }
        [sampleRateKey, bitDepthKey, formatUpdatedAtKey].forEach {
            defaults.removeObject(forKey: $0)
        }
        defaults.synchronize()
    }

    static func saveNowPlayingTrack(
        title: String?,
        artist: String?,
        artworkDataBase64: String?,
        updatedAt: Date = Date()
    ) {
        var state = loadState() ?? WidgetState(
            sampleRate: nil,
            bitDepth: nil,
            formatUpdatedAt: nil,
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        state.title = title
        state.artist = artist
        state.artworkDataBase64 = sanitizedArtworkDataBase64(artworkDataBase64)
        state.trackUpdatedAt = updatedAt
        saveState(state)

        guard let defaults = sharedDefaults else { return }
        set(title, forKey: titleKey, in: defaults)
        set(artist, forKey: artistKey, in: defaults)
        set(state.artworkDataBase64, forKey: artworkKey, in: defaults)
        defaults.set(updatedAt, forKey: updatedAtKey)
        defaults.synchronize()
    }

    static func clearNowPlayingTrack() {
        var state = loadState() ?? WidgetState(
            sampleRate: nil,
            bitDepth: nil,
            formatUpdatedAt: nil,
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        state.title = nil
        state.artist = nil
        state.artworkDataBase64 = nil
        state.trackUpdatedAt = nil
        saveState(state)

        guard let defaults = sharedDefaults else { return }
        [titleKey, artistKey, artworkKey, updatedAtKey].forEach {
            defaults.removeObject(forKey: $0)
        }
        defaults.synchronize()
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

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
    }

    private static var stateURL: URL? {
        guard let containerURL = appGroupContainerURL else { return nil }
        return containerURL
            .appendingPathComponent("Library/Application Support/RateSync", isDirectory: true)
            .appendingPathComponent(stateFileName)
    }

    private static var legacyPreferencesURL: URL? {
        appGroupContainerURL?.appendingPathComponent(
            "Library/Preferences/\(appGroupIdentifier).plist"
        )
    }

    private static var stateURLs: [URL] {
        [stateURL, localWidgetStateURL].compactMap { $0 }
    }

    private static func loadLegacyValues() -> [String: Any]? {
        guard let legacyPreferencesURL,
              let data = try? Data(contentsOf: legacyPreferencesURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) else { return nil }
        return propertyList as? [String: Any]
    }

    static func mergeStates(_ states: [WidgetState]) -> WidgetState? {
        guard !states.isEmpty else { return nil }

        let newestFormat = states
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
        let newestTrack = states
            .filter { $0.trackUpdatedAt != nil }
            .max {
                ($0.trackUpdatedAt ?? .distantPast) < ($1.trackUpdatedAt ?? .distantPast)
            }
        let merged = WidgetState(
            sampleRate: newestFormat?.sampleRate,
            bitDepth: newestFormat?.bitDepth,
            formatUpdatedAt: newestFormat?.formatUpdatedAt,
            title: newestTrack?.title,
            artist: newestTrack?.artist,
            artworkDataBase64: newestTrack?.artworkDataBase64,
            trackUpdatedAt: newestTrack?.trackUpdatedAt
        )
        return merged.formatUpdatedAt != nil || merged.trackUpdatedAt != nil
            ? merged
            : nil
    }

    private static func loadState() -> WidgetState? {
        let states = stateURLs.compactMap { stateURL -> WidgetState? in
            guard let data = try? Data(contentsOf: stateURL) else { return nil }
            return try? PropertyListDecoder().decode(WidgetState.self, from: data)
        }
        return mergeStates(states)
    }

    private static func saveState(_ state: WidgetState) {
        guard let data = try? PropertyListEncoder().encode(state) else { return }
        for stateURL in stateURLs {
            try? FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private static func set(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func set(_ value: Int?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
