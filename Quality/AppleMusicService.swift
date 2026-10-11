//
//  AppleMusicService.swift
//  RateSync
//

import ApplicationServices
import AppKit
import OSLog

/// Encapsulates Apple Music's AppleScript and UI-automation integration.
/// OutputDevices only decides when this service should be consulted.
final class AppleMusicService {
    struct PlaybackState {
        let isPlaying: Bool
        let sampleRate: Double?
    }

    private enum PlaybackStateReadResult {
        case playing(sampleRate: Double?)
        case notPlaying
        case unavailable

        var playbackState: PlaybackState? {
            switch self {
            case .playing(let sampleRate):
                return PlaybackState(isPlaying: true, sampleRate: sampleRate)
            case .notPlaying:
                return PlaybackState(isPlaying: false, sampleRate: nil)
            case .unavailable:
                return nil
            }
        }

        var sampleRateQueryResult: AppleMusicSampleRateQueryResult {
            switch self {
            case .playing(let sampleRate):
                if let sampleRate {
                    return .sampleRate(sampleRate)
                }
                return .missingValue
            case .notPlaying:
                return .notPlaying
            case .unavailable:
                return .unavailable
            }
        }
    }

    private var lastAppliedEQPreset: String?
    private let eqLock = NSLock()
    private let playbackQueue = DispatchQueue(label: "AppleMusicService.playback", qos: .userInitiated)
    private var cachedPlaybackState: (result: PlaybackStateReadResult, date: Date)?
    private static let playbackCacheTTL: TimeInterval = 0.25

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == PlayerProfile.appleMusic.bundleIdentifier
        }
    }

    func fetchPlaybackState(completion: @escaping (PlaybackState?) -> Void) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            completion(self.playbackStateReadResult().playbackState)
        }
    }

    /// Reads Apple Music's current track sample rate. A missing rate is distinct
    /// from a stopped player or an unavailable/permission-denied AppleScript API.
    func fetchCurrentTrackSampleRate(completion: @escaping (AppleMusicSampleRateQueryResult) -> Void) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            completion(self.playbackStateReadResult().sampleRateQueryResult)
        }
    }

    /// Prevents a cached response from the previous track from being reused by
    /// the next sample-rate request. Queue ordering makes invalidation precede
    /// any request enqueued after a MediaRemote track-change event.
    func invalidatePlaybackStateCache() {
        playbackQueue.async { [weak self] in
            self?.cachedPlaybackState = nil
        }
    }

    private func playbackStateReadResult() -> PlaybackStateReadResult {
        if let cachedPlaybackState,
           Date().timeIntervalSince(cachedPlaybackState.date) < Self.playbackCacheTTL {
            return cachedPlaybackState.result
        }

        let result = readPlaybackState()
        cachedPlaybackState = (result, Date())
        return result
    }

    private func readPlaybackState() -> PlaybackStateReadResult {
        let script = """
        tell application "Music"
            if player state is playing then
                set currentRate to sample rate of current track
                if currentRate is missing value then return "missing value"
                return currentRate as string
            end if
            return "not playing"
        end tell
        """
        guard let output = execute(script, logPrefix: "[AM state]") else { return .unavailable }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "not playing" { return .notPlaying }
        if value == "missing value" { return .playing(sampleRate: nil) }
        guard let sampleRate = Double(value),
              sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
            RateSyncLog.switching.info("[AM state] unavailable: invalid sample rate result")
            return .unavailable
        }
        return .playing(sampleRate: sampleRate)
    }

    func applyEQIfNeeded(isEnabled: Bool, isCurrentSource: Bool) {
        guard isEnabled else {
            RateSyncLog.switching.info("[EQ] skipped: switch off")
            return
        }
        guard isCurrentSource else {
            RateSyncLog.switching.info("[EQ] skipped: source is not Apple Music")
            return
        }
        guard isRunning else {
            RateSyncLog.switching.info("[EQ] skipped: Music is not running")
            return
        }
        guard let genre = currentGenre() else {
            RateSyncLog.switching.info("[EQ] skipped: no genre")
            return
        }
        guard let preset = Self.eqPreset(forGenre: genre) else {
            RateSyncLog.switching.info("[EQ] skipped: genre \(genre, privacy: .public) maps to no preset")
            return
        }

        eqLock.lock()
        let unchanged = preset == lastAppliedEQPreset
        if !unchanged {
            lastAppliedEQPreset = preset
        }
        eqLock.unlock()

        guard !unchanged else {
            RateSyncLog.switching.info("[EQ] skipped: preset \(preset, privacy: .public) already applied")
            return
        }
        RateSyncLog.switching.info("[EQ] genre \(genre, privacy: .public) -> preset \(preset, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            setEQ(preset)
        }
    }

    /// Maps a genre to a hardcoded, localized Apple Music EQ preset.
    /// Genre metadata is untrusted and is never interpolated into a script.
    static func eqPreset(forGenre genre: String?) -> String? {
        guard let genre else { return nil }
        let normalized = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "摇滚", "摇滚乐", "rock", "alternative", "punk", "metal", "hard rock", "j-rock", "jrock", "日语摇滚", "日本摇滚":
            return "摇滚乐"
        case "流行", "流行乐", "pop", "mandopop", "c-pop", "k-pop", "cpop", "kpop", "synthpop",
             "j-pop", "jpop", "japanese pop", "japanese", "日语流行", "日本流行", "日语", "日本",
             "anime", "动漫", "动画", "j-pop/anime", "city pop":
            return "流行乐"
        case "古典", "classical", "opera", "orchestra", "chamber", "symphony":
            return "古典"
        case "爵士", "爵士乐", "jazz", "swing", "blues", "bebop":
            return "爵士乐"
        case "嘻哈", "嘻哈音乐", "说唱", "rap", "hip hop", "hip-hop", "hiphop", "trap", "grime":
            return "嘻哈音乐"
        case "电子", "电子乐", "electronic", "edm", "techno", "house", "trance", "dubstep", "ambient", "chillout":
            return "电子乐"
        case "舞曲", "dance", "disco", "club":
            return "舞曲"
        case "民谣", "原声", "acoustic", "folk", "country", "indie folk", "民乐":
            return "原声"
        case "r&b", "rnb", "soul", "funk", "neo soul":
            return "R&B"
        case "钢琴", "piano", "instrumental", "new age", "solo piano", "纯音乐", "轻音乐":
            return "钢琴曲"
        case "诵读", "spoken word", "audiobook", "podcast", "有声书", "播客":
            return "诵读音乐"
        case "拉丁", "latin", "salsa", "reggaeton", "bossa nova":
            return "拉丁音乐"
        case "休闲", "lounge", "easy listening", "chill", "lo-fi", "lofi", "氛围", "演歌", "enka":
            return "平缓"
        default:
            return nil
        }
    }

    private func currentGenre() -> String? {
        let script = """
        tell application "Music"
            if player state is playing then
                return (genre of current track)
            end if
            return ""
        end tell
        """
        guard let output = execute(script, logPrefix: "[AM genre]") else { return nil }
        guard !output.isEmpty, output != "missing value" else { return nil }
        return output
    }

    /// Switches Apple Music's EQ through System Events UI automation.
    private func setEQ(_ preset: String) {
        let allowedPresets: Set<String> = [
            "摇滚乐", "流行乐", "古典", "爵士乐", "嘻哈音乐", "电子乐", "舞曲",
            "原声", "R&B", "钢琴曲", "诵读音乐", "拉丁音乐", "平缓"
        ]
        guard allowedPresets.contains(preset) else {
            RateSyncLog.switching.error("[EQ] rejected non-allowlisted preset \(preset, privacy: .public)")
            return
        }

        RateSyncLog.switching.info("[EQ] accessibility trusted: \(AXIsProcessTrusted(), privacy: .public)")
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let script = """
        tell application "Music" to activate
        delay 0.3
        tell application "System Events"
            tell process "Music"
                try
                    click menu item "均衡器" of menu 1 of menu bar item "窗口" of menu bar 1
                on error
                    click menu item "Equalizer" of menu 1 of menu bar item "Window" of menu bar 1
                end try
                delay 0.4
                set eqWin to (first window whose name contains "均衡器" or name contains "Equalizer")
                click pop up button 1 of eqWin
                delay 0.3
                click menu item "\(preset)" of menu 1 of pop up button 1 of eqWin
                delay 0.2
                if (value of checkbox 1 of eqWin) is 0 then
                    click checkbox 1 of eqWin
                end if
                try
                    click menu item "均衡器" of menu 1 of menu bar item "窗口" of menu bar 1
                on error
                    click menu item "Equalizer" of menu 1 of menu bar item "Window" of menu bar 1
                end try
            end tell
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            RateSyncLog.switching.info("[EQ] failed: \(String(describing: error), privacy: .public)")
        }
        if let previousFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                previousFrontmost.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private func execute(_ source: String, logPrefix: String) -> String? {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error {
                RateSyncLog.switching.info("\(logPrefix) error: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        if let error {
            RateSyncLog.switching.info("\(logPrefix) error: \(String(describing: error), privacy: .public)")
        }
        return output
    }
}
