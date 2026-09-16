import Foundation

struct PlayerProfile: Equatable, Identifiable {
    enum FormatDetection: Equatable {
        case mediaRemoteThenLogs
        case audioQueueLogs
    }

    let bundleIdentifier: String
    let localizationKey: String
    let processName: String
    let formatDetection: FormatDetection
    let fallbackSampleRate: Double?

    var displayName: String { localizationKey }

    var id: String { bundleIdentifier }

    static let appleMusic = PlayerProfile(
        bundleIdentifier: "com.apple.Music",
        localizationKey: "Apple Music",
        processName: "Music",
        formatDetection: .mediaRemoteThenLogs,
        fallbackSampleRate: nil
    )
    static let spotify = PlayerProfile(
        bundleIdentifier: "com.spotify.client",
        localizationKey: "Spotify",
        processName: "Spotify",
        formatDetection: .mediaRemoteThenLogs,
        fallbackSampleRate: 44_100
    )
    static let neteaseMusic = PlayerProfile(
        bundleIdentifier: "com.netease.163music",
        localizationKey: "NetEase Music",
        processName: "NeteaseMusic",
        formatDetection: .audioQueueLogs,
        fallbackSampleRate: nil
    )
    static let qqMusic = PlayerProfile(
        bundleIdentifier: "com.tencent.QQMusicMac",
        localizationKey: "QQ Music",
        processName: "QQMusic",
        formatDetection: .audioQueueLogs,
        fallbackSampleRate: nil
    )

    static let monitoringSources = [appleMusic, spotify, neteaseMusic, qqMusic]

    /// Default takeover order used when the user selects "All Apps".
    /// Keeping Apple Music first preserves the behaviour users already had
    /// before multi-player arbitration was introduced.
    static let defaultPriorityBundleIdentifiers = monitoringSources.map(\.bundleIdentifier)

    static func normalizedPriority(_ bundleIdentifiers: [String]) -> [String] {
        var result: [String] = []
        for identifier in bundleIdentifiers {
            guard monitoringSources.contains(where: { $0.bundleIdentifier == identifier }),
                  !result.contains(identifier) else {
                continue
            }
            result.append(identifier)
        }

        for identifier in defaultPriorityBundleIdentifiers where !result.contains(identifier) {
            result.append(identifier)
        }
        return result
    }

    static func profile(for bundleIdentifier: String?) -> PlayerProfile? {
        monitoringSources.first { $0.bundleIdentifier == bundleIdentifier }
    }

    static func bundleIdentifier(forProcessName processName: String) -> String? {
        monitoringSources.first { $0.processName == processName }?.bundleIdentifier
    }
}
