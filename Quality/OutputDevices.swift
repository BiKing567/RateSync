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
import WidgetKit

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection

    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    private let appleMusic = AppleMusicService()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var nominalSampleRateChangesCancellable: AnyCancellable?
    private var streamPhysicalFormatChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var pollCancellable: AnyCancellable?
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    private var lastTrackChangeDate: Date?
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
    private var trackAndSample = [MediaTrack : Float64]()
    private var trackAndBitDepth = [MediaTrack : Int]()
    private var appleMusicFormatEvidence: CMPlayerStats?
    private var appleMusicFallbackFormat: CMPlayerStats?
    private var appleMusicFallbackAttemptedForTrack = false
    private var previousTrack: MediaTrack?
    private var currentTrack: MediaTrack?
    private var pendingNowPlayingClear: DispatchWorkItem?
    private static let nowPlayingClearGracePeriod: TimeInterval = 1.5
    
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

        nominalSampleRateChangesCancellable =
            NotificationCenter.default.publisher(for: .deviceNominalSampleRateDidChange).sink { [weak self] notification in
                guard let self,
                      let device = notification.object as? AudioDevice,
                      let monitoredDevice = self.selectedOutputDevice ?? self.defaultOutputDevice,
                      device.uid == monitoredDevice.uid else { return }
                self.processQueue.async {
                    self.refreshCurrentOutputFormat()
                }
            }

        streamPhysicalFormatChangesCancellable =
            NotificationCenter.default.publisher(for: .streamPhysicalFormatDidChange).sink { [weak self] notification in
                guard let self,
                      let stream = notification.object as? AudioStream,
                      stream.scope == .output,
                      let monitoredDevice = self.selectedOutputDevice ?? self.defaultOutputDevice,
                      stream.owningDevice?.uid == monitoredDevice.uid else { return }
                self.processQueue.async {
                    self.refreshCurrentOutputFormat()
                }
            }
        
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
        nominalSampleRateChangesCancellable?.cancel()
        streamPhysicalFormatChangesCancellable?.cancel()
        timerCancellable?.cancel()
        pollCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.renewTimerOnMain()
        }
    }

    private func renewTimerOnMain() {
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
                    self.scheduleSwitchForCurrentTrack()
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
                self.scheduleSwitchForCurrentTrack()
            }
    }
    
    func getDeviceSampleRate() {
        processQueue.async { [weak self] in
            self?.refreshCurrentOutputFormat()
        }
    }

    private func refreshCurrentOutputFormat() {
        let device = selectedOutputDevice ?? defaultOutputDevice
        guard let sampleRate = device?.nominalSampleRate,
              sampleRate.isFinite,
              sampleRate > 0 else {
            previousSampleRate = nil
            previousBitDepth = nil
            RateSyncWidgetConfiguration.clearAudioFormat()
            reloadWidgetTimeline(reason: "output format unavailable")
            DispatchQueue.main.async { [weak self] in
                self?.currentSampleRate = nil
                self?.currentBitDepth = nil
            }
            return
        }

        let bitDepth = device?.streams(scope: .output)?.first?.physicalFormat
            .map { Int($0.mBitsPerChannel) }
            .flatMap { $0 > 0 ? $0 : nil }
        let previousFormat = RateSyncWidgetConfiguration.loadAudioFormat()
        let formatChanged = previousFormat?.sampleRate != sampleRate
            || previousFormat?.bitDepth != bitDepth

        DispatchQueue.main.async { [weak self] in
            self?.currentSampleRate = sampleRate / 1_000
            self?.currentBitDepth = bitDepth
        }
        previousSampleRate = sampleRate
        previousBitDepth = bitDepth

        guard formatChanged else { return }
        RateSyncWidgetConfiguration.saveAudioFormat(sampleRate: sampleRate, bitDepth: bitDepth)
        reloadWidgetTimeline(reason: "output format refreshed")
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
        Self.resolveBundleIdentifier(track: currentTrack) == PlayerProfile.appleMusic.bundleIdentifier
    }

    private var shouldPrioritizeAppleMusic: Bool {
        return AppleMusicPriorityPolicy.shouldPrioritize(
            monitoredBundleIdentifier: Defaults.shared.monitoredBundleIdentifier,
            sourceBundleIdentifier: Self.resolveBundleIdentifier(track: currentTrack),
            priority: Defaults.shared.playerPriorityBundleIdentifiers,
            temporarySourceLockBundleIdentifier: Defaults.shared.activeTemporarySourceLock?.bundleIdentifier
        )
    }

    private func isExpectedTrackCurrent(_ expectedTrack: MediaTrack?) -> Bool {
        guard let expectedTrack else { return true }
        return currentTrack == expectedTrack
    }

    /// Applies Apple Music's EQ preset matching the current track's genre.
    /// Apple Music-specific automation is kept in AppleMusicService.
    func applyAppleMusicEQIfNeeded() {
        processQueue.async { [weak self] in
            self?.scheduleAppleMusicEQUpdate()
        }
    }

    private func scheduleAppleMusicEQUpdate() {
        let isEnabled = Defaults.shared.autoEQEnabled
        let isCurrentSource = isAppleMusicSource
        DispatchQueue.global(qos: .userInitiated).async { [appleMusic] in
            appleMusic.applyEQIfNeeded(isEnabled: isEnabled, isCurrentSource: isCurrentSource)
        }
    }

    private func scheduleSwitchForCurrentTrack() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let currentTrack = self.currentTrack else { return }
            self.switchLatestSampleRate(for: currentTrack)
        }
    }
    
    func getAllStats(process: String = PlayerProfile.appleMusic.processName,
                     parser: ([SimpleConsole]) -> [CMPlayerStats] = CMPlayerParser.parseCoreAudioConsoleLogs,
                     durationSeconds: TimeInterval = 5.0) -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()

        do {
            let entryTypes: [EntryType] = process == PlayerProfile.appleMusic.processName
                ? [.coreAudio, .appleMusic]
                : [.coreAudio]
            let logs = try Console.getRecentEntries(types: entryTypes, process: process, durationSeconds: durationSeconds)
            allStats.append(contentsOf: parser(logs))
            Logger.switching.info("[getAllStats] \(allStats)")
        }
        catch {
            Logger.switching.info("[getAllStats, error] \(error)")
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
        // Fast-path for NetEase / QQ: independent AudioQueue chain.
        // These apps never report NowPlaying sampleRate and do not need the
        // Apple Music priority dance (which costs AppleScript + 1.0s probe timeout).
        if let profile = PlayerProfile.profile(for: Self.resolveBundleIdentifier(track: currentTrack)),
           profile.formatDetection == .audioQueueLogs {
            Logger.switching.info("[FastPath] \(profile.bundleIdentifier, privacy: .public) -> direct AudioQueue chain")
            self.runLogChain(expectedTrack: expectedTrack, recursion: recursion)
            return
        }
        // Apps already known to report nothing are skipped entirely: a miss
        // costs the probe's 1.0 s timeout wait, and the gate re-evaluates
        // every 0.5 s, so that wait is paid on every single re-evaluation.
        if let bundleID = Self.resolveBundleIdentifier(track: currentTrack),
           silentProbeApps.contains(bundleID) {
            Logger.switching.info("[MRProbe] skipping probe for silent app \(bundleID, privacy: .public)")
            self.runLogChain(expectedTrack: expectedTrack, recursion: recursion)
            return
        }
        MediaRemoteSampleRateProbe.fetchAudioFormat(expectedPID: currentTrack?.pid) { [weak self] sampleRate, reportedBitDepth in
            guard let self else { return }
            // The probe callback arrives on an arbitrary queue; hop back to
            // the serial processQueue and re-check the track snapshot, since
            // the track may have changed while the probe was in flight.
            self.processQueue.async {
                if !self.isExpectedTrackCurrent(expectedTrack) {
                    Logger.switching.info("stale switch task after probe, skip")
                    return
                }
                self.applyAppleMusicPriorityOrMediaRemote(
                    sampleRate: sampleRate,
                    reportedBitDepth: reportedBitDepth,
                    expectedTrack: expectedTrack,
                    recursion: recursion
                )
            }
        }
    }

    private func applyAppleMusicPriorityOrMediaRemote(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        recursion: Bool
    ) {
        guard shouldPrioritizeAppleMusic, appleMusic.isRunning else {
            applyMediaRemoteProbe(
                sampleRate: sampleRate,
                reportedBitDepth: reportedBitDepth,
                expectedTrack: expectedTrack,
                recursion: recursion
            )
            return
        }

        appleMusic.fetchPlaybackState { [weak self] state in
            guard let self else { return }
            self.processQueue.async {
                guard self.isExpectedTrackCurrent(expectedTrack) else {
                    Logger.switching.info("stale switch task after Apple Music priority check, skip")
                    return
                }
                if let state,
                   state.isPlaying,
                   let appleMusicSampleRate = state.sampleRate,
                   appleMusicSampleRate > 0 {
                    let stat = CMPlayerStats(
                        sampleRate: appleMusicSampleRate,
                        bitDepth: self.previousBitDepth ?? 24,
                        date: Date()
                    )
                    Logger.switching.info("[AM Priority] Apple Music is playing, using its sample rate")
                    self.applyStats([stat], source: .appleMusicPriority, expectedTrack: expectedTrack, recursion: recursion)
                    self.scheduleAppleMusicEQUpdate()
                    return
                }
                self.applyMediaRemoteProbe(
                    sampleRate: sampleRate,
                    reportedBitDepth: reportedBitDepth,
                    expectedTrack: expectedTrack,
                    recursion: recursion
                )
            }
        }
    }

    private func applyMediaRemoteProbe(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        recursion: Bool
    ) {
        if let sampleRate, sampleRate > 0 {
            let bitDepth = RateSwitchingPolicy.bitDepth(
                reportedByMediaRemote: reportedBitDepth,
                fallback: previousBitDepth
            )
            let stat = CMPlayerStats(sampleRate: sampleRate, bitDepth: bitDepth, date: Date())
            Logger.switching.info("[MRProbe] direct audio format: \(sampleRate) Hz, \(reportedBitDepth ?? -1) bit")
            applyStats([stat], source: .mediaRemoteProbe, expectedTrack: expectedTrack, recursion: recursion)
        } else {
            recordProbeMissIfPossible()
            runLogChain(expectedTrack: expectedTrack, recursion: recursion)
        }
    }

    /// Log-based rate resolution plus the preset fallback, run after the
    /// MediaRemote probe reported nothing (or was skipped).
    private func runLogChain(expectedTrack: MediaTrack?, recursion: Bool) {
        let logStats = self.statsFromLogs(recursion: recursion)
        if isAppleMusicSource {
            rememberAppleMusicFormat(from: logStats)
        }
        let appleMusicResolution = isAppleMusicSource
            ? AppleMusicFormatPolicy.resolution(
                hasLogEvidence: appleMusicFormatEvidence != nil,
                hasLogStats: !logStats.isEmpty,
                hasCachedFallback: appleMusicFallbackFormat != nil,
                hasAttemptedFallback: appleMusicFallbackAttemptedForTrack,
                isPlaying: appleMusic.isRunning
            )
            : .noFormat
        if appleMusicResolution == .logEvidence,
           let appleMusicFormatEvidence {
            applyStats(
                [appleMusicFormatEvidence],
                source: .appleMusicFormatLog,
                expectedTrack: expectedTrack,
                recursion: recursion
            )
            return
        }
        if appleMusicResolution == .cachedFallback,
           let appleMusicFallbackFormat {
            applyStats(
                [appleMusicFallbackFormat],
                source: .decoderLog,
                expectedTrack: expectedTrack,
                recursion: recursion
            )
            return
        }
        if appleMusicResolution == .requestAppleScript {
            appleMusicFallbackAttemptedForTrack = true
            appleMusic.fetchPlaybackState { [weak self] state in
                guard let self else { return }
                self.processQueue.async {
                    guard self.isExpectedTrackCurrent(expectedTrack) else {
                        Logger.switching.info("stale switch task after Apple Music log fallback, skip")
                        return
                    }
                    if let state,
                       state.isPlaying,
                       let sampleRate = state.sampleRate,
                       sampleRate > 0 {
                        let stat = CMPlayerStats(
                            sampleRate: sampleRate,
                            bitDepth: self.previousBitDepth ?? 24,
                            date: Date()
                        )
                        self.appleMusicFallbackFormat = stat
                        Logger.switching.info("[LogFallback] Apple Music AppleScript sample rate: \(sampleRate)")
                        self.applyStats([stat], source: .decoderLog, expectedTrack: expectedTrack, recursion: recursion)
                    } else {
                        self.applyStats([], source: .decoderLog, expectedTrack: expectedTrack, recursion: recursion)
                    }
                }
            }
            return
        }
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
            let source: RateSource
            if Self.resolveProcessName(track: currentTrack) == PlayerProfile.appleMusic.processName {
                source = logStats.first?.isAppleMusicFormat == true ? .appleMusicFormatLog : .decoderLog
            } else {
                source = self.audioQueueSource(for: logStats)
            }
            self.applyStats(logStats, source: source, expectedTrack: expectedTrack, recursion: recursion)
        }
    }

    private func rememberAppleMusicFormat(from stats: [CMPlayerStats]) {
        guard let incoming = stats.first(where: \CMPlayerStats.isDolbyAtmos)
                ?? stats.first(where: \CMPlayerStats.isAppleMusicFormat) else {
            return
        }
        guard AppleMusicFormatPolicy.shouldReplaceCachedFormat(
            currentIsDolbyAtmos: appleMusicFormatEvidence?.isDolbyAtmos == true,
            incomingIsDolbyAtmos: incoming.isDolbyAtmos
        ) else {
            return
        }
        appleMusicFormatEvidence = incoming
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
        return PlayerProfile.profile(for: bundleIdentifier)?.fallbackSampleRate
    }

    /// Log-based fallback chain, per source process:
    /// - Any other process (e.g. "NeteaseMusic"): AudioQueue "New output"
    ///   entries, which report the decoded sample rate for players that
    ///   render through AudioQueue without resampling.
    private func statsFromLogs(recursion: Bool) -> [CMPlayerStats] {
        guard let processName = Self.resolveProcessName(track: currentTrack) else {
            Logger.switching.info("cannot resolve source process name, skipping log chain")
            return []
        }
        let isMusicProcess = (processName == PlayerProfile.appleMusic.processName)
        var allStats: [CMPlayerStats]
        if isMusicProcess {
            guard isAppleMusicSource else { return [] }
            allStats = self.cachedAppleMusicStats(process: processName)
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

    private func cachedAppleMusicStats(process: String) -> [CMPlayerStats] {
        let key = "am:\(process)"
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            Logger.switching.info("[LogCache] hit for Apple Music (\(cached.stats.count) stats)")
            return cached.stats
        }
        let stats = self.getAllStats(
            process: process,
            parser: CMPlayerParser.parseAppleMusicConsoleLogs,
            durationSeconds: AppleMusicFormatParser.logWindowSeconds
        )
        if stats.isEmpty {
            logStatsCache.removeValue(forKey: key)
        } else {
            logStatsCache[key] = (stats, Date())
            Logger.switching.info("[LogCache] stored for Apple Music (\(stats.count) stats)")
        }
        return stats
    }

    /// Applies the best matching device format for the given stats, and
    /// schedules one retry when nothing usable was found yet.
    private func applyStats(_ allStats: [CMPlayerStats], source: RateSource = .decoderLog, expectedTrack: MediaTrack?, recursion: Bool) {
        let policy = RateSwitchingPolicy.gatePolicy(for: source)
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
           first.sampleRate <= RateSwitchingPolicy.maxPlausibleSampleRate {
            didFindStat = true
            let sampleRate = Float64(first.sampleRate)
            // Clamp instead of truncating, and clamp before use:
            // Int32(truncatingIfNeeded:) silently turns an absurd depth
            // into a bogus but plausible-looking value
            // (99999999999999 -> 276447231). A garbage depth must not cost
            // us a valid rate, so it is clamped, not rejected.
            let bitDepth = Int32(clamping: min(max(first.bitDepth, 1), RateSwitchingPolicy.maxPlausibleBitDepth))

            // Boundary gating: right after a track change, players
            // transitioning between formats (e.g. Dolby Atmos) report an
            // intermediate rate (44.1 kHz) for several seconds before
            // settling on the real one — via decoder logs AND via the
            // MediaRemote probe itself. A differing rate may only be
            // applied when (a) the post-track-change window has closed
            // AND (b) the same candidate has persisted across evaluations.
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

            let suitableFormat = AudioFormatSelector.nearestFormat(
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                supportedSampleRates: supported,
                formats: formats,
                preferSampleRateMultiples: Defaults.shared.userPreferSampleRateMultiples
            )
            Logger.switching.info("NEAREST FORMAT \(suitableFormat.map { "\($0.mSampleRate)Hz/\($0.mBitsPerChannel)bit" } ?? "none", privacy: .public)")

            if let suitableFormat {
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
        RateSyncWidgetConfiguration.saveAudioFormat(sampleRate: sampleRate, bitDepth: bitDepth)
        reloadWidgetTimeline(reason: "RateSync applied format")
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
        }
        if runUserScript {
            UserScriptRunner.run(sampleRate: sampleRate, bitDepth: bitDepth)
        }
    }

    private func reloadWidgetTimeline(reason: String, reloadAll: Bool = false) {
        let reload = {
            Logger.switching.info("[Widget] reload: \(reason, privacy: .public)")
            WidgetCenter.shared.reloadTimelines(ofKind: RateSyncWidgetConfiguration.widgetKind)
            if reloadAll {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        if Thread.isMainThread {
            reload()
        } else {
            DispatchQueue.main.async(execute: reload)
        }
    }

    func refreshWidgetTimelineOnLaunch() {
        RateSyncWidgetConfiguration.migrateLegacyState()
        reloadWidgetTimeline(reason: "app launched", reloadAll: true)
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

    /// Re-evaluates the currently playing track immediately. Called when
    /// the user changes the monitoring source while something is already
    /// playing - without this, no new MediaRemote event would arrive and
    /// the sample rate would never switch until the next track change.
    func reevaluateNowPlaying() {
        MediaRemoteSampleRateProbe.fetchNowPlayingInfo { [weak self] trackInfo in
            guard let self else { return }
            guard let trackInfo else {
                Logger.switching.info("[Reevaluate] now playing snapshot unavailable, preserving current widget track")
                return
            }
            self.processQueue.async {
                let bundleID = trackInfo.payload.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: trackInfo.payload.PID ?? 0)?.bundleIdentifier
                let monitored = Defaults.shared.activeTemporarySourceLock?.bundleIdentifier
                    ?? Defaults.shared.monitoredBundleIdentifier
                if let monitored, bundleID != monitored {
                    Logger.switching.info("[Reevaluate] \(bundleID ?? "?") is not the monitored source, preserve target metadata")
                    return
                }
                Logger.switching.info("[Reevaluate] re-evaluating switch for \(bundleID ?? "?")")
                self.handleTrackDidChange(trackInfo, eventDate: nil)
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
        processQueue.async { [weak self] in
            self?.handleTrackDidChange(newTrack, eventDate: eventDate)
        }
    }

    private func handleTrackDidChange(_ newTrack: TrackInfo, eventDate: Date?) {
        pendingNowPlayingClear?.cancel()
        pendingNowPlayingClear = nil
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        let trackChanged = self.previousTrack != self.currentTrack
        let sharedTrack = RateSyncWidgetConfiguration.loadNowPlayingTrack()
        let widgetMetadataChanged = sharedTrack?.title != newTrack.payload.title
            || sharedTrack?.artist != newTrack.payload.artist
            || sharedTrack?.artworkDataBase64 != newTrack.payload.artworkDataBase64

        if trackChanged || widgetMetadataChanged {
            RateSyncWidgetConfiguration.saveNowPlayingTrack(
                title: newTrack.payload.title,
                artist: newTrack.payload.artist,
                artworkDataBase64: newTrack.payload.artworkDataBase64,
                updatedAt: eventDate ?? Date()
            )
            reloadWidgetTimeline(
                reason: trackChanged ? "now playing track changed" : "now playing metadata updated"
            )
        }

        if trackChanged {

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
            self.appleMusicFormatEvidence = nil
            self.appleMusicFallbackFormat = nil
            self.appleMusicFallbackAttemptedForTrack = false
            self.pendingCandidateRate = nil
            self.pendingCandidateFirstSeen = nil
            self.renewTimer()
            // Track change: apply Apple Music's EQ preset for the new genre
            // (Apple Music only; no-op unless the auto-EQ switch is on).
            // The dedupe is intentionally NOT reset here: tracks mapping to
            // the same preset must not re-open the EQ window.
            self.scheduleAppleMusicEQUpdate()
        }
        // Snapshot the track this task was scheduled for, so the stale-task guard
        // in switchLatestSampleRate can discard it if the track changes first.
        let trackSnapshot = MediaTrack(trackInfo: newTrack)
        self.switchLatestSampleRate(for: trackSnapshot)
    }

    func clearNowPlayingTrack() {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.pendingNowPlayingClear?.cancel()
            self.pendingNowPlayingClear = nil
            self.currentTrack = nil
            self.previousTrack = nil
            self.trackAndSample.removeAll()
            self.trackAndBitDepth.removeAll()
            self.logStatsCache.removeAll()
            self.appleMusicFormatEvidence = nil
            self.appleMusicFallbackFormat = nil
            self.appleMusicFallbackAttemptedForTrack = false
            self.lastTrackChangeDate = nil
            self.pendingCandidateRate = nil
            self.pendingCandidateFirstSeen = nil
            self.timerCancellable?.cancel()
            self.timerCancellable = nil
            self.timerCalls = 0
            let clearWork = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingNowPlayingClear = nil
                RateSyncWidgetConfiguration.clearNowPlayingTrack()
                self.reloadWidgetTimeline(reason: "now playing stopped")
            }
            self.pendingNowPlayingClear = clearWork
            self.processQueue.asyncAfter(
                deadline: .now() + Self.nowPlayingClearGracePeriod,
                execute: clearWork
            )
        }
    }
}
