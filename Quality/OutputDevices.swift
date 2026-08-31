//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import OSLog
import AppKit
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter

/// Where a candidate sample rate came from. Only Apple Music's own paths are
/// known to report a transient rate before settling, so the gate that guards
/// against that misreport is sized per source.
private enum RateSource {
    case mediaRemoteProbe
    case appleMusicPriority
    case decoderLog
    case audioQueueLog
    /// An AudioQueue log line that predates the current track change, so it
    /// describes the PREVIOUS track. Retries widen the staleness filter by
    /// 1.5 s, so such a line can legitimately reach applyStats. It must never
    /// be applied immediately - it keeps the conservative gate, which holds
    /// long enough for the new track's own line to be written.
    case staleAudioQueueLog
    case preset
}

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var pollCancellable: AnyCancellable?
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    private var lastTrackChangeDate: Date?
    // Boundary-gate tuning: post-track-change blackout window and how long
    // a differing candidate must persist before it may be applied.
    private static let boundaryWindow: TimeInterval = 3.5
    private static let stabilityConfirmation: TimeInterval = 2.0
    // Overriding an already-applied rate for the current track requires
    // overwhelming evidence: transient misreports (e.g. Atmos handshakes)
    // never survive this long, while genuine corrections do.
    private static let lockedOverridePersistence: TimeInterval = 12.0
    // Plausibility bounds for parsed/probed sample rates and bit depths.
    // The log parsers accept any text that Double()/Int() can read, so a
    // malformed or hostile log line ("0 Hz", "-96000 Hz",
    // "99999999999999-bit source") would otherwise reach CoreAudio and
    // silently force the device to the lowest/highest supported format.
    // 768 kHz and 64 bit are far above anything real hardware advertises.
    static let maxPlausibleSampleRate: Double = 768_000
    static let maxPlausibleBitDepth: Int = 64
    // Cap on retained per-track results, so long listening sessions cannot
    // grow the caches without bound (one entry per distinct MediaTrack).
    private static let maxCachedTracks = 200
    // Stability confirmation for post-window rate changes (see applyStats).
    private var pendingCandidateRate: Float64?
    private var pendingCandidateFirstSeen: Date?

    /// How long a parsed OSLog result may be reused before the archive is
    /// queried again. One query costs ~0.70 s of blocking work (measured on
    /// this machine, and independent of the window size: 5 s, 15 s and 60 s
    /// all measured ~0.70 s), and the gate re-evaluates every 0.5 s, so a
    /// single track change would otherwise pay for a dozen identical
    /// queries. The TTL is short enough that a genuinely new log line - a
    /// mid-track format change creates a new AudioQueue and therefore a new
    /// line - is still picked up on the next poll.
    private static let logStatsTTL: TimeInterval = 1.5
    /// Caches the PARSED stats, not the post-filter result: cached entries
    /// are re-filtered against `lastTrackChangeDate` on every read, so a
    /// cached line from the previous track can never be applied to the new
    /// one. Only non-empty results are cached (see statsFromLogs) so the
    /// "log line not written yet" retry always re-queries.
    private var logStatsCache: [String : (stats: [CMPlayerStats], at: Date)] = [:]

    /// Apps observed to report no audio format through MediaRemote. Every
    /// probe costs a 1.0 s timeout wait, paid on EVERY gate re-evaluation,
    /// so once an app has been seen to report nothing repeatedly we stop
    /// asking and go straight to the log chain. Two consecutive misses are
    /// required, so a transient failure (app mid-launch, Now Playing
    /// payload not populated yet) cannot poison the cache.
    private var silentProbeApps: Set<String> = []
    private var probeMissCounts: [String : Int] = [:]
    private static let probeMissesBeforeSkip = 2

    /// Gate policy per rate source. The 3.5 s boundary window + 2.0 s
    /// stability confirmation exist because Apple Music reports a transient
    /// 44.1 kHz for several seconds on Dolby Atmos tracks before settling -
    /// both in its decoder logs and in its MediaRemote payload - so a
    /// differing rate must not be trusted immediately.
    /// AudioQueue sources do NOT behave that way: "New output" is written
    /// once, at queue creation, with the final rate. Measured NetEase
    /// CloudMusic logs (30-day archive) contain exactly one such line per
    /// track, with no transient re-report - the closest two lines are
    /// 12.13 s apart and are genuine track changes. Holding the full gate
    /// there only adds ~5.5 s of dead time before a rate that was already
    /// correct on first read.
    private struct GatePolicy {
        let boundary: TimeInterval
        let stability: TimeInterval
        let lockedOverride: TimeInterval

        static let standard = GatePolicy(boundary: 3.5, stability: 2.0, lockedOverride: 12.0)
        /// AudioQueue log sources: a single confirmation tick, so a
        /// straggler line is not applied on its own, then apply.
        static let audioQueue = GatePolicy(boundary: 0, stability: 0.6, lockedOverride: 12.0)
    }

    private static func gatePolicy(for source: RateSource) -> GatePolicy {
        switch source {
        case .audioQueueLog:
            return .audioQueue
        case .staleAudioQueueLog, .mediaRemoteProbe, .appleMusicPriority, .decoderLog, .preset:
            return .standard
        }
    }


    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        // Restore the device the user picked in a previous session.
        // The UID is persisted but was never read back, so the selection
        // silently reverted to "Default Device" on every launch.
        self.restoreSelectedDevice()
        self.getDeviceSampleRate()


        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        startPolling()
    }
    
    /// Re-applies the persisted output device selection at launch.
    /// Falls back to "Default Device" when the saved device is gone
    /// (unplugged, renamed) or when none was ever chosen.
    private func restoreSelectedDevice() {
        guard let uid = Defaults.shared.selectedDeviceUID else { return }
        guard let device = self.outputDevices.first(where: { $0.uid == uid }) else {
            Logger.switching.info("[Restore] saved device \(uid, privacy: .public) no longer present, using default")
            Defaults.shared.selectedDeviceUID = nil
            return
        }
        self.selectedOutputDevice = device
        Logger.switching.info("[Restore] restored selected device \(device.name, privacy: .public)")
    }

    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        pollCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.timerCalls += 1
                if self.timerCalls >= 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    // Snapshot the track at tick time so the stale-task guard
                    // in switchLatestSampleRate can discard ticks that belong
                    // to a track that has since changed.
                    let trackSnapshot = self.currentTrack
                    self.processQueue.async {
                        self.switchLatestSampleRate(for: trackSnapshot)
                    }
                }
            }
    }
    
    /// Always-on safety net alongside the event-driven path and the
    /// renewTimer retries: catches evaluations missed when no MediaRemote
    /// event fires (e.g. playback already running before launch). In steady
    /// state each tick hits the same-track lock in applyStats and skips cheaply.
    private func startPolling() {
        pollCancellable = Timer.publish(every: 3, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let snapshot = self.currentTrack
                self.processQueue.async {
                    self.switchLatestSampleRate(for: snapshot)
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                Logger.switching.info("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }

    /// Resolves the playing app's bundle identifier, falling back to the
    /// process identifier when the MediaRemote event did not carry one
    /// (the adapter's PID lookup can race and return no bundle id).
    static func resolveBundleIdentifier(track: MediaTrack?) -> String? {
        if let bundleID = track?.bundleIdentifier {
            return bundleID
        }
        guard let pid = track?.pid, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleIdentifier
    }

    /// Resolves the process name (executable basename) of the playing app.
    /// OSLog entries are filtered by this name (e.g. "Music",
    /// "NeteaseMusic", "Spotify").
    static func resolveProcessName(track: MediaTrack?) -> String? {
        guard let pid = track?.pid, pid > 0,
              let url = NSRunningApplication(processIdentifier: pid)?.executableURL else {
            return nil
        }
        return url.lastPathComponent
    }

    /// AppleScript queries the Music app specifically, and the decoder log
    /// parsing targets the Music process (see Console.EntryType.coreAudio).
    /// Both are therefore only valid when the current track actually comes
    /// from Apple Music. For any other (or unknown) source they would apply
    /// Apple Music's sample rate to a track playing in a different app.
    private var isAppleMusicSource: Bool {
        return Self.resolveBundleIdentifier(track: currentTrack) == Defaults.appleMusicBundleIdentifier
    }

    /// True only when the Music process is actually running.
    /// Every `tell application "Music"` block launches Music if it is not
    /// already running, so any AppleScript query must be gated on this -
    /// otherwise monitoring a non-Apple-Music app would start Music as a
    /// side effect of the priority check below.
    private var isAppleMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Defaults.appleMusicBundleIdentifier
        }
    }

    /// When another player triggers the event but Apple Music is playing at
    /// the same time, Apple Music wins: its sample rate is applied. Returns
    /// nil when the event source is Apple Music itself (its normal chain
    /// already handles it), when Apple Music is not running/not playing, or
    /// when the query fails (e.g. automation permission missing - safe degradation).
    private func appleMusicPriorityStat() -> CMPlayerStats? {
        guard !isAppleMusicSource else { return nil }
        // Music is queried on every switch for non-Apple-Music sources.
        // Without this check the AppleScript below would launch Music.
        guard isAppleMusicRunning else { return nil }
        guard let state = appleMusicPlaybackState(), state.isPlaying,
              let sampleRate = state.sampleRate, sampleRate > 0 else {
            return nil
        }
        return CMPlayerStats(sampleRate: sampleRate, bitDepth: previousBitDepth ?? 24, date: Date())
    }

    /// Fetches Apple Music's current track genre (nil when not playing or
    /// unavailable). Apple Music only - other apps do not expose genre.
    private func appleMusicGenre() -> String? {
        let script = """
        tell application "Music"
            if player state is playing then
                return (genre of current track)
            end if
            return ""
        end tell
        """
        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            if let error = error {
                Logger.switching.info("[AM genre] error: \(error)")
            }
            return nil
        }
        if output.isEmpty || output == "missing value" {
            return nil
        }
        return output
    }

    /// Maps a track genre to Apple Music's localized EQ preset name.
    /// Presets verified via `name of EQ presets` (zh-Hans system).
    /// Returns nil to leave the current EQ untouched.
    static func eqPreset(forGenre genre: String?) -> String? {
        guard let genre else { return nil }
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch g {
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

    /// Last EQ preset applied, to avoid re-applying for repeated events.
    private var lastAppliedEQPreset: String?
    private let eqLock = NSLock()

    /// Applies Apple Music's EQ preset matching the current track's genre.
    /// Apple Music only; no-op when the switch is off, the source is not
    /// Apple Music, the genre maps to no preset, or the preset is unchanged.
    func applyAppleMusicEQIfNeeded() {
        guard Defaults.shared.autoEQEnabled else {
            Logger.switching.info("[EQ] skipped: switch off")
            return
        }
        guard isAppleMusicSource else {
            Logger.switching.info("[EQ] skipped: source is not Apple Music (\(Self.resolveBundleIdentifier(track: self.currentTrack) ?? "unknown", privacy: .public))")
            return
        }
        guard isAppleMusicRunning else {
            Logger.switching.info("[EQ] skipped: Music is not running")
            return
        }
        guard let genre = appleMusicGenre() else {
            Logger.switching.info("[EQ] skipped: no genre")
            return
        }
        guard let preset = Self.eqPreset(forGenre: genre) else {
            Logger.switching.info("[EQ] skipped: genre \(genre, privacy: .public) maps to no preset")
            return
        }
        eqLock.lock()
        let unchanged = (preset == lastAppliedEQPreset)
        if !unchanged {
            lastAppliedEQPreset = preset
        }
        eqLock.unlock()
        guard !unchanged else {
            Logger.switching.info("[EQ] skipped: preset \(preset, privacy: .public) already applied")
            return
        }
        Logger.switching.info("[EQ] genre \(genre, privacy: .public) -> preset \(preset, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async {
            self.setAppleMusicEQ(preset)
        }
    }

    /// Switches Apple Music's built-in EQ preset via UI automation.
    /// AppleScript writes to EQ properties are read-only, so System Events
    /// (Accessibility + Automation permissions) is required. Music must be
    /// activated for the menu action to take effect; the previously active
    /// app is restored afterwards so focus returns quickly.
    func setAppleMusicEQ(_ preset: String) {
        Logger.switching.info("[EQ] accessibility trusted: \(AXIsProcessTrusted(), privacy: .public)")
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let script = """
        tell application "Music" to activate
        delay 0.3
        tell application "System Events"
            tell process "Music"
                -- Open the EQ window via the Window menu.
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
                -- Ensure the equalizer is enabled. Setting the checkbox value
                -- is unreliable; click it only when it is not checked.
                if (value of checkbox 1 of eqWin) is 0 then
                    click checkbox 1 of eqWin
                end if
                -- Close the EQ window again (toggle the menu item).
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
        if let error = error {
            Logger.switching.info("[EQ] failed: \(String(describing: error), privacy: .public)")
        }
        // Give the focus back to the app that was active before the switch.
        if let previousFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                previousFrontmost.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private func appleMusicPlaybackState() -> (isPlaying: Bool, sampleRate: Double?)? {
        let script = """
        tell application "Music"
            if player state is playing then
                return (sample rate of current track) as string
            end if
            return ""
        end tell
        """
        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            if let error = error {
                Logger.switching.info("[AM state] error: \(error)")
            }
            return nil
        }
        if output.isEmpty {
            return (false, nil)
        }
        if output == "missing value" {
            return (true, nil)
        }
        return (true, Double(output))
    }
    
    func getAllStats(process: String = "Music",
                     parser: ([SimpleConsole]) -> [CMPlayerStats] = CMPlayerParser.parseCoreAudioConsoleLogs,
                     durationSeconds: TimeInterval = 5.0) -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()

        do {
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio, process: process, durationSeconds: durationSeconds)
            allStats.append(contentsOf: parser(coreAudioLogs))
            Logger.switching.info("[getAllStats] \(allStats)")
        }
        catch {
            Logger.switching.info("[getAllStats, error] \(error)")
        }

        if allStats.isEmpty, isAppleMusicSource, let sampleRate = getSampleRateFromAppleScript() {
            let stat = CMPlayerStats(sampleRate: sampleRate, bitDepth: previousBitDepth ?? 24, date: Date())
            allStats.append(stat)
            Logger.switching.info("[getAllStats] AppleScript fallback: \(stat)")
        }
        
        return allStats
    }
    
    func switchLatestSampleRate(for expectedTrack: MediaTrack? = nil, recursion: Bool = false) {
        // P1: stale-task guard. The switch task is queued on the serial processQueue
        // with a snapshot of the track it was scheduled for. If the track changed
        // before the task ran, discard it - otherwise its parsed sample rate (from
        // the newer track's log entries) could be applied to the older track.
        if let expectedTrack = expectedTrack, currentTrack != expectedTrack {
            Logger.switching.info("stale switch task for previous track, skip")
            return
        }
        // Preferred source: the playing app's own Now Playing audio format
        // (sample rate / bit depth), when it reports it. This avoids OSLog
        // parsing entirely and works without admin privileges. Apps that do
        // not report it fall through to the log-based chain below.
        //
        // Apps already known to report nothing are skipped entirely: a miss
        // costs the probe's 1.0 s timeout wait, and the gate re-evaluates
        // every 0.5 s, so that wait is paid on every single re-evaluation.
        if let bundleID = Self.resolveBundleIdentifier(track: currentTrack),
           silentProbeApps.contains(bundleID) {
            Logger.switching.info("[MRProbe] skipping probe for silent app \(bundleID, privacy: .public)")
            self.processQueue.async {
                self.runLogChain(expectedTrack: expectedTrack, recursion: recursion)
            }
            return
        }
        MediaRemoteSampleRateProbe.fetchAudioFormat(expectedPID: currentTrack?.pid) { [weak self] sampleRate, bitDepth in
            guard let self else { return }
            // The probe callback arrives on an arbitrary queue; hop back to
            // the serial processQueue and re-check the track snapshot, since
            // the track may have changed while the probe was in flight.
            self.processQueue.async {
                if let expectedTrack = expectedTrack, self.currentTrack != expectedTrack {
                    Logger.switching.info("stale switch task after probe, skip")
                    return
                }
                // Apple Music priority: when another player (e.g. Spotify)
                // triggers an event while Apple Music is also playing, the
                // sample rate to apply is Apple Music's, not the event
                // source's. Only checked for non-Apple-Music sources.
                if let amStat = self.appleMusicPriorityStat() {
                    Logger.switching.info("[AM Priority] Apple Music is playing, using its sample rate")
                    self.applyStats([amStat], source: .appleMusicPriority, expectedTrack: expectedTrack, recursion: recursion)
                    // Keep Apple Music's EQ in sync with its own genre too.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.applyAppleMusicEQIfNeeded()
                    }
                    return
                }
                if let sampleRate, sampleRate > 0 {
                    let stat = CMPlayerStats(sampleRate: sampleRate, bitDepth: self.previousBitDepth ?? 24, date: Date())
                    Logger.switching.info("[MRProbe] direct audio format: \(sampleRate) Hz, \(bitDepth ?? -1) bit")
                    self.applyStats([stat], source: .mediaRemoteProbe, expectedTrack: expectedTrack, recursion: recursion)
                } else {
                    self.recordProbeMissIfPossible()
                    self.runLogChain(expectedTrack: expectedTrack, recursion: recursion)
                }
            }
        }
    }

    /// Log-based rate resolution plus the preset fallback, run after the
    /// MediaRemote probe reported nothing (or was skipped).
    private func runLogChain(expectedTrack: MediaTrack?, recursion: Bool) {
        let logStats = self.statsFromLogs(expectedTrack: expectedTrack, recursion: recursion)
        // Lowest-priority fallback: known apps that neither report
        // Now Playing audio format keys nor emit parseable decoder
        // logs get a preset sample rate, so switching still happens.
        if logStats.isEmpty,
           let track = self.currentTrack,
           let bundleID = Self.resolveBundleIdentifier(track: track),
           let preset = Self.presetSampleRate(for: bundleID) {
            let stat = CMPlayerStats(sampleRate: preset, bitDepth: 16, date: Date())
            Logger.switching.info("[Preset] \(bundleID) -> \(preset) Hz")
            self.applyStats([stat], source: .preset, expectedTrack: expectedTrack, recursion: recursion)
        } else {
            // The AudioQueue parser is the only log parser used for
            // non-Apple-Music processes; Apple Music's own decoder parser
            // feeds the log entries that the Atmos gate was designed for.
            let source: RateSource = (Self.resolveProcessName(track: currentTrack) == "Music")
                ? .decoderLog
                : self.audioQueueSource(for: logStats)
            self.applyStats(logStats, source: source, expectedTrack: expectedTrack, recursion: recursion)
        }
    }

    /// Classifies an AudioQueue log result for the gate.
    ///
    /// A line written BEFORE the current track change describes the previous
    /// track. Recursive retries widen the staleness filter by 1.5s, so such a
    /// line does reach applyStats - deliberately, because on a slow first
    /// write it is the only available data. It is still real data, but it is
    /// not trustworthy enough to apply immediately: the fast AudioQueue gate
    /// would lock in the OLD track's rate before the new line lands. Those
    /// results fall back to the conservative gate, which confirms long enough
    /// for the new track's own line to be written.
    private func audioQueueSource(for stats: [CMPlayerStats]) -> RateSource {
        guard let lastTrackChangeDate, let newest = stats.map(\.date).max() else {
            return .audioQueueLog
        }
        if newest < lastTrackChangeDate {
            Logger.switching.info("[Gate] AudioQueue log predates track change, using conservative gate")
            return .staleAudioQueueLog
        }
        return .audioQueueLog
    }

    /// Tracks consecutive MediaRemote probe misses per app. After
    /// `probeMissesBeforeSkip` misses the app is treated as reporting no
    /// audio format, so later evaluations skip the 1.0 s timeout wait.
    /// Requiring two misses keeps a transient failure (app mid-launch,
    /// Now Playing payload not yet populated) from disabling the probe.
    private func recordProbeMissIfPossible() {
        guard let bundleID = Self.resolveBundleIdentifier(track: currentTrack) else { return }
        let count = (probeMissCounts[bundleID] ?? 0) + 1
        probeMissCounts[bundleID] = count
        if count >= Self.probeMissesBeforeSkip, !silentProbeApps.contains(bundleID) {
            silentProbeApps.insert(bundleID)
            Logger.switching.info("[MRProbe] \(bundleID, privacy: .public) reported no format \(count)x, skipping probe from now on")
        }
    }

    /// Best-effort preset sample rates for apps that expose no sample rate
    /// anywhere (no Now Playing audio format keys, no parseable decoder logs,
    /// no AppleScript access). Verified facts only:
    /// - Spotify streams (lossy or the 2025 CD-lossless "HD" tier) are 44.1 kHz.
    /// Extend this table per app after measuring its actual behaviour.
    static func presetSampleRate(for bundleIdentifier: String?) -> Double? {
        guard let bundleIdentifier else { return nil }
        switch bundleIdentifier {
        case Defaults.spotifyBundleIdentifier:
            return 44100
        default:
            return nil
        }
    }

    /// Log-based fallback chain, per source process:
    /// - "Music" (Apple Music): Apple's decoder logs + AppleScript.
    /// - Any other process (e.g. "NeteaseMusic"): AudioQueue "New output"
    ///   entries, which report the decoded sample rate for players that
    ///   render through AudioQueue without resampling.
    private func statsFromLogs(expectedTrack: MediaTrack?, recursion: Bool) -> [CMPlayerStats] {
        guard let processName = Self.resolveProcessName(track: currentTrack) else {
            Logger.switching.info("cannot resolve source process name, skipping log chain")
            return []
        }
        let isMusicProcess = (processName == "Music")
        var allStats: [CMPlayerStats]
        if isMusicProcess {
            guard isAppleMusicSource else { return [] }
            allStats = self.getAllStats(process: processName)
        } else {
            Logger.switching.info("log chain for process \(processName) via AudioQueue parser")
            // AudioQueue "New output" entries are written once per queue creation
            // and are these apps' ONLY rate source (no probe keys, no AppleScript).
            // The query window must outlive the gate confirmation so the single
            // log line cannot expire mid-gate - observed as "first play never
            // switches until the track is replayed". Stale entries stay excluded
            // by the lastTrackChangeDate filter below.
            allStats = self.cachedAudioQueueStats(process: processName)
        }
        // Ignore logs from before the current track started playing,
        // as stale logs from the previous track cause wrong switches.
        if let lastTrackChangeDate = lastTrackChangeDate {
            // P2: recursive retries widen the tolerance window. Decoder logs can be
            // written more than 0.5s before the MediaRemote event (e.g. delayed UI
            // state updates); a strict filter would permanently discard them and,
            // if the AppleScript fallback also fails, the switch would be lost.
            let threshold = recursion ? lastTrackChangeDate.addingTimeInterval(-1.5) : lastTrackChangeDate
            allStats = allStats.filter { $0.date >= threshold }
            // If every log entry was filtered out, it may mean the new track's
            // logs are not in the window yet. Fall back to AppleScript on the
            // initial attempt so switching is not lost.
            if allStats.isEmpty, !recursion, isMusicProcess, let sampleRate = getSampleRateFromAppleScript() {
                allStats = [CMPlayerStats(sampleRate: sampleRate, bitDepth: previousBitDepth ?? 24, date: Date())]
                Logger.switching.info("[switchLatestSampleRate] AppleScript fallback after filtering: \(sampleRate)")
            }
        }
        return allStats
    }

    /// AudioQueue stats for `process`, reusing a recent parse when possible.
    ///
    /// One OSLog query costs ~0.70 s of blocking work regardless of window
    /// size, and the gate re-evaluates every 0.5 s, so an uncached chain pays
    /// for a dozen near-identical queries per track change. Results are
    /// cached for `logStatsTTL`.
    ///
    /// Only NON-EMPTY results are cached: an empty result usually means the
    /// log line has not been written yet, and caching that would freeze the
    /// retry loop into returning nothing until the TTL expires.
    ///
    /// The cached value is the PARSED list, not the post-filter result, so the
    /// `lastTrackChangeDate` filter below still runs on every read and a line
    /// belonging to the previous track can never be applied to the new one.
    private func cachedAudioQueueStats(process: String) -> [CMPlayerStats] {
        let key = "aq:\(process)"
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            Logger.switching.info("[LogCache] hit for \(process, privacy: .public) (\(cached.stats.count) stats)")
            return cached.stats
        }
        let stats = self.getAllStats(process: process,
                                     parser: CMPlayerParser.parseAudioQueueConsoleLogs,
                                     durationSeconds: 60)
        if stats.isEmpty {
            // Do not cache "nothing found" - the line may simply not be
            // written yet, and the gate must be able to re-query.
            logStatsCache.removeValue(forKey: key)
            Logger.switching.info("[LogCache] miss for \(process, privacy: .public) (no stats, not cached)")
        } else {
            logStatsCache[key] = (stats, Date())
            Logger.switching.info("[LogCache] stored for \(process, privacy: .public) (\(stats.count) stats)")
        }
        return stats
    }

    /// Applies the best matching device format for the given stats, and
    /// schedules one retry when nothing usable was found yet.
    private func applyStats(_ allStats: [CMPlayerStats], source: RateSource = .decoderLog, expectedTrack: MediaTrack?, recursion: Bool) {
        let policy = Self.gatePolicy(for: source)
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice

        var didFindStat = false

        if let first = allStats.first,
           let supported = defaultDevice?.nominalSampleRates,
           // Reject implausible rates before they can reach CoreAudio:
           // 0 Hz / negative rates would select the LOWEST supported rate
           // and absurd rates the highest, silently forcing the device to
           // an extreme format. A rejected stat leaves didFindStat false, so
           // the single non-recursive retry below can still pick up a later,
           // valid reading without starting a retry loop.
           first.sampleRate.isFinite,
           first.sampleRate > 0,
           first.sampleRate <= Self.maxPlausibleSampleRate {
            didFindStat = true
            let sampleRate = Float64(first.sampleRate)
            // Clamp instead of truncating, and clamp before use:
            // Int32(truncatingIfNeeded:) silently turns an absurd depth
            // into a bogus but plausible-looking value
            // (99999999999999 -> 276447231). A garbage depth must not cost
            // us a valid rate, so it is clamped, not rejected.
            let bitDepth = Int32(clamping: min(max(first.bitDepth, 1), Self.maxPlausibleBitDepth))

            // Boundary gating: right after a track change, players
            // transitioning between formats (e.g. Dolby Atmos) report an
            // intermediate rate (44.1 kHz) for several seconds before
            // settling on the real one — via decoder logs AND via the
            // MediaRemote probe itself. A differing rate may only be
            // applied when (a) the post-track-change window has closed
            // AND (b) the same candidate has persisted across evaluations.
            // Persistence is tiered: a first-time candidate needs only
            // 2.0 s, but once the track already has an applied/cached
            // rate, overriding it requires 12 s — late Atmos handshakes
            // can outlive the short threshold yet must not cause a flap.
            // Equal-rate candidates pass through untouched.
            let sinceTrackChange = lastTrackChangeDate.map {
                Date().timeIntervalSince($0)
            } ?? .infinity
            let rateDiffersFromDevice = defaultDevice?.nominalSampleRate != sampleRate
            if rateDiffersFromDevice {
                if sinceTrackChange < policy.boundary {
                    Logger.switching.info("[Gate] candidate \(sampleRate, privacy: .public) != device \(defaultDevice?.nominalSampleRate ?? -1, privacy: .public) Hz inside boundary window, re-evaluating in 0.5s")
                    processQueue.asyncAfter(deadline: .now() + 0.5) {
                        self.switchLatestSampleRate(for: expectedTrack, recursion: true)
                    }
                    return
                }
                // Tiered persistence: first evaluation for this track uses the
                // short confirmation; once a rate is already applied+cached for
                // the current track, overturning it requires the candidate to
                // persist far longer (transient handshakes never do).
                let requiredPersistence = currentTrack.flatMap { trackAndSample[$0] } != nil
                    ? policy.lockedOverride
                    : policy.stability
                let confirmed: Bool
                if pendingCandidateRate == sampleRate,
                   let seen = pendingCandidateFirstSeen {
                    confirmed = Date().timeIntervalSince(seen) >= requiredPersistence
                } else {
                    confirmed = false
                }
                if !confirmed {
                    if pendingCandidateRate != sampleRate {
                        pendingCandidateRate = sampleRate
                        pendingCandidateFirstSeen = Date()
                    }
                    Logger.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz awaiting stability \(Int(requiredPersistence))s, re-evaluating in 0.5s")
                    processQueue.asyncAfter(deadline: .now() + 0.5) {
                        self.switchLatestSampleRate(for: expectedTrack, recursion: true)
                    }
                    return
                }
                Logger.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz confirmed stable, applying")
            }
            pendingCandidateRate = nil
            pendingCandidateFirstSeen = nil

            guard let defaultDevice = defaultDevice,
                  let formats = self.getFormats(device: defaultDevice) else { return }

            // https://stackoverflow.com/a/65060134
            var nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })

            // Tie-break equal distances toward the LOWER depth (closer to typical content).
            let nearestBitDepth = formats.min(by: {
                let d0 = abs(Int32($0.mBitsPerChannel) - bitDepth)
                let d1 = abs(Int32($1.mBitsPerChannel) - bitDepth)
                if d0 != d1 { return d0 < d1 }
                return $0.mBitsPerChannel < $1.mBitsPerChannel
            })

            if Defaults.shared.userPreferSampleRateMultiples,
               let nearestSampleRate = nearest,
               nearestSampleRate != sampleRate, supported.contains(sampleRate / 2) {
                nearest = sampleRate / 2
            }

            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })

            Logger.switching.info("NEAREST FORMAT \(nearestFormat.map { "\($0.mSampleRate)Hz/\($0.mBitsPerChannel)bit" }.joined(separator: ", "), privacy: .public)")

            if let suitableFormat = nearestFormat.first {
                // Same-track lock: once a sample rate has been applied for the current
                // track, never switch again within the same song unless the output
                // device itself changed (e.g. the user switched device), the parsed
                // sample rate actually differs from the applied one (e.g. the stream
                // switched to another version mid-song), or, in bit depth mode, the
                // applicable bit depth actually changed within the track. Multiple decoder
                // log entries (e.g. Dolby Atmos streams) can jitter between sample
                // rates, which would otherwise cause repeated switching.
                if let currentTrack = currentTrack,
                   let cachedSampleRate = trackAndSample[currentTrack],
                   defaultDevice.nominalSampleRate == cachedSampleRate,
                   cachedSampleRate == sampleRate {
                    let bitDepthChanged = enableBitDepthDetection && trackAndBitDepth[currentTrack] != Int(suitableFormat.mBitsPerChannel)
                    if !bitDepthChanged {
                        Logger.switching.info("same track, sample rate already applied, skip")
                        return
                    }
                    Logger.switching.info("same track, bit depth changed, re-applying format")
                }
                let sampleRateChanged = suitableFormat.mSampleRate != previousSampleRate
                let bitDepthChanged = enableBitDepthDetection && Int(suitableFormat.mBitsPerChannel) != previousBitDepth
                let formatChanged = sampleRateChanged || bitDepthChanged

                // An equal-rate result is a NO-OP (device already correct).
                // Applying-and-caching it would wrongly "settle" the track:
                // a genuine rate arriving later would then be forced onto
                // the slow 12 s override tier (observed as ~20 s switching
                // when the first read is stale data from the previous
                // track). Leave such tracks uncached instead.
                if !formatChanged {
                    Logger.switching.info("already at target format, nothing to apply (left uncached)")
                    return
                }

                Logger.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz depth \(suitableFormat.mBitsPerChannel, privacy: .public)")
                if enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                }
                else if sampleRateChanged { // bit depth disabled
                    defaultDevice.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel), runUserScript: formatChanged)
                if let currentTrack = currentTrack {
                    self.cacheTrackResult(currentTrack, sampleRate: suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel))
                }
            }
        }

        // Console logs may not contain the new track's format yet right after a track change.
        // Retry once shortly instead of waiting for the slower fallback timer.
        if !didFindStat && !recursion {
            processQueue.asyncAfter(deadline: .now() + 0.5) {
                self.switchLatestSampleRate(for: expectedTrack, recursion: true)
            }
        }
    }


    /// Records the format applied for a track, under a hard size cap.
    /// Only `currentTrack` is ever read back, but entries survive until the
    /// next track change, so an unbounded table would retain one entry per
    /// distinct track ever played in a long-running menu bar process.
    private func cacheTrackResult(_ track: MediaTrack, sampleRate: Float64, bitDepth: Int) {
        self.trackAndSample[track] = sampleRate
        self.trackAndBitDepth[track] = bitDepth
        // Dictionary ordering is unspecified, so this trims arbitrary
        // victims rather than a true LRU - the cap is the safety net, and
        // trackDidChange already removes entries as tracks move on.
        while self.trackAndSample.count > Self.maxCachedTracks {
            guard let victim = self.trackAndSample.keys.first(where: { $0 != self.currentTrack })
                    ?? self.trackAndSample.keys.first else { break }
            self.trackAndSample.removeValue(forKey: victim)
            self.trackAndBitDepth.removeValue(forKey: victim)
        }
    }

    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?, runUserScript: Bool = true) {
        self.previousSampleRate = sampleRate
        self.pendingCandidateRate = nil
        self.pendingCandidateFirstSeen = nil
        self.previousBitDepth = bitDepth
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
        }
        if runUserScript {
            self.runUserScript(sampleRate, bitDepth: bitDepth)
        }
    }
    
    /// Shared formatted text for the menu bar label and the menu content view.
    var formattedSampleRate: String? {
        guard let currentSampleRate = currentSampleRate else { return nil }
        if let bitDepth = currentBitDepth, enableBitDepthDetection {
            return String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth)
        } else {
            return String(format: "%.1f kHz", currentSampleRate)
        }
    }

    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        // Add bit depth as second argument if available
        if let bitDepth = bitDepth {
            arguments.append(String(bitDepth))
        }
        
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                try await task.execute(withArguments: arguments)
            }
            catch {
                Logger.switching.info("TASK ERR \(error)")
            }
        }
    }
    
    /// Re-evaluates the currently playing track immediately. Called when
    /// the user changes the monitoring source while something is already
    /// playing - without this, no new MediaRemote event would arrive and
    /// the sample rate would never switch until the next track change.
    func reevaluateNowPlaying() {
        MediaRemoteSampleRateProbe.fetchNowPlayingInfo { [weak self] trackInfo in
            guard let self, let trackInfo else { return }
            self.processQueue.async {
                let bundleID = trackInfo.payload.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: trackInfo.payload.PID ?? 0)?.bundleIdentifier
                if let monitored = Defaults.shared.monitoredBundleIdentifier,
                   bundleID != monitored {
                    Logger.switching.info("[Reevaluate] \(bundleID ?? "?") is not the monitored source, skip")
                    return
                }
                Logger.switching.info("[Reevaluate] re-evaluating switch for \(bundleID ?? "?")")
                self.trackDidChange(trackInfo)
            }
        }
    }
    
    /// Re-applies the current track when bit depth detection is enabled so stale pre-toggle state cannot make the next evaluation a no-op.
    func bitDepthPreferenceDidChange() {
        processQueue.async { [weak self] in
            guard let self, let track = self.currentTrack, Defaults.shared.userPreferBitDepthDetection else { return }
            self.trackAndSample.removeValue(forKey: track)
            self.trackAndBitDepth.removeValue(forKey: track)
            self.previousSampleRate = nil
            self.previousBitDepth = nil
            self.pendingCandidateRate = nil
            self.pendingCandidateFirstSeen = nil
            self.switchLatestSampleRate(for: track)
        }
    }

    func trackDidChange(_ newTrack: TrackInfo, eventDate: Date? = nil) {
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        if self.previousTrack != self.currentTrack {
            // Unlock the new track so its sample rate can be applied. The lock is
            // per-track and must not leak across replays of the same song.
            // Also drop the PREVIOUS track's entry: the lookup tables are
            // only ever consulted for `currentTrack`, so any other entry is
            // dead weight that would otherwise accumulate one per distinct
            // track played for the lifetime of the process.
            if let currentTrack = currentTrack {
                self.trackAndSample.removeValue(forKey: currentTrack)
                self.trackAndBitDepth.removeValue(forKey: currentTrack)
            }
            if let previousTrack = previousTrack {
                self.trackAndSample.removeValue(forKey: previousTrack)
                self.trackAndBitDepth.removeValue(forKey: previousTrack)
            }
            // Decoder log entries are timestamped when the new track starts decoding,
            // which can be slightly before the MediaRemote event arrives. Use the event
            // time minus a small tolerance, so the new track's logs pass the filter
            // while stale logs from the previous track are discarded.
            self.lastTrackChangeDate = (eventDate ?? Date()).addingTimeInterval(-0.5)
            self.pendingCandidateRate = nil
            self.pendingCandidateFirstSeen = nil
            self.renewTimer()
            // Track change: apply Apple Music's EQ preset for the new genre
            // (Apple Music only; no-op unless the auto-EQ switch is on).
            // The dedupe is intentionally NOT reset here: tracks mapping to
            // the same preset must not re-open the EQ window.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.applyAppleMusicEQIfNeeded()
            }
        }
        // Snapshot the track this task was scheduled for, so the stale-task guard
        // in switchLatestSampleRate can discard it if the track changes first.
        let trackSnapshot = MediaTrack(trackInfo: newTrack)
        processQueue.async { [unowned self] in
            self.switchLatestSampleRate(for: trackSnapshot)
        }
    }
}
