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
import CoreAudio
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
    @Published var isMultiPlayerConflictActive: Bool = false

    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    let appleMusic = AppleMusicService()
    let audioProcessMonitor: AudioProcessMonitoring
    lazy var playerPlaybackResolver = PlayerPlaybackStatusResolver(appleMusic: self.appleMusic)
    var latestPlayerRecords: [String: PlayerTrackRecord] = [:]
    var multiPlayerStabilizationWorkItem: DispatchWorkItem?
    static let multiPlayerStabilizationDelay: TimeInterval = 1.0
    let arbitrationTracker = MultiPlayerArbitrationTracker()
    var confirmedPlayingDatesByPlayer: [String: Date] = [:]
    var isArbitrationPending: Bool = false
    var arbitrationConfirmedSinglePlayer: String?
    let appleMusicAtmosProbeQueue = DispatchQueue(
        label: "com.biking.RateSync.apple-music-atmos-probe",
        qos: .userInitiated
    )
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var nominalSampleRateChangesCancellable: AnyCancellable?
    private var streamPhysicalFormatChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var pollCancellable: AnyCancellable?
    
    let processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    var previousSampleRate: Float64?
    var previousBitDepth: Int?
    var currentTrackStartedAt: Date?
    var currentTrackRequeryStartedAt: Date?
    var lastTrackChangeDate: Date?
    /// Distinguishes a replay/resume of identical MediaRemote metadata from
    /// callbacks belonging to the previous playback generation.
    var currentTrackGeneration: UInt64 = 0
    var appleMusicSampleRateState: AppleMusicSampleRateState = .inactive
    var appleMusicSampleRateWaitStartedAt: Date?
    /// Timestamp of the most recent AppleScript query for the current track.
    /// The first result is intentionally revalidated after Music has had time
    /// to settle its decoder/rendering metadata.
    var appleMusicSampleRateLastQueriedAt: Date?
    /// Identifies one AppleScript request attempt. Track/generation identity
    /// alone is insufficient because the same track can be queried again
    /// during revalidation.
    var appleMusicSampleRateQueryID: UInt64 = 0
    /// Last valid AppleScript rate for the current track. A later timeout must
    /// not let an unrelated decoder-log candidate replace this evidence.
    var appleMusicLastKnownCurrentTrackSampleRate: Double?
    /// Latches a generation while its current scan or delayed retry is pending.
    var appleMusicAtmosProbeScheduledGeneration: UInt64?
    var appleMusicAtmosProbeCompletedGeneration: UInt64?
    var appleMusicAtmosProbeLastCompletedAt: Date?
    var appleMusicResumeRetryWorkItem: DispatchWorkItem?
    var appleMusicResumeCheckAttempts: Int = 0
    var appleMusicRecoveryWorkItem: DispatchWorkItem?
    var appleMusicRecoveryAttempts: Int = 0
    struct QueuedTrackEvent {
        let track: TrackInfo
        let eventDate: Date?
        var hasResumedFromPause: Bool = false
    }
    struct ConfirmedPlayerSourceFormat {
        let track: MediaTrack
        let sampleRate: Float64
        let bitDepth: Int?
        let sourceSampleRate: Float64?
        let sourceBitDepth: Int?
        let deviceUID: String?
        let lastTrackChangeDate: Date?
        let trackStartedAt: Date?
        let confirmedAt: Date
    }
    private let pendingTrackChangeCoalescer = PendingTrackEventCoalescer<QueuedTrackEvent>()
    // Cap on retained per-track results, so long listening sessions cannot
    // grow the caches without bound (one entry per distinct MediaTrack).
    static let maxCachedTracks = 200
    // Stability confirmation for post-window rate changes (see applyStats).
    var pendingCandidate: RateGateDecisionPolicy.CandidateTracking?

    /// How long a parsed OSLog result may be reused before the archive is
    /// queried again. One query costs ~0.70 s of blocking work (measured on
    /// this machine, and independent of the window size: 5 s, 15 s and 60 s
    /// all measured ~0.70 s), and the gate re-evaluates every 0.5 s, so a
    /// single track change would otherwise pay for a dozen identical
    /// queries. The TTL is short enough that a genuinely new log line - a
    /// mid-track format change creates a new AudioQueue and therefore a new
    /// line - is still picked up on the next poll.
    static let logStatsTTL: TimeInterval = 1.5
    /// Caches the PARSED stats, not the post-filter result: cached entries
    /// are re-filtered against `lastTrackChangeDate` on every read, so a
    /// cached line from the previous track can never be applied to the new
    /// one. Only non-empty results are cached (see statsFromLogs) so the
    /// "log line not written yet" retry always re-queries.
    var logStatsCache: [String : (stats: [CMPlayerStats], at: Date)] = [:]

    /// Bounded MediaRemote and OSLog format probe budget for the active
    /// non-Apple-Music track or resume window. Prevents repeated 1.0 s timeouts
    /// and unbounded OSLog queries while keeping probing re-enabled on track
    /// changes, playback resume, and valid bit-depth-only reports.
    var formatProbeBudget = FormatProbeBudget()
    var cachedMediaRemoteSampleRate: Double?
    var cachedBitDepthEvidence: TrackFormatResolutionPolicy.BitDepthEvidence?

    func resetNonAppleMusicProbeWindow() {
        formatProbeBudget.resetForNewWindow()
        cachedMediaRemoteSampleRate = nil
        cachedBitDepthEvidence = nil
    }
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var trackLockedDeviceUID = [MediaTrack : String]()
    var trackDeviceMatch = [MediaTrack : SteadyStatePollingPolicy.ConfirmedDeviceMatch]()
    var confirmedPlayerFormats = [String: ConfirmedPlayerSourceFormat]()
    var lastTrackChangeDatesByPlayer = [String: Date]()
    var trackStartedAtByPlayer = [String: Date]()
    var appleMusicFormatEvidence: CMPlayerStats?
    var appleMusicDecoderFormatEvidence: CMPlayerStats?
    var appleMusicFallbackFormat: CMPlayerStats?
    var appleMusicFallbackAttemptedForTrack = false
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    private var pendingNowPlayingClear: DispatchWorkItem?
    private static let nowPlayingClearGracePeriod: TimeInterval = 1.5
    
    var timerCalls = 0
    
    init(audioProcessMonitor: AudioProcessMonitoring = CoreAudioProcessMonitor()) {
        self.audioProcessMonitor = audioProcessMonitor
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        // Restore the device the user picked in a previous session.
        // The UID is persisted but was never read back, so the selection
        // silently reverted to "Default Device" on every launch.
        self.restoreSelectedDevice()
        self.getDeviceSampleRate()

        audioProcessMonitor.onProcessActivityChanged = { [weak self] in
            self?.evaluateMultiPlayerActivity()
        }
        audioProcessMonitor.startMonitoring()


        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { [weak self] _ in
                guard let self else { return }
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.outputDeviceDidChange()
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
        
        outputSelectionCancellable = $selectedOutputDevice.dropFirst().sink(receiveValue: { [weak self] _ in
            self?.outputDeviceDidChange()
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
            RateSyncLog.switching.info("[Restore] saved device \(uid, privacy: .public) no longer present, using default")
            Defaults.shared.selectedDeviceUID = nil
            return
        }
        self.selectedOutputDevice = device
        RateSyncLog.switching.info("[Restore] restored selected device \(device.name, privacy: .public)")
    }

    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        nominalSampleRateChangesCancellable?.cancel()
        streamPhysicalFormatChangesCancellable?.cancel()
        timerCancellable?.cancel()
        pollCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        appleMusicResumeRetryWorkItem?.cancel()
        appleMusicRecoveryWorkItem?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.renewTimerOnMain()
        }
    }

    func cancelRetryTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.timerCalls = 0
            self?.timerCancellable?.cancel()
            self?.timerCancellable = nil
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
                self.schedulePollingCheckForCurrentTrack()
            }
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
    var isAppleMusicSource: Bool {
        Self.resolveBundleIdentifier(track: currentTrack) == PlayerProfile.appleMusic.bundleIdentifier
    }

    var shouldPrioritizeAppleMusic: Bool {
        return false
    }

    func isExpectedTrackCurrent(_ expectedTrack: MediaTrack?, generation: UInt64? = nil) -> Bool {
        if let expectedTrack, currentTrack != expectedTrack {
            return false
        }
        if let generation,
           !TrackRequestPolicy.isCurrent(
            expectedGeneration: generation,
            currentGeneration: currentTrackGeneration
           ) {
            return false
        }
        return true
    }

    func isPlayerEffectivelyPlaying(_ bundleID: String) -> Bool {
        if let confirmedAt = confirmedPlayingDatesByPlayer[bundleID] {
            if let record = latestPlayerRecords[bundleID], record.trackInfo.payload.isPlaying == false {
                return record.recordedAt <= confirmedAt
            }
            return true
        }
        return latestPlayerRecords[bundleID]?.trackInfo.payload.isPlaying != false
    }


    private func scheduleSwitchForCurrentTrack() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let currentTrack = self.currentTrack else { return }
            let activeDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let activeDeviceID = activeDevice?.id else { return }

            let processes = self.audioProcessMonitor.currentAudioProcesses()
            let activePlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                processes: processes,
                controlledDeviceID: activeDeviceID
            )
            guard let trackBundleID = Self.resolveBundleIdentifier(track: currentTrack),
                  activePlayers.contains(trackBundleID),
                  self.isPlayerEffectivelyPlaying(trackBundleID) else {
                return
            }

            if !self.isAppleMusicSource && self.formatProbeBudget.isPaused {
                return
            }
            self.switchLatestSampleRate(for: currentTrack)
        }
    }

    private func schedulePollingCheckForCurrentTrack() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let currentTrack = self.currentTrack else { return }
            let activeDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let activeDeviceID = activeDevice?.id else { return }

            let processes = self.audioProcessMonitor.currentAudioProcesses()
            let activePlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                processes: processes,
                controlledDeviceID: activeDeviceID
            )
            guard let trackBundleID = Self.resolveBundleIdentifier(track: currentTrack),
                  activePlayers.contains(trackBundleID),
                  self.isPlayerEffectivelyPlaying(trackBundleID) else {
                return
            }

            let deviceMatched = self.isCurrentDeviceMatched(for: currentTrack, device: activeDevice)
            guard SteadyStatePollingPolicy.shouldPollTrack(
                hasCurrentTrack: true,
                isTrackLocked: self.isTrackLockedOnDevice(currentTrack, device: activeDevice),
                isDeviceMatched: deviceMatched,
                hasPendingCandidate: self.pendingCandidate != nil,
                appleMusicState: self.appleMusicSampleRateState,
                trackStartedAt: self.currentTrackRequeryStartedAt ?? self.currentTrackStartedAt,
                now: Date(),
                isPlaybackPaused: !self.isAppleMusicSource && self.formatProbeBudget.isPaused
            ) else {
                return
            }
            self.switchLatestSampleRate(for: currentTrack)
        }
    }
    
    
    func switchLatestSampleRate(
        for expectedTrack: MediaTrack? = nil,
        recursion: Bool = false,
        generation: UInt64? = nil
    ) {
        let requestGeneration = generation ?? currentTrackGeneration
        let requestTrack = expectedTrack ?? currentTrack
        // P1: stale-task guard. The switch task is queued on the serial processQueue
        // with a snapshot of the track it was scheduled for. If the track changed
        // before the task ran, discard it - otherwise its parsed sample rate (from
        // the newer track's log entries) could be applied to the older track.
        if !isExpectedTrackCurrent(requestTrack, generation: requestGeneration) {
            RateSyncLog.switching.info("stale switch task for previous track, skip")
            return
        }
        if isMultiPlayerConflictActive || arbitrationTracker.isStabilizationScheduled {
            RateSyncLog.switching.info("[MultiPlayer] active conflict or stabilization scheduled, skipping switchLatestSampleRate")
            return
        }
        guard let requestTrack else { return }

        // Apple Music's current-track AppleScript value is the primary rate
        // evidence. Atmos and active spatial-rendering logs remain higher-priority overrides
        // only when attributed to the current playback track.
        if isAppleMusicSource {
            scheduleAppleMusicAtmosProbeIfNeeded(expectedTrack: requestTrack, generation: requestGeneration)
            if let atmosphere = appleMusicFormatEvidence, atmosphere.isPriorityAppleMusicFormat {
                let isFresh = currentTrackStartedAt.map { atmosphere.date >= $0 } ?? true
                let isMismatched = atmosphere.isMismatched(trackID: requestTrack.id, title: requestTrack.title)
                if isMismatched || (!isFresh && !atmosphere.isAttributed(trackID: requestTrack.id, title: requestTrack.title)) {
                    appleMusicFormatEvidence = nil
                } else if AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                    formatEvidence: atmosphere,
                    expectedTrackID: requestTrack.id,
                    expectedTrackTitle: requestTrack.title,
                    trackStartedAt: currentTrackStartedAt
                ) {
                    applyStats(
                        [atmosphere],
                        source: .appleMusicFormatLog,
                        expectedTrack: requestTrack,
                        generation: requestGeneration,
                        recursion: recursion
                    )
                    return
                }
            }
            resolveAppleMusicCurrentTrackSampleRate(
                expectedTrack: requestTrack,
                generation: requestGeneration,
                recursion: recursion
            )
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
        if let profile = PlayerProfile.profile(for: Self.resolveBundleIdentifier(track: requestTrack)),
           profile.formatDetection == .audioQueueLogs {
            RateSyncLog.switching.info("[FastPath] \(profile.bundleIdentifier, privacy: .public) -> direct AudioQueue chain")
            self.runLogChain(expectedTrack: requestTrack, generation: requestGeneration, recursion: recursion)
            return
        }
        let bundleID = Self.resolveBundleIdentifier(track: requestTrack)
        guard formatProbeBudget.shouldProbeMediaRemote(now: Date()) else {
            if let bundleID,
               formatProbeBudget.mediaRemoteMisses >= FormatProbeBudget.maxMediaRemoteMissesPerWindow {
                RateSyncLog.switching.info("[MRProbe] skipping probe for \(bundleID, privacy: .public) in current window after \(self.formatProbeBudget.mediaRemoteMisses) misses")
            }
            self.runLogChain(
                probeSampleRate: self.cachedMediaRemoteSampleRate,
                probeBitDepth: nil,
                expectedTrack: requestTrack,
                generation: requestGeneration,
                recursion: recursion
            )
            return
        }
        MediaRemoteSampleRateProbe.fetchAudioFormat(
            expectedPID: requestTrack.pid,
            expectedBundleIdentifier: bundleID
        ) { [weak self] sampleRate, reportedBitDepth in
            guard let self else { return }
            // The probe callback arrives on an arbitrary queue; hop back to
            // the serial processQueue and re-check the track snapshot, since
            // the track may have changed while the probe was in flight.
            self.processQueue.async {
                if !self.isExpectedTrackCurrent(requestTrack, generation: requestGeneration) {
                    RateSyncLog.switching.info("stale switch task after probe, skip")
                    return
                }
                let now = Date()
                let validRate = TrackFormatResolutionPolicy.validSampleRate(sampleRate)
                let validDepth = TrackFormatResolutionPolicy.validBitDepth(reportedBitDepth)
                if let validRate {
                    self.cachedMediaRemoteSampleRate = validRate
                }
                self.recordMediaRemoteBitDepthEvidence(validDepth, at: now)
                self.formatProbeBudget.recordMediaRemoteAttempt(
                    hasSampleRate: validRate != nil,
                    hasBitDepth: validDepth != nil,
                    now: now
                )
                self.applyAppleMusicPriorityOrMediaRemote(
                    sampleRate: validRate,
                    reportedBitDepth: validDepth,
                    expectedTrack: requestTrack,
                    generation: requestGeneration,
                    recursion: recursion
                )
            }
        }
    }


    func reloadWidgetTimeline(reason: String, reloadAll: Bool = false) {
        let reload = {
            RateSyncLog.switching.info("[Widget] reload: \(reason, privacy: .public)")
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.terminateStaleWidgetHost()

            for (attempt, delay) in RateSyncWidgetConfiguration.launchRefreshDelays.enumerated() {
                let refresh: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.reloadWidgetTimeline(
                        reason: attempt == 0 ? "app launched" : "app launch retry \(attempt)",
                        reloadAll: attempt == 0
                    )
                }
                if delay == 0 {
                    DispatchQueue.main.async(execute: refresh)
                } else {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + delay,
                        execute: refresh
                    )
                }
            }
        }
    }

    private func terminateStaleWidgetHost() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-TERM", RateSyncWidgetConfiguration.widgetExecutableName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            RateSyncLog.switching.info(
                "[Widget] stale host cleanup exited with status \(process.terminationStatus, privacy: .public)"
            )
        } catch {
            RateSyncLog.switching.error(
                "[Widget] stale host cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
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

    /// Re-evaluates the currently playing track immediately. Called when
    /// the user changes the monitoring source while something is already
    /// playing - without this, no new MediaRemote event would arrive and
    /// the sample rate would never switch until the next track change.
    func reevaluateNowPlaying() {
        MediaRemoteSampleRateProbe.fetchNowPlayingInfo { [weak self] trackInfo in
            guard let self else { return }
            guard let trackInfo else {
                RateSyncLog.switching.info("[Reevaluate] now playing snapshot unavailable, preserving current widget track")
                return
            }
            self.processQueue.async {
                let bundleID = trackInfo.payload.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: trackInfo.payload.PID ?? 0)?.bundleIdentifier
                guard let bundleID, PlayerProfile.registeredBundleIdentifiers.contains(bundleID) else {
                    RateSyncLog.switching.info("[Reevaluate] \(bundleID ?? "?") is not a registered player, preserve target metadata")
                    return
                }
                RateSyncLog.switching.info("[Reevaluate] re-evaluating switch for \(bundleID)")
                self.playerTrackInfoDidChange(trackInfo, bundleIdentifier: bundleID, eventDate: nil)
            }
        }
    }

    /// Re-applies the current track when bit depth detection is enabled so stale pre-toggle state cannot make the next evaluation a no-op.
    func bitDepthPreferenceDidChange() {
        processQueue.async { [weak self] in
            guard let self, let track = self.currentTrack, Defaults.shared.userPreferBitDepthDetection else { return }
            self.trackAndSample.removeValue(forKey: track)
            self.trackAndBitDepth.removeValue(forKey: track)
            self.trackLockedDeviceUID.removeValue(forKey: track)
            self.trackDeviceMatch.removeValue(forKey: track)
            self.resetNonAppleMusicProbeWindow()
            self.previousSampleRate = nil
            self.previousBitDepth = nil
            self.pendingCandidate = nil
            self.renewTimer()
            self.switchLatestSampleRate(for: track)
        }
    }

    func trackDidChange(_ newTrack: TrackInfo, eventDate: Date? = nil) {
        let queued = QueuedTrackEvent(track: newTrack, eventDate: eventDate)
        guard pendingTrackChangeCoalescer.enqueue(
            queued,
            merge: { existing, new in
                let isSameTrack = MediaTrack(trackInfo: existing.track) == MediaTrack(trackInfo: new.track)
                let resumed = isSameTrack && (
                    existing.hasResumedFromPause ||
                    (existing.track.payload.isPlaying == false && new.track.payload.isPlaying != false)
                )
                return QueuedTrackEvent(
                    track: new.track,
                    eventDate: new.eventDate,
                    hasResumedFromPause: resumed
                )
            }
        ) else {
            return
        }
        processQueue.async { [weak self] in
            self?.drainPendingTrackChanges()
        }
    }

    private func drainPendingTrackChanges() {
        while let action = pendingTrackChangeCoalescer.takeNextAction() {
            autoreleasepool {
                switch action {
                case .event(let next):
                    handleTrackDidChange(next.track, eventDate: next.eventDate, hasResumedFromPause: next.hasResumedFromPause)
                case .clear:
                    handleClearNowPlayingTrack()
                case .clearThenEvent(let next):
                    handleClearNowPlayingTrack()
                    handleTrackDidChange(next.track, eventDate: next.eventDate, hasResumedFromPause: next.hasResumedFromPause)
                case .resetArbitration:
                    break
                case .resetArbitrationThenEvent(let next):
                    handleTrackDidChange(next.track, eventDate: next.eventDate, hasResumedFromPause: next.hasResumedFromPause)
                }
            }
        }
    }

    func handleTrackDidChange(_ newTrack: TrackInfo, eventDate: Date?, hasResumedFromPause: Bool = false) {
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
            currentTrackGeneration &+= 1
            appleMusic.invalidatePlaybackStateCache()

            // Unlock the new track so its sample rate can be applied. The lock is
            // per-track and must not leak across replays of the same song.
            // Also drop the PREVIOUS track's entry: the lookup tables are
            // only ever consulted for `currentTrack`, so any other entry is
            // dead weight that would otherwise accumulate one per distinct
            // track played for the lifetime of the process.
            if let currentTrack = currentTrack {
                self.trackAndSample.removeValue(forKey: currentTrack)
                self.trackAndBitDepth.removeValue(forKey: currentTrack)
                self.trackLockedDeviceUID.removeValue(forKey: currentTrack)
                self.trackDeviceMatch.removeValue(forKey: currentTrack)
            }
            if let previousTrack = previousTrack {
                self.trackAndSample.removeValue(forKey: previousTrack)
                self.trackAndBitDepth.removeValue(forKey: previousTrack)
                self.trackLockedDeviceUID.removeValue(forKey: previousTrack)
                self.trackDeviceMatch.removeValue(forKey: previousTrack)
            }
            // Decoder log entries are timestamped when the new track starts decoding,
            // which can be slightly before the MediaRemote event arrives. Use the event
            // time minus a small tolerance, so the new track's logs pass the filter
            // while stale logs from the previous track are discarded.
            let trackStartedAt = eventDate ?? Date()
            self.currentTrackStartedAt = trackStartedAt
            self.currentTrackRequeryStartedAt = trackStartedAt
            self.lastTrackChangeDate = trackStartedAt.addingTimeInterval(-0.5)
            if let bundleID = Self.resolveBundleIdentifier(track: self.currentTrack) {
                self.trackStartedAtByPlayer[bundleID] = trackStartedAt
                self.lastTrackChangeDatesByPlayer[bundleID] = self.lastTrackChangeDate
                self.confirmedPlayerFormats.removeValue(forKey: bundleID)
            }
            self.appleMusicSampleRateState = isAppleMusicSource ? .waiting : .inactive
            self.appleMusicSampleRateWaitStartedAt = isAppleMusicSource ? trackStartedAt : nil
            self.appleMusicSampleRateLastQueriedAt = nil
            self.appleMusicSampleRateQueryID &+= 1
            self.appleMusicLastKnownCurrentTrackSampleRate = nil
            self.appleMusicAtmosProbeScheduledGeneration = nil
            self.appleMusicAtmosProbeCompletedGeneration = nil
            self.appleMusicAtmosProbeLastCompletedAt = nil
            self.appleMusicResumeRetryWorkItem?.cancel()
            self.appleMusicResumeRetryWorkItem = nil
            self.appleMusicResumeCheckAttempts = 0
            self.appleMusicRecoveryWorkItem?.cancel()
            self.appleMusicRecoveryWorkItem = nil
            self.appleMusicRecoveryAttempts = 0
            self.appleMusicFormatEvidence = nil
            self.appleMusicDecoderFormatEvidence = nil
            self.appleMusicFallbackFormat = nil
            self.appleMusicFallbackAttemptedForTrack = false
            self.resetNonAppleMusicProbeWindow()
            self.logStatsCache.removeAll()
            self.pendingCandidate = nil
            self.renewTimer()
            // Track change: apply Apple Music's EQ preset for the new genre
            // (Apple Music only; no-op unless the auto-EQ switch is on).
            // The dedupe is intentionally NOT reset here: tracks mapping to
            // the same preset must not re-open the EQ window.
            self.scheduleAppleMusicEQUpdate()
        } else if isAppleMusicSource {
            self.appleMusic.invalidatePlaybackStateCache()
            let isPlaying = newTrack.payload.isPlaying
            if isPlaying == false {
                self.appleMusicSampleRateState = .notPlaying
                self.appleMusicSampleRateWaitStartedAt = nil
                self.appleMusicSampleRateQueryID &+= 1
                self.appleMusicResumeRetryWorkItem?.cancel()
                self.appleMusicResumeRetryWorkItem = nil
                self.appleMusicResumeCheckAttempts = 0
                self.appleMusicRecoveryWorkItem?.cancel()
                self.appleMusicRecoveryWorkItem = nil
                self.appleMusicRecoveryAttempts = 0
                self.currentTrackGeneration &+= 1
                self.pendingCandidate = nil
                return
            } else {
                let wasNotPlaying = (self.appleMusicSampleRateState == .notPlaying)
                self.appleMusicResumeRetryWorkItem?.cancel()
                self.appleMusicResumeRetryWorkItem = nil
                self.appleMusicResumeCheckAttempts = 0
                if wasNotPlaying || hasResumedFromPause {
                    let resumedAt = eventDate ?? Date()
                    self.currentTrackGeneration &+= 1
                    self.appleMusicSampleRateQueryID &+= 1
                    self.currentTrackStartedAt = resumedAt
                    self.currentTrackRequeryStartedAt = resumedAt
                    self.appleMusicSampleRateState = .waiting
                    self.appleMusicSampleRateWaitStartedAt = resumedAt
                    self.appleMusicSampleRateLastQueriedAt = nil
                    self.appleMusicAtmosProbeCompletedGeneration = nil
                    self.appleMusicAtmosProbeLastCompletedAt = nil
                    if let currentTrack = self.currentTrack {
                        self.trackAndSample.removeValue(forKey: currentTrack)
                        self.trackAndBitDepth.removeValue(forKey: currentTrack)
                        self.trackLockedDeviceUID.removeValue(forKey: currentTrack)
                        self.trackDeviceMatch.removeValue(forKey: currentTrack)
                    }
                    self.pendingCandidate = nil
                    self.renewTimer()
                } else {
                    let eventTime = eventDate ?? Date()
                    self.currentTrackRequeryStartedAt = eventTime
                    self.appleMusicSampleRateState = .waiting
                    self.appleMusicSampleRateWaitStartedAt = eventTime
                    self.appleMusicSampleRateLastQueriedAt = nil
                    self.appleMusicAtmosProbeCompletedGeneration = nil
                    self.appleMusicAtmosProbeLastCompletedAt = nil
                    if let currentTrack = self.currentTrack {
                        self.trackDeviceMatch.removeValue(forKey: currentTrack)
                    }
                    self.pendingCandidate = nil
                    self.renewTimer()
                }
            }
        } else {
            if newTrack.payload.isPlaying == false {
                self.formatProbeBudget.setPaused(true)
                self.currentTrackGeneration &+= 1
                self.pendingCandidate = nil
                return
            }
            let wasPaused = self.formatProbeBudget.isPaused
            if wasPaused || hasResumedFromPause {
                let resumedAt = eventDate ?? Date()
                self.currentTrackGeneration &+= 1
                self.resetNonAppleMusicProbeWindow()
                self.currentTrackStartedAt = resumedAt
                self.currentTrackRequeryStartedAt = resumedAt
                self.lastTrackChangeDate = resumedAt.addingTimeInterval(-0.5)
                self.logStatsCache.removeAll()
                if let currentTrack = self.currentTrack {
                    self.trackDeviceMatch.removeValue(forKey: currentTrack)
                }
                self.pendingCandidate = nil
                self.renewTimer()
            }
        }
        // Snapshot the track this task was scheduled for, so the stale-task guard
        // in switchLatestSampleRate can discard it if the track changes first.
        let trackSnapshot = MediaTrack(trackInfo: newTrack)
        if !isMultiPlayerConflictActive {
            self.switchLatestSampleRate(for: trackSnapshot, generation: currentTrackGeneration)
        }
        if trackChanged && !isAppleMusicSource && newTrack.payload.isPlaying == false {
            self.formatProbeBudget.setPaused(true)
        }
        self.evaluateMultiPlayerActivity()
    }

    func clearNowPlayingTrack() {
        guard pendingTrackChangeCoalescer.enqueueClear() else {
            return
        }
        processQueue.async { [weak self] in
            self?.drainPendingTrackChanges()
        }
    }

    private func handleClearNowPlayingTrack() {
        self.currentTrackGeneration &+= 1
        self.appleMusic.invalidatePlaybackStateCache()
        self.appleMusicSampleRateState = .inactive
        self.appleMusicSampleRateWaitStartedAt = nil
        self.appleMusicSampleRateLastQueriedAt = nil
        self.appleMusicSampleRateQueryID &+= 1
        self.appleMusicLastKnownCurrentTrackSampleRate = nil
        self.appleMusicAtmosProbeScheduledGeneration = nil
        self.appleMusicAtmosProbeCompletedGeneration = nil
        self.appleMusicAtmosProbeLastCompletedAt = nil
        self.appleMusicResumeRetryWorkItem?.cancel()
        self.appleMusicResumeRetryWorkItem = nil
        self.appleMusicResumeCheckAttempts = 0
        self.appleMusicRecoveryWorkItem?.cancel()
        self.appleMusicRecoveryWorkItem = nil
        self.appleMusicRecoveryAttempts = 0
        self.pendingNowPlayingClear?.cancel()
        self.pendingNowPlayingClear = nil
        self.currentTrack = nil
        self.previousTrack = nil
        self.trackAndSample.removeAll()
        self.trackAndBitDepth.removeAll()
        self.trackLockedDeviceUID.removeAll()
        self.trackDeviceMatch.removeAll()
        self.logStatsCache.removeAll()
        self.appleMusicFormatEvidence = nil
        self.appleMusicDecoderFormatEvidence = nil
        self.appleMusicFallbackFormat = nil
        self.appleMusicFallbackAttemptedForTrack = false
        self.resetNonAppleMusicProbeWindow()
        self.currentTrackStartedAt = nil
        self.currentTrackRequeryStartedAt = nil
        self.lastTrackChangeDate = nil
        self.pendingCandidate = nil
        self.arbitrationTracker.cancelStabilization(reason: "clear now playing")
        self.multiPlayerStabilizationWorkItem?.cancel()
        self.multiPlayerStabilizationWorkItem = nil
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
        self.evaluateMultiPlayerActivity()
    }

}
