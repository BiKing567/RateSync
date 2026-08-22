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

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var showBitDepthInLabel = Defaults.shared.userPreferBitDepthDisplay
    
    private var showBitDepthCancellable: AnyCancellable?
    
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
    // Stability confirmation for post-window rate changes (see applyStats).
    private var pendingCandidateRate: Float64?
    private var pendingCandidateFirstSeen: Date?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
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
        
        showBitDepthCancellable = Defaults.shared.$userPreferBitDepthDisplay.sink(receiveValue: { newValue in
            self.showBitDepthInLabel = newValue
        })

        startPolling()
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        pollCancellable?.cancel()
        showBitDepthCancellable?.cancel()
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

    /// When another player triggers the event but Apple Music is playing at
    /// the same time, Apple Music wins: its sample rate is applied. Returns
    /// nil when the event source is Apple Music itself (its normal chain
    /// already handles it), when Apple Music is not playing, or when the
    /// query fails (e.g. automation permission missing - safe degradation).
    private func appleMusicPriorityStat() -> CMPlayerStats? {
        guard !isAppleMusicSource else { return nil }
        guard let state = appleMusicPlaybackState(), state.isPlaying,
              let sampleRate = state.sampleRate, sampleRate > 0 else {
            return nil
        }
        return CMPlayerStats(sampleRate: sampleRate, bitDepth: previousBitDepth ?? 24, date: Date())
    }

    /// Fixed content-depth mapping (user-verified against real catalogs):
    /// AM: 44.1k→16bit, ≥48k→24bit; NetEase: 48k→16bit special-case, rest as AM.
    private func fixedBitDepth(sampleRate: Double, bundleID: String?) -> Int {
        let isNetEase = bundleID?.caseInsensitiveCompare(Defaults.neteaseMusicBundleIdentifier) == .orderedSame
        if isNetEase && abs(sampleRate - 48_000) < 1 { return 16 }
        return sampleRate >= 47_999 ? 24 : 16
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
                     parser: ([SimpleConsole]) -> [CMPlayerStats] = CMPlayerParser.parseCoreAudioConsoleLogs) -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio, process: process)
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
                    self.applyStats([amStat], expectedTrack: expectedTrack, recursion: recursion)
                    // Keep Apple Music's EQ in sync with its own genre too.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.applyAppleMusicEQIfNeeded()
                    }
                    return
                }
                if let sampleRate, sampleRate > 0 {
                    let stat = CMPlayerStats(sampleRate: sampleRate, bitDepth: self.previousBitDepth ?? 24, date: Date())
                    Logger.switching.info("[MRProbe] direct audio format: \(sampleRate) Hz, \(bitDepth ?? -1) bit")
                    self.applyStats([stat], expectedTrack: expectedTrack, recursion: recursion)
                } else {
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
                        self.applyStats([stat], expectedTrack: expectedTrack, recursion: recursion)
                    } else {
                        self.applyStats(logStats, expectedTrack: expectedTrack, recursion: recursion)
                    }
                }
            }
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
            allStats = self.getAllStats(process: processName, parser: CMPlayerParser.parseAudioQueueConsoleLogs)
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

    /// Applies the best matching device format for the given stats, and
    /// schedules one retry when nothing usable was found yet.
    private func applyStats(_ allStats: [CMPlayerStats], expectedTrack: MediaTrack?, recursion: Bool) {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice

        var didFindStat = false

        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            didFindStat = true
            let sampleRate = Float64(first.sampleRate)
            let sourceBundleID = Self.resolveBundleIdentifier(track: currentTrack)
            // Target depth intentionally ignores stat-reported depth (probe/log depth proved unreliable).
            let bitDepth = Int32(fixedBitDepth(
                sampleRate: Float64(first.sampleRate),
                bundleID: sourceBundleID))
            Logger.switching.info("[DepthMap] \(first.sampleRate, privacy: .public) Hz on \(sourceBundleID ?? "nil", privacy: .public) -> \(Int(bitDepth), privacy: .public)bit")

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
                if sinceTrackChange < Self.boundaryWindow {
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
                    ? Self.lockedOverridePersistence
                    : Self.stabilityConfirmation
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
                    let bitDepthChanged = trackAndBitDepth[currentTrack] != Int(suitableFormat.mBitsPerChannel)
                    if !bitDepthChanged {
                        Logger.switching.info("same track, sample rate already applied, skip")
                        return
                    }
                    Logger.switching.info("same track, bit depth changed, re-applying format")
                }
                let sampleRateChanged = suitableFormat.mSampleRate != previousSampleRate
                let bitDepthChanged = Int(suitableFormat.mBitsPerChannel) != previousBitDepth
                let formatChanged = sampleRateChanged || bitDepthChanged

                Logger.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz depth \(suitableFormat.mBitsPerChannel, privacy: .public)")
                self.setFormats(device: defaultDevice, format: suitableFormat)
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel), runUserScript: formatChanged)
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                    self.trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
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
        if let bitDepth = currentBitDepth, showBitDepthInLabel {
            return String(format: "%gk·%dbit", currentSampleRate, bitDepth)
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
    
    func trackDidChange(_ newTrack: TrackInfo, eventDate: Date? = nil) {
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        if self.previousTrack != self.currentTrack {
            // Unlock the new track so its sample rate can be applied. The lock is
            // per-track and must not leak across replays of the same song.
            if let currentTrack = currentTrack {
                self.trackAndSample.removeValue(forKey: currentTrack)
                self.trackAndBitDepth.removeValue(forKey: currentTrack)
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
