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
    private let appleMusicAtmosProbeQueue = DispatchQueue(
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
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    private var currentTrackStartedAt: Date?
    private var currentTrackRequeryStartedAt: Date?
    private var lastTrackChangeDate: Date?
    /// Distinguishes a replay/resume of identical MediaRemote metadata from
    /// callbacks belonging to the previous playback generation.
    private var currentTrackGeneration: UInt64 = 0
    private var appleMusicSampleRateState: AppleMusicSampleRateState = .inactive
    private var appleMusicSampleRateWaitStartedAt: Date?
    /// Timestamp of the most recent AppleScript query for the current track.
    /// The first result is intentionally revalidated after Music has had time
    /// to settle its decoder/rendering metadata.
    private var appleMusicSampleRateLastQueriedAt: Date?
    /// Identifies one AppleScript request attempt. Track/generation identity
    /// alone is insufficient because the same track can be queried again
    /// during revalidation.
    private var appleMusicSampleRateQueryID: UInt64 = 0
    /// Last valid AppleScript rate for the current track. A later timeout must
    /// not let an unrelated decoder-log candidate replace this evidence.
    private var appleMusicLastKnownCurrentTrackSampleRate: Double?
    /// Latches a generation while its current scan or delayed retry is pending.
    private var appleMusicAtmosProbeScheduledGeneration: UInt64?
    private var appleMusicAtmosProbeCompletedGeneration: UInt64?
    private var appleMusicAtmosProbeLastCompletedAt: Date?
    private var appleMusicResumeRetryWorkItem: DispatchWorkItem?
    private var appleMusicResumeCheckAttempts: Int = 0
    private var appleMusicRecoveryWorkItem: DispatchWorkItem?
    private var appleMusicRecoveryAttempts: Int = 0
    private struct QueuedTrackEvent {
        let track: TrackInfo
        let eventDate: Date?
        var hasResumedFromPause: Bool = false
    }
    private let pendingTrackChangeCoalescer = PendingTrackEventCoalescer<QueuedTrackEvent>()
    // Cap on retained per-track results, so long listening sessions cannot
    // grow the caches without bound (one entry per distinct MediaTrack).
    private static let maxCachedTracks = 200
    // Stability confirmation for post-window rate changes (see applyStats).
    private var pendingCandidate: RateGateDecisionPolicy.CandidateTracking?

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

    /// Bounded MediaRemote and OSLog format probe budget for the active
    /// non-Apple-Music track or resume window. Prevents repeated 1.0 s timeouts
    /// and unbounded OSLog queries while keeping probing re-enabled on track
    /// changes, playback resume, and valid bit-depth-only reports.
    private var formatProbeBudget = FormatProbeBudget()
    private var cachedMediaRemoteSampleRate: Double?
    private var cachedBitDepthEvidence: TrackFormatResolutionPolicy.BitDepthEvidence?

    private func resetNonAppleMusicProbeWindow() {
        formatProbeBudget.resetForNewWindow()
        cachedMediaRemoteSampleRate = nil
        cachedBitDepthEvidence = nil
    }
    private var trackAndSample = [MediaTrack : Float64]()
    private var trackAndBitDepth = [MediaTrack : Int]()
    private var trackLockedDeviceUID = [MediaTrack : String]()
    private var trackDeviceMatch = [MediaTrack : SteadyStatePollingPolicy.ConfirmedDeviceMatch]()
    private var appleMusicFormatEvidence: CMPlayerStats?
    private var appleMusicDecoderFormatEvidence: CMPlayerStats?
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
    
    func getDeviceSampleRate() {
        processQueue.async { [weak self] in
            self?.refreshCurrentOutputFormat()
        }
    }

    func outputDeviceDidChange() {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.refreshCurrentOutputFormat()
            self.pendingCandidate = nil
            // Preserve the current track's verified format evidence across output device
            // switches, while resetting the probe retry budget for the new DAC.
            self.formatProbeBudget.resetForNewWindow()
            guard let currentTrack = self.currentTrack else { return }
            self.switchLatestSampleRate(for: currentTrack, generation: self.currentTrackGeneration)
        }
    }

    private func hasConfirmedTrackFormat(for track: MediaTrack) -> Bool {
        trackAndSample[track] != nil || trackDeviceMatch[track] != nil
    }

    private func isTrackLockedOnDevice(_ track: MediaTrack, device: AudioDevice?) -> Bool {
        guard let lockedRate = trackAndSample[track],
              let deviceRate = device?.nominalSampleRate,
              deviceRate == lockedRate else {
            return false
        }
        if let lockedUID = trackLockedDeviceUID[track],
           let currentUID = device?.uid,
           lockedUID != currentUID {
            return false
        }
        return true
    }

    private func isCurrentDeviceMatched(for track: MediaTrack, device: AudioDevice?) -> Bool {
        let currentBitDepth = device?.streams(scope: .output)?.first?.physicalFormat
            .map { Int($0.mBitsPerChannel) }
            .flatMap { $0 > 0 ? $0 : nil }
        return SteadyStatePollingPolicy.isDeviceMatched(
            lockedSampleRate: trackAndSample[track],
            lockedBitDepth: trackAndBitDepth[track],
            lockedDeviceUID: trackLockedDeviceUID[track],
            confirmedMatch: trackDeviceMatch[track],
            currentDeviceUID: device?.uid,
            currentDeviceSampleRate: device?.nominalSampleRate,
            currentDeviceBitDepth: currentBitDepth,
            enableBitDepthDetection: enableBitDepthDetection
        )
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

    private func isExpectedTrackCurrent(_ expectedTrack: MediaTrack?, generation: UInt64? = nil) -> Bool {
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
            RateSyncLog.switching.info("[getAllStats] \(allStats)")
        }
        catch {
            RateSyncLog.switching.info("[getAllStats, error] \(error)")
        }

        return allStats
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

    private func resolveAppleMusicCurrentTrackSampleRate(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        scheduleAppleMusicAtmosProbeIfNeeded(expectedTrack: expectedTrack, generation: generation)

        switch appleMusicSampleRateState {
        case .inactive:
            return
        case .querying:
            return
        case .notPlaying:
            // MediaRemote can retain the same track snapshot across pause/resume.
            // Reset the detection and query windows when playback resumes; otherwise a
            // long pause would make the first resumed query look timed out or settled.
            let resumedAt = Date()
            currentTrackStartedAt = resumedAt
            currentTrackRequeryStartedAt = resumedAt
            appleMusicSampleRateState = .waiting
            appleMusicSampleRateWaitStartedAt = resumedAt
            appleMusicAtmosProbeCompletedGeneration = nil
            appleMusicAtmosProbeLastCompletedAt = nil
        case .resolved(let sampleRate):
            let now = Date()
            guard AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: appleMusicSampleRateLastQueriedAt,
                now: now,
                trackStartedAt: currentTrackRequeryStartedAt ?? currentTrackStartedAt,
                isTrackLocked: hasConfirmedTrackFormat(for: expectedTrack)
            ) else {
                applyAppleMusicCurrentTrackSampleRate(
                    sampleRate,
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: recursion
                )
                return
            }

            // A quick first answer can be a transient 44.1 kHz value while
            // Music finishes loading a 96/192 kHz track. Start a fresh bounded
            // query window for the same track instead of reusing that answer.
            RateSyncLog.switching.info(
                "[AM CurrentTrackRate] revalidating settled track after \(AppleMusicCurrentTrackRatePolicy.revalidationInterval, privacy: .public)s"
            )
            appleMusicSampleRateState = .waiting
            appleMusicSampleRateWaitStartedAt = now
        case .fallbackToLogs:
            if !preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            ) {
                runAppleMusicLogFallback(expectedTrack: expectedTrack, generation: generation, recursion: recursion)
            }
            return
        case .waiting:
            break
        }

        let startedAt = appleMusicSampleRateWaitStartedAt ?? Date()
        appleMusicSampleRateWaitStartedAt = startedAt
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= AppleMusicSampleRatePolicy.maximumWait {
            logAppleMusicSampleRateDecision(
                track: expectedTrack,
                elapsed: elapsed,
                result: "missing value",
                fallback: appleMusicLastKnownCurrentTrackSampleRate == nil
                    ? "timeout"
                    : "timeout_preserveCurrentTrack"
            )
            if !preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            ) {
                appleMusicSampleRateState = .fallbackToLogs
                runAppleMusicLogFallback(
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: true
                )
            }
            return
        }

        appleMusicSampleRateQueryID &+= 1
        let queryID = appleMusicSampleRateQueryID
        appleMusicSampleRateState = .querying
        appleMusicSampleRateLastQueriedAt = Date()
        let remaining = max(0, AppleMusicSampleRatePolicy.maximumWait - elapsed)
        processQueue.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self,
                  AppleMusicSampleRateQueryPolicy.isCurrent(
                      expectedQueryID: queryID,
                      currentQueryID: self.appleMusicSampleRateQueryID
                  ),
                  self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  case .querying = self.appleMusicSampleRateState else { return }
            let timeoutElapsed = Date().timeIntervalSince(startedAt)
            self.logAppleMusicSampleRateDecision(
                track: expectedTrack,
                elapsed: timeoutElapsed,
                result: "AppleScript request timed out",
                fallback: self.appleMusicLastKnownCurrentTrackSampleRate == nil
                    ? "timeout"
                    : "timeout_preserveCurrentTrack"
            )
            if !self.preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            ) {
                self.appleMusicSampleRateState = .fallbackToLogs
                self.runAppleMusicLogFallback(
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: true
                )
            }
        }
        appleMusic.fetchCurrentTrackSampleRate { [weak self] result in
            guard let self else { return }
            self.processQueue.async { [weak self] in
                guard let self else { return }
                guard AppleMusicSampleRateQueryPolicy.isCurrent(
                    expectedQueryID: queryID,
                    currentQueryID: self.appleMusicSampleRateQueryID
                ) else { return }
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                    RateSyncLog.switching.info("[AM CurrentTrackRate] stale AppleScript result discarded")
                    return
                }
                guard case .querying = self.appleMusicSampleRateState else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let resolution = elapsed >= AppleMusicSampleRatePolicy.maximumWait
                    ? AppleMusicSampleRateResolution.fallbackToLogs
                    : AppleMusicSampleRatePolicy.resolution(for: result, elapsed: elapsed)
                self.logAppleMusicSampleRateDecision(
                    track: expectedTrack,
                    elapsed: elapsed,
                    result: result.logLabel,
                    fallback: resolution == .fallbackToLogs
                        ? (elapsed >= AppleMusicSampleRatePolicy.maximumWait || result == .missingValue ? "timeout" : "unavailable")
                        : nil
                )

                switch resolution {
                case .apply(let sampleRate):
                    self.applyAppleMusicCurrentTrackSampleRate(
                        sampleRate,
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: recursion
                    )
                case .retry(let delay):
                    self.appleMusicSampleRateState = .waiting
                    self.processQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self,
                              AppleMusicSampleRateQueryPolicy.isCurrent(
                                  expectedQueryID: queryID,
                                  currentQueryID: self.appleMusicSampleRateQueryID
                              ),
                              self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                        self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
                    }
                case .fallbackToLogs:
                    if !self.preserveAppleMusicCurrentTrackRateOrFallback(
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: true
                    ) {
                        self.appleMusicSampleRateState = .fallbackToLogs
                        self.runAppleMusicLogFallback(
                            expectedTrack: expectedTrack,
                            generation: generation,
                            recursion: true
                        )
                    }
                case .noPlayback:
                    self.appleMusicSampleRateState = .notPlaying
                    self.appleMusicSampleRateWaitStartedAt = nil
                    self.scheduleAppleMusicResumeCheck(
                        expectedTrack: expectedTrack,
                        generation: generation
                    )
                }
            }
        }
    }

    private func scheduleAppleMusicResumeCheck(
        expectedTrack: MediaTrack,
        generation: UInt64
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation),
              appleMusicResumeRetryWorkItem == nil,
              let delay = AppleMusicPlaybackRecoveryPolicy.retryDelay(
                  hasCurrentTrack: true,
                  isTrackLocked: hasConfirmedTrackFormat(for: expectedTrack),
                  attempts: appleMusicResumeCheckAttempts
              ) else {
            return
        }
        appleMusicResumeCheckAttempts += 1

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appleMusicResumeRetryWorkItem = nil
            guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  case .notPlaying = self.appleMusicSampleRateState else {
                return
            }
            self.switchLatestSampleRate(
                for: expectedTrack,
                recursion: true,
                generation: generation
            )
        }
        appleMusicResumeRetryWorkItem = workItem
        processQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func applyAppleMusicCurrentTrackSampleRate(
        _ sampleRate: Double,
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }

        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: sampleRate,
            decoderEvidence: appleMusicDecoderFormatEvidence,
            formatEvidence: appleMusicFormatEvidence,
            trackStartedAt: currentTrackStartedAt,
            expectedTrackID: expectedTrack.id,
            expectedTrackTitle: expectedTrack.title,
            decoderToleranceThreshold: lastTrackChangeDate
        ) ?? sampleRate

        if effectiveRate.isFinite,
           effectiveRate > 0,
           effectiveRate <= RateSwitchingPolicy.maxPlausibleSampleRate {
            appleMusicLastKnownCurrentTrackSampleRate = effectiveRate
        }

        // A later AppleScript or decoder answer for the same track is new evidence, not
        // jitter from another track. Drop the old same-track lock so the
        // normal stability gate can confirm and apply the corrected rate.
        if let cachedSampleRate = trackAndSample[expectedTrack],
           cachedSampleRate != effectiveRate {
            trackAndSample.removeValue(forKey: expectedTrack)
            trackAndBitDepth.removeValue(forKey: expectedTrack)
            trackLockedDeviceUID.removeValue(forKey: expectedTrack)
            pendingCandidate = nil
            RateSyncLog.switching.info(
                "[AM CurrentTrackRate] replacing stale same-track rate \(cachedSampleRate, privacy: .public) with \(effectiveRate, privacy: .public)"
            )
        }
        if let matched = trackDeviceMatch[expectedTrack],
           matched.sourceSampleRate != effectiveRate,
           matched.sampleRate != effectiveRate {
            trackDeviceMatch.removeValue(forKey: expectedTrack)
        }
        let atmosphere = appleMusicFormatEvidence.flatMap { stat -> CMPlayerStats? in
            guard AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: stat,
                expectedTrackID: expectedTrack.id,
                expectedTrackTitle: expectedTrack.title,
                trackStartedAt: currentTrackStartedAt
            ) else {
                return nil
            }
            return stat
        }
        let action = AppleMusicCurrentTrackRatePolicy.action(
            hasCurrentTrackRate: effectiveRate.isFinite && effectiveRate > 0,
            hasPriorityEvidence: atmosphere != nil,
            atmosProbeCompleted: appleMusicAtmosProbeCompletedGeneration == generation
        )

        switch action {
        case .applyPriorityFormat:
            guard let atmosphere else { return }
            applyStats(
                [atmosphere],
                source: .appleMusicFormatLog,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        case .waitForAtmosProbe:
            appleMusicSampleRateState = .resolved(effectiveRate)
            return
        case .fallbackToLogs:
            appleMusicSampleRateState = .fallbackToLogs
            runAppleMusicLogFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            )
            return
        case .applyCurrentTrackRate:
            break
        }

        appleMusicSampleRateState = .resolved(effectiveRate)
        let atmosProbeStatus = appleMusicAtmosProbeCompletedGeneration == generation ? "complete" : "pending"
        RateSyncLog.switching.info("[AM RateDecision] source=AppleScript/Decoder action=stabilityGate sampleRate=\(effectiveRate, privacy: .public) atmosProbe=\(atmosProbeStatus, privacy: .public)")

        let stat = CMPlayerStats.sampleRateOnly(
            sampleRate: effectiveRate,
            bitDepth: AppleMusicFormatPolicy.bitDepthEvidence(
                formatEvidence: appleMusicFormatEvidence,
                fallbackEvidence: appleMusicFallbackFormat,
                decoderEvidence: appleMusicDecoderFormatEvidence,
                expectedTrackID: expectedTrack.id,
                expectedTrackTitle: expectedTrack.title
            )
        )
        applyStats(
            [stat],
            source: .appleMusicCurrentTrack,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
        scheduleAppleMusicEQUpdate()
    }

    /// Keep a valid same-track AppleScript result authoritative when a later
    /// revalidation times out. Log fallback remains available for tracks for
    /// which AppleScript never supplied a usable current-track rate.
    @discardableResult
    private func preserveAppleMusicCurrentTrackRateOrFallback(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) -> Bool {
        let hasKnownCurrentTrackRate = appleMusicLastKnownCurrentTrackSampleRate != nil
        guard AppleMusicCurrentTrackRatePolicy.shouldPreserveCurrentTrackRateOnFallback(
                  hasKnownCurrentTrackRate: hasKnownCurrentTrackRate
              ),
              let sampleRate = appleMusicLastKnownCurrentTrackSampleRate else {
            return false
        }

        appleMusicSampleRateState = .resolved(sampleRate)
        RateSyncLog.switching.info(
            "[AM CurrentTrackRate] revalidation fallback preserved last AppleScript rate \(sampleRate, privacy: .public)"
        )
        applyAppleMusicCurrentTrackSampleRate(
            sampleRate,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
        return true
    }

    private func runAppleMusicLogFallback(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        appleMusicFallbackAttemptedForTrack = true
        runLogChain(expectedTrack: expectedTrack, generation: generation, recursion: recursion)
        scheduleAppleMusicRecoveryProbeIfNeeded(expectedTrack: expectedTrack, generation: generation)
    }

    private func scheduleAppleMusicRecoveryProbeIfNeeded(expectedTrack: MediaTrack, generation: UInt64) {
        guard AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
            state: appleMusicSampleRateState,
            hasKnownCurrentTrackRate: appleMusicLastKnownCurrentTrackSampleRate != nil,
            attempts: appleMusicRecoveryAttempts
        ) else { return }
        guard appleMusicRecoveryWorkItem == nil else { return }

        let attempts = appleMusicRecoveryAttempts + 1
        appleMusicRecoveryAttempts = attempts
        let delay = AppleMusicCurrentTrackRatePolicy.recoveryProbeInterval
        RateSyncLog.switching.info("[AM RecoveryProbe] scheduling recovery attempt \(attempts, privacy: .public)/\(AppleMusicCurrentTrackRatePolicy.maxRecoveryAttempts, privacy: .public) in \(delay, privacy: .public)s")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appleMusicRecoveryWorkItem = nil
            guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  self.isAppleMusicSource,
                  case .fallbackToLogs = self.appleMusicSampleRateState,
                  self.appleMusicLastKnownCurrentTrackSampleRate == nil else { return }

            RateSyncLog.switching.info("[AM RecoveryProbe] attempting to recover primary AppleScript source (attempt \(attempts, privacy: .public))")
            self.appleMusicSampleRateState = .waiting
            self.appleMusicFallbackAttemptedForTrack = false
            self.appleMusicSampleRateWaitStartedAt = Date()
            self.resolveAppleMusicCurrentTrackSampleRate(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            )
        }
        appleMusicRecoveryWorkItem = workItem
        processQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleAppleMusicAtmosProbeIfNeeded(expectedTrack: MediaTrack, generation: UInt64) {
        guard AppleMusicFormatProbePolicy.shouldSchedule(
            generation: generation,
            scheduledGeneration: appleMusicAtmosProbeScheduledGeneration,
            completedGeneration: appleMusicAtmosProbeCompletedGeneration,
            lastCompletedAt: appleMusicAtmosProbeLastCompletedAt,
            now: Date(),
            trackStartedAt: currentTrackRequeryStartedAt ?? currentTrackStartedAt,
            sampleRateState: appleMusicSampleRateState
        ) else { return }
        appleMusicAtmosProbeScheduledGeneration = generation
        let logThreshold = lastTrackChangeDate
        let trackID = expectedTrack.id ?? "unknown"
        let probeStartedAt = appleMusicSampleRateWaitStartedAt ?? Date()

        appleMusicAtmosProbeQueue.async { [weak self] in
            guard let self else { return }
            let stats = self.getAllStats(
                process: PlayerProfile.appleMusic.processName,
                parser: CMPlayerParser.parseAppleMusicConsoleLogs,
                durationSeconds: AppleMusicFormatParser.logWindowSeconds
            ).filter { stat in
                guard let logThreshold else { return true }
                return stat.date >= logThreshold
            }

            self.processQueue.async { [weak self] in
                guard let self else { return }
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                      self.isAppleMusicSource else { return }
                self.rememberAppleMusicFormat(from: stats, for: expectedTrack)
                self.rememberAppleMusicDecoderFormat(from: stats, for: expectedTrack)
                if let preferredFormat = self.appleMusicFormatEvidence,
                   preferredFormat.isPriorityAppleMusicFormat {
                    let isMismatched = preferredFormat.isMismatched(trackID: expectedTrack.id, title: expectedTrack.title)
                    if isMismatched || (self.currentTrackStartedAt.map { preferredFormat.date < $0 } == true && !preferredFormat.isAttributed(trackID: expectedTrack.id, title: expectedTrack.title)) {
                        self.appleMusicFormatEvidence = nil
                        return
                    }
                    let canOverrideConfirmed = AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                        formatEvidence: preferredFormat,
                        expectedTrackID: expectedTrack.id,
                        expectedTrackTitle: expectedTrack.title,
                        trackStartedAt: self.currentTrackStartedAt
                    )
                    let canUseUnattributedFallback = (self.appleMusicSampleRateState == .fallbackToLogs)
                        && (self.appleMusicLastKnownCurrentTrackSampleRate == nil)
                        && !isMismatched
                    if canOverrideConfirmed || canUseUnattributedFallback {
                        self.appleMusicAtmosProbeCompletedGeneration = generation
                        self.appleMusicAtmosProbeScheduledGeneration = nil
                        self.appleMusicAtmosProbeLastCompletedAt = Date()
                        guard self.appleMusicSampleRateState != .notPlaying else { return }

                        let elapsed = Date().timeIntervalSince(probeStartedAt)
                        let evidenceType = preferredFormat.isDolbyAtmos ? "DolbyAtmos" : "spatialAudio"
                        RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) source=AppleMusicLog type=\(evidenceType, privacy: .public) sampleRate=\(preferredFormat.sampleRate, privacy: .public) elapsed=\(elapsed, privacy: .public)s")
                        self.applyStats(
                            [preferredFormat],
                            source: .appleMusicFormatLog,
                            expectedTrack: expectedTrack,
                            generation: generation,
                            recursion: false
                        )
                        return
                    }
                }

                let elapsed = Date().timeIntervalSince(probeStartedAt)
                guard self.appleMusicSampleRateState != .notPlaying else {
                    self.appleMusicAtmosProbeCompletedGeneration = generation
                    self.appleMusicAtmosProbeScheduledGeneration = nil
                    self.appleMusicAtmosProbeLastCompletedAt = Date()
                    return
                }

                if let retryDelay = AppleMusicFormatProbePolicy.retryDelay(
                    after: elapsed,
                    hasPriorityEvidence: false
                ) {
                    RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) found=false elapsed=\(elapsed, privacy: .public)s retryIn=\(retryDelay, privacy: .public)s")
                    self.processQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                        guard let self,
                              self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                              self.appleMusicAtmosProbeScheduledGeneration == generation else { return }
                        self.appleMusicAtmosProbeScheduledGeneration = nil
                        self.scheduleAppleMusicAtmosProbeIfNeeded(
                            expectedTrack: expectedTrack,
                            generation: generation
                        )
                    }
                    return
                }

                self.appleMusicAtmosProbeCompletedGeneration = generation
                self.appleMusicAtmosProbeScheduledGeneration = nil
                self.appleMusicAtmosProbeLastCompletedAt = Date()
                RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) found=false elapsed=\(elapsed, privacy: .public)s fallback=AppleScript")
                if case .resolved(let sampleRate) = self.appleMusicSampleRateState {
                    self.applyAppleMusicCurrentTrackSampleRate(
                        sampleRate,
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: true
                    )
                }
            }
        }
    }

    private func logAppleMusicSampleRateDecision(
        track: MediaTrack,
        elapsed: TimeInterval,
        result: String,
        fallback: String?
    ) {
        let fallbackDescription = fallback ?? "none"
        RateSyncLog.switching.info("[AM CurrentTrackRate] track=\(track.id ?? "unknown", privacy: .public) source=AppleScript elapsed=\(elapsed, privacy: .public)s result=\(result, privacy: .public) fallback=\(fallbackDescription, privacy: .public)")
    }

    private func applyAppleMusicPriorityOrMediaRemote(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard shouldPrioritizeAppleMusic, appleMusic.isRunning else {
            applyMediaRemoteProbe(
                sampleRate: sampleRate,
                reportedBitDepth: reportedBitDepth,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }

        appleMusic.fetchPlaybackState { [weak self] state in
            guard let self else { return }
            self.processQueue.async {
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                    RateSyncLog.switching.info("stale switch task after Apple Music priority check, skip")
                    return
                }
                if let state,
                   state.isPlaying,
                   let appleMusicSampleRate = state.sampleRate,
                   appleMusicSampleRate > 0 {
                    // This fallback reports only the rate; output bit depth is not source evidence.
                    let stat = CMPlayerStats.sampleRateOnly(sampleRate: appleMusicSampleRate)
                    RateSyncLog.switching.info("[AM Priority] Apple Music is playing, using its sample rate")
                    self.applyStats([stat], source: .appleMusicPriority, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    self.scheduleAppleMusicEQUpdate()
                    return
                }
                self.applyMediaRemoteProbe(
                    sampleRate: sampleRate,
                    reportedBitDepth: reportedBitDepth,
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: recursion
                )
            }
        }
    }

    private func recordMediaRemoteBitDepthEvidence(_ validDepth: Int?, at date: Date) {
        guard let validDepth else { return }
        let probeEvidence = TrackFormatResolutionPolicy.BitDepthEvidence(
            bitDepth: validDepth,
            source: .mediaRemoteReport,
            date: date
        )
        if TrackFormatResolutionPolicy.shouldPreferBitDepthEvidence(
            probeEvidence,
            over: cachedBitDepthEvidence
        ) {
            cachedBitDepthEvidence = probeEvidence
        }
    }

    private func applyMediaRemoteProbe(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        let now = Date()
        let validRate = TrackFormatResolutionPolicy.validSampleRate(sampleRate)
        if let validRate {
            cachedMediaRemoteSampleRate = validRate
        }
        let validDepth = TrackFormatResolutionPolicy.validBitDepth(reportedBitDepth)
        recordMediaRemoteBitDepthEvidence(validDepth, at: now)
        let effectiveRate = validRate ?? cachedMediaRemoteSampleRate
        let targetTrack = expectedTrack ?? currentTrack
        let bundleID = Self.resolveBundleIdentifier(track: targetTrack)
        let presetRate = Self.presetSampleRate(for: bundleID)

        if let effectiveRate,
           validDepth != nil || !enableBitDepthDetection || presetRate == nil {
            let effectiveDepth = validDepth ?? (enableBitDepthDetection ? cachedBitDepthEvidence?.bitDepth : nil)
            let stat = CMPlayerStats(sampleRate: effectiveRate, bitDepth: effectiveDepth, date: now)
            RateSyncLog.switching.info("[MRProbe] direct audio format: \(effectiveRate) Hz, \(effectiveDepth ?? -1) bit")
            applyStats([stat], source: .mediaRemoteProbe, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
            return
        }

        runLogChain(
            probeSampleRate: effectiveRate,
            probeBitDepth: validDepth,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
    }

    /// Log-based rate resolution plus preset/MediaRemote field merging, run after the
    /// MediaRemote probe reported partial/no format data (or was skipped).
    private func runLogChain(
        probeSampleRate: Double? = nil,
        probeBitDepth: Int? = nil,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        let targetTrack = expectedTrack ?? currentTrack
        let now = Date()

        if !isAppleMusicSource {
            let bundleID = Self.resolveBundleIdentifier(track: targetTrack)
            let presetRate = Self.presetSampleRate(for: bundleID)
            let validProbeDepth = TrackFormatResolutionPolicy.validBitDepth(probeBitDepth)
            let hasVerifiedMediaRemoteBitDepth = validProbeDepth != nil
                || cachedBitDepthEvidence?.source == .mediaRemoteReport
            let shouldQueryLogs = formatProbeBudget.shouldProbeLogs(
                hasPresetSampleRate: presetRate != nil,
                hasMediaRemoteBitDepth: hasVerifiedMediaRemoteBitDepth,
                enableBitDepthDetection: enableBitDepthDetection,
                now: now
            )
            let rawLogStats: [CMPlayerStats]
            if shouldQueryLogs {
                rawLogStats = self.statsFromLogs(for: targetTrack, recursion: recursion)
                if presetRate != nil {
                    let foundBitDepth = rawLogStats.contains { TrackFormatResolutionPolicy.validBitDepth($0.bitDepth) != nil }
                    formatProbeBudget.recordLogAttempt(foundBitDepth: foundBitDepth, now: now)
                }
            } else {
                rawLogStats = []
            }

            let aqSource = self.audioQueueSource(for: rawLogStats)
            let resolution = TrackFormatResolutionPolicy.resolveNonAppleMusic(
                mediaRemoteSampleRate: probeSampleRate,
                mediaRemoteBitDepth: probeBitDepth,
                logStats: rawLogStats,
                cachedSampleRate: cachedMediaRemoteSampleRate,
                cachedBitDepthEvidence: cachedBitDepthEvidence,
                presetSampleRate: presetRate,
                audioQueueSource: aqSource,
                defaultLogSource: aqSource,
                enableBitDepthDetection: enableBitDepthDetection,
                now: now
            )
            if let resolvedEvidence = resolution.resolvedBitDepthEvidence,
               TrackFormatResolutionPolicy.shouldPreferBitDepthEvidence(resolvedEvidence, over: cachedBitDepthEvidence) {
                cachedBitDepthEvidence = resolvedEvidence
            }
            if let first = resolution.stats.first, let bundleID, presetRate != nil {
                RateSyncLog.switching.info("[PresetMerge] \(bundleID, privacy: .public) -> \(first.sampleRate, privacy: .public) Hz, \(first.bitDepth ?? -1, privacy: .public) bit")
            }
            self.applyStats(
                resolution.stats,
                source: resolution.source,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }

        let rawLogStats = self.statsFromLogs(for: targetTrack, recursion: recursion)
        let toleranceThreshold = recursion ? lastTrackChangeDate?.addingTimeInterval(-1.5) : lastTrackChangeDate
        let logStats = AppleMusicFormatPolicy.filterFallbackLogs(
            rawLogStats,
            expectedTrackID: targetTrack?.id,
            expectedTrackTitle: targetTrack?.title,
            trackStartedAt: currentTrackStartedAt,
            toleranceThreshold: toleranceThreshold
        )
        rememberAppleMusicFormat(from: logStats, for: targetTrack)
        rememberAppleMusicDecoderFormat(from: logStats, for: targetTrack)
        let preferredFallback = AppleMusicFormatPolicy.preferredFallbackEvidence(
            formatEvidence: appleMusicFormatEvidence,
            decoderEvidence: appleMusicDecoderFormatEvidence,
            expectedTrackID: targetTrack?.id,
            expectedTrackTitle: targetTrack?.title,
            trackStartedAt: currentTrackStartedAt,
            decoderToleranceThreshold: toleranceThreshold
        )
        let appleMusicResolution = AppleMusicFormatPolicy.resolution(
            hasLogEvidence: preferredFallback != nil,
            hasLogStats: !logStats.isEmpty,
            hasCachedFallback: appleMusicFallbackFormat != nil,
            hasAttemptedFallback: appleMusicFallbackAttemptedForTrack,
            isPlaying: appleMusic.isRunning
        )
        if appleMusicResolution == .logEvidence,
           let preferredFallback {
            applyStats(
                [preferredFallback.stat],
                source: preferredFallback.source,
                expectedTrack: expectedTrack,
                generation: generation,
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
                generation: generation,
                recursion: recursion
            )
            return
        }
        if appleMusicResolution == .requestAppleScript {
            appleMusicFallbackAttemptedForTrack = true
            appleMusic.fetchPlaybackState { [weak self] state in
                guard let self else { return }
                self.processQueue.async {
                    guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                        RateSyncLog.switching.info("stale switch task after Apple Music log fallback, skip")
                        return
                    }
                    if let state,
                       state.isPlaying,
                       let sampleRate = state.sampleRate,
                       sampleRate > 0 {
                        // This fallback reports only the rate; output bit depth is not source evidence.
                        let stat = CMPlayerStats.sampleRateOnly(sampleRate: sampleRate)
                        self.appleMusicFallbackFormat = stat
                        RateSyncLog.switching.info("[LogFallback] Apple Music AppleScript sample rate: \(sampleRate)")
                        self.applyStats([stat], source: .decoderLog, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    } else {
                        self.applyStats([], source: .decoderLog, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    }
                }
            }
            return
        }
        let source: RateSource = logStats.first?.isAppleMusicFormat == true ? .appleMusicFormatLog : .decoderLog
        self.applyStats(logStats, source: source, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
    }

    private func rememberAppleMusicFormat(from stats: [CMPlayerStats], for track: MediaTrack? = nil) {
        let targetTrack = track ?? currentTrack
        if let existing = appleMusicFormatEvidence,
           existing.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) {
            appleMusicFormatEvidence = nil
        }
        let trackStartedAt = currentTrackStartedAt
        let validStats = stats.filter { stat in
            guard stat.isAppleMusicFormat else { return false }
            switch stat.attribution(trackID: targetTrack?.id, title: targetTrack?.title) {
            case .mismatched:
                return false
            case .matched:
                return true
            case .unattributed:
                guard let trackStartedAt else { return true }
                return stat.date >= trackStartedAt
            }
        }
        let incoming = validStats.first(where: { $0.isPriorityAppleMusicFormat && $0.isAttributed(trackID: targetTrack?.id, title: targetTrack?.title) })
            ?? validStats.max(by: { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return !lhs.isPriorityAppleMusicFormat && rhs.isPriorityAppleMusicFormat
            })
        guard let incoming else {
            return
        }
        let existing = appleMusicFormatEvidence
        guard AppleMusicFormatPolicy.shouldReplaceCachedFormat(
            currentIsPriorityFormat: existing?.isPriorityAppleMusicFormat == true,
            incomingIsPriorityFormat: incoming.isPriorityAppleMusicFormat,
            currentIsAttributedToTrack: existing?.isAttributed(trackID: targetTrack?.id, title: targetTrack?.title) == true,
            incomingIsNewer: existing.map { incoming.date > $0.date } ?? true
        ) else {
            return
        }
        appleMusicFormatEvidence = incoming
    }

    private func rememberAppleMusicDecoderFormat(from stats: [CMPlayerStats], for track: MediaTrack? = nil) {
        let targetTrack = track ?? currentTrack
        if let existing = appleMusicDecoderFormatEvidence,
           existing.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) {
            appleMusicDecoderFormatEvidence = nil
        }
        let minDate = lastTrackChangeDate ?? currentTrackStartedAt
        guard let incoming = stats
            .filter({ stat in
                guard !stat.isAppleMusicFormat && stat.bitDepth != nil else { return false }
                guard !stat.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) else { return false }
                if let minDate {
                    return stat.date >= minDate
                }
                return true
            })
            .max(by: { $0.date < $1.date }) else {
            return
        }
        if let existing = appleMusicDecoderFormatEvidence,
           incoming.date < existing.date {
            return
        }
        appleMusicDecoderFormatEvidence = incoming
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
            RateSyncLog.switching.info("[Gate] AudioQueue log predates track change, using conservative gate")
            return .staleAudioQueueLog
        }
        return .audioQueueLog
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
    private func statsFromLogs(for track: MediaTrack? = nil, recursion: Bool) -> [CMPlayerStats] {
        guard let processName = Self.resolveProcessName(track: track ?? currentTrack) else {
            RateSyncLog.switching.info("cannot resolve source process name, skipping log chain")
            return []
        }
        let isMusicProcess = (processName == PlayerProfile.appleMusic.processName)

        var allStats: [CMPlayerStats]
        if isMusicProcess {
            guard isAppleMusicSource else { return [] }
            // P2: recursive retries widen the tolerance window. Apple Music decoder logs can be
            // written more than 0.5s before the MediaRemote event (e.g. delayed UI state updates);
            // a strict filter would permanently discard them and, if the AppleScript fallback
            // also fails, the switch would be lost.
            let threshold = recursion
                ? lastTrackChangeDate?.addingTimeInterval(-1.5)
                : lastTrackChangeDate
            allStats = self.cachedAppleMusicStats(process: processName)
            if let threshold {
                allStats = allStats.filter { $0.date >= threshold }
            }
        } else {
            RateSyncLog.switching.info("log chain for process \(processName) via AudioQueue parser")
            // AudioQueue session pairing boundary must remain strictly consistent across retries.
            // Widening the boundary for retries would pull in previous-track converter logs (e.g. t - 0.8s)
            // that erroneously suppress the new track's hardware output logs (t), causing wrong switches.
            let aqBoundary = lastTrackChangeDate
            allStats = self.cachedAudioQueueStats(process: processName, since: aqBoundary)
            if let aqBoundary {
                allStats = allStats.filter { $0.date >= aqBoundary }
            }
        }
        return allStats
    }

    /// Prunes expired entries from `logStatsCache` so old generation/track entries
    /// do not accumulate across songs.
    private func pruneLogStatsCache(now: Date = Date()) {
        LogStatsCachePolicy.prune(
            &logStatsCache,
            currentGeneration: currentTrackGeneration,
            now: now,
            ttl: Self.logStatsTTL
        )
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
    /// The cached value is keyed by process, generation, and since boundary,
    /// with pre-filtering by `since` ensuring companion suppression only evaluates
    /// entries belonging to the current playback window.
    private func cachedAudioQueueStats(process: String, since: Date? = nil) -> [CMPlayerStats] {
        pruneLogStatsCache()
        let key = LogStatsCachePolicy.audioQueueCacheKey(
            process: process,
            generation: currentTrackGeneration,
            since: since
        )
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            RateSyncLog.switching.info("[LogCache] hit for \(process, privacy: .public) (\(cached.stats.count) stats)")
            return cached.stats
        }
        let stats = self.getAllStats(process: process,
                                     parser: { CMPlayerParser.parseAudioQueueConsoleLogs($0, since: since) },
                                     durationSeconds: 60)
        if stats.isEmpty {
            // Do not cache "nothing found" - the line may simply not be
            // written yet, and the gate must be able to re-query.
            logStatsCache.removeValue(forKey: key)
            RateSyncLog.switching.info("[LogCache] miss for \(process, privacy: .public) (no stats, not cached)")
        } else {
            logStatsCache[key] = (stats, Date())
            RateSyncLog.switching.info("[LogCache] stored for \(process, privacy: .public) (\(stats.count) stats)")
        }
        return stats
    }

    private func cachedAppleMusicStats(process: String) -> [CMPlayerStats] {
        pruneLogStatsCache()
        let key = LogStatsCachePolicy.appleMusicCacheKey(process: process)
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            RateSyncLog.switching.info("[LogCache] hit for Apple Music (\(cached.stats.count) stats)")
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
            RateSyncLog.switching.info("[LogCache] stored for Apple Music (\(stats.count) stats)")
        }
        return stats
    }

    /// Applies the best matching device format for the given stats, and
    /// schedules one retry when nothing usable was found yet.
    private func applyStats(
        _ allStats: [CMPlayerStats],
        source: RateSource = .decoderLog,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
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
            let currentOutputBitDepth = defaultDevice?.streams(scope: .output)?.first?.physicalFormat
                .map { Int($0.mBitsPerChannel) }
                .flatMap { $0 > 0 ? $0 : nil }
            // This is only a selector hint; the final 24-bit fallback must never count as evidence
            // for changing bit depth when the source did not report one.
            let selectionHintBitDepth = first.bitDepth ?? currentOutputBitDepth ?? previousBitDepth ?? 24
            // Clamp instead of truncating, and clamp before use:
            // Int32(truncatingIfNeeded:) silently turns an absurd depth
            // into a bogus but plausible-looking value
            // (99999999999999 -> 276447231). A garbage depth must not cost
            // us a valid rate, so it is clamped, not rejected.
            let bitDepth = Int32(clamping: min(max(selectionHintBitDepth, 1), RateSwitchingPolicy.maxPlausibleBitDepth))

            // Boundary gating: right after a track change, players
            // transitioning between formats (e.g. Dolby Atmos) report an
            // intermediate rate (44.1 kHz) for several seconds before
            // settling on the real one — via decoder logs AND via the
            // MediaRemote probe itself. A differing rate may only be
            // applied when (a) the post-track-change window has closed
            // AND (b) the same candidate has persisted across evaluations.
            // Both windows count down concurrently from the candidate's first observation.
            // Equal-rate candidates pass through untouched.
            let sinceTrackChange = lastTrackChangeDate.map {
                Date().timeIntervalSince($0)
            } ?? .infinity
            let rateDiffersFromDevice = defaultDevice?.nominalSampleRate != sampleRate
            if rateDiffersFromDevice {
                let alreadyConfirmedForTrack = currentTrack.map { track in
                    trackAndSample[track] == sampleRate
                        || (sinceTrackChange >= policy.boundary && trackDeviceMatch[track]?.sourceSampleRate == sampleRate)
                } ?? false
                if !alreadyConfirmedForTrack {
                    let now = Date()
                    let candidate = RateGateDecisionPolicy.updateCandidate(
                        current: pendingCandidate,
                        rate: sampleRate,
                        generation: generation,
                        now: now
                    )
                    pendingCandidate = candidate

                    let isLocked = currentTrack.map { isTrackLockedOnDevice($0, device: defaultDevice) } ?? false
                    let requiredPersistence = RateGateDecisionPolicy.requiredPersistence(
                        isLocked: isLocked,
                        policy: policy
                    )
                    let boundarySatisfied = RateGateDecisionPolicy.isBoundarySatisfied(
                        sinceTrackChange: sinceTrackChange,
                        policy: policy
                    )
                    let stabilitySatisfied = RateGateDecisionPolicy.isStabilitySatisfied(
                        candidateFirstSeen: candidate.firstSeen,
                        now: now,
                        requiredPersistence: requiredPersistence
                    )
                    let confirmed = boundarySatisfied && stabilitySatisfied

                    if !confirmed {
                        let persistenceElapsed = now.timeIntervalSince(candidate.firstSeen)
                        if !boundarySatisfied && !stabilitySatisfied {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz inside boundary (\(String(format: "%.1f", sinceTrackChange), privacy: .public)/\(String(format: "%.1f", policy.boundary), privacy: .public)s) and awaiting stability (\(String(format: "%.1f", persistenceElapsed), privacy: .public)/\(String(format: "%.1f", requiredPersistence), privacy: .public)s), re-evaluating in 0.5s")
                        } else if !boundarySatisfied {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) != device \(defaultDevice?.nominalSampleRate ?? -1, privacy: .public) Hz inside boundary window (\(String(format: "%.1f", sinceTrackChange), privacy: .public)/\(String(format: "%.1f", policy.boundary), privacy: .public)s), re-evaluating in 0.5s")
                        } else {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz awaiting stability (\(String(format: "%.1f", persistenceElapsed), privacy: .public)/\(String(format: "%.1f", requiredPersistence), privacy: .public)s), re-evaluating in 0.5s")
                        }
                        processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self,
                                  self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                            self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
                        }
                        return
                    }
                    RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz confirmed stable, applying")
                }
            }
            pendingCandidate = nil

            guard let defaultDevice = defaultDevice,
                  let formats = self.getFormats(device: defaultDevice) else { return }

            let suitableFormat = AudioFormatSelector.nearestFormat(
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                supportedSampleRates: supported,
                formats: formats,
                preferSampleRateMultiples: Defaults.shared.userPreferSampleRateMultiples
            )
            RateSyncLog.switching.info("NEAREST FORMAT \(suitableFormat.map { "\($0.mSampleRate)Hz/\($0.mBitsPerChannel)bit" } ?? "none", privacy: .public)")

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
                   isTrackLockedOnDevice(currentTrack, device: defaultDevice),
                   cachedSampleRate == sampleRate {
                    let bitDepthChanged = RateSwitchingPolicy.shouldApplyBitDepthChange(
                        isEnabled: enableBitDepthDetection,
                        reportedBitDepth: first.bitDepth,
                        currentBitDepth: currentOutputBitDepth ?? trackAndBitDepth[currentTrack],
                        selectedBitDepth: Int(suitableFormat.mBitsPerChannel)
                    )
                    if !bitDepthChanged {
                        self.cacheConfirmedDeviceMatch(
                            currentTrack,
                            deviceUID: defaultDevice.uid,
                            sampleRate: cachedSampleRate,
                            bitDepth: currentOutputBitDepth ?? trackAndBitDepth[currentTrack],
                            sourceSampleRate: sampleRate
                        )
                        RateSyncLog.switching.info("same track, sample rate already applied, skip")
                        return
                    }
                    RateSyncLog.switching.info("same track, bit depth changed, re-applying format")
                }
                let currentDeviceSampleRate = defaultDevice.nominalSampleRate ?? previousSampleRate
                let sampleRateChanged = suitableFormat.mSampleRate != currentDeviceSampleRate
                let bitDepthChanged = RateSwitchingPolicy.shouldApplyBitDepthChange(
                    isEnabled: enableBitDepthDetection,
                    reportedBitDepth: first.bitDepth,
                    currentBitDepth: currentOutputBitDepth ?? previousBitDepth,
                    selectedBitDepth: Int(suitableFormat.mBitsPerChannel)
                )
                let formatChanged = sampleRateChanged || bitDepthChanged

                // An equal-rate result is a NO-OP (device already correct).
                // Applying-and-caching it in `trackAndSample` would wrongly "settle" the track's
                // switching lock: a genuine rate arriving later would then be forced onto
                // the slow 12 s override tier (observed as ~20 s switching
                // when the first read is stale data from the previous
                // track). Leave `trackAndSample` uncached, and record the confirmed device
                // match separately so steady-state polling stops after the settling window.
                if !formatChanged {
                    if let currentTrack = currentTrack {
                        let matchedBitDepth = first.bitDepth != nil
                            ? Int(suitableFormat.mBitsPerChannel)
                            : currentOutputBitDepth ?? previousBitDepth
                        self.cacheConfirmedDeviceMatch(
                            currentTrack,
                            deviceUID: defaultDevice.uid,
                            sampleRate: currentDeviceSampleRate ?? suitableFormat.mSampleRate,
                            bitDepth: matchedBitDepth,
                            sourceSampleRate: sampleRate
                        )
                    }
                    RateSyncLog.switching.info("already at target format, nothing to apply (left uncached)")
                    return
                }

                if first.bitDepth != nil {
                    RateSyncLog.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz depth \(suitableFormat.mBitsPerChannel, privacy: .public)")
                } else {
                    RateSyncLog.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz; bit depth unknown, preserving current depth")
                }
                var applySucceeded = true
                if enableBitDepthDetection && first.bitDepth != nil {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                    let appliedPhysicalFormat = defaultDevice.streams(scope: .output)?.first?.physicalFormat
                    applySucceeded = DeviceFormatVerification.isPhysicalFormatApplied(
                        targetRate: suitableFormat.mSampleRate,
                        targetBitDepth: suitableFormat.mBitsPerChannel,
                        streamPhysicalFormat: appliedPhysicalFormat,
                        nominalRate: defaultDevice.nominalSampleRate
                    )
                } else if sampleRateChanged { // Keep the current depth when the source did not report one.
                    let rateSetOk = defaultDevice.setNominalSampleRate(suitableFormat.mSampleRate)
                    let confirmedNominal = defaultDevice.nominalSampleRate
                    applySucceeded = DeviceFormatVerification.isSampleRateApplied(
                        targetRate: suitableFormat.mSampleRate,
                        nominalRate: confirmedNominal,
                        rateSetOk: rateSetOk
                    )
                }

                if !applySucceeded {
                    if let currentTrack = currentTrack {
                        self.trackDeviceMatch.removeValue(forKey: currentTrack)
                        self.trackAndSample.removeValue(forKey: currentTrack)
                        self.trackAndBitDepth.removeValue(forKey: currentTrack)
                        self.trackLockedDeviceUID.removeValue(forKey: currentTrack)
                    }
                    let streams = defaultDevice.streams(scope: .output)
                    let currentStreamFormat = streams?.first?.physicalFormat
                    let fallback = DeviceFormatVerification.fallbackStateOnFailure(
                        nominalRate: defaultDevice.nominalSampleRate,
                        streamPhysicalFormat: currentStreamFormat,
                        currentOutputBitDepth: currentOutputBitDepth,
                        previousSampleRate: previousSampleRate,
                        previousBitDepth: previousBitDepth
                    )
                    RateSyncLog.switching.error("Device '\(defaultDevice.name, privacy: .public)' rejected format target=(\(suitableFormat.mSampleRate, privacy: .public) Hz, \(suitableFormat.mBitsPerChannel, privacy: .public) bit) nominal=(\(defaultDevice.nominalSampleRate ?? -1, privacy: .public) Hz)")
                    if let fallbackRate = fallback.sampleRate {
                        self.updateSampleRate(
                            fallbackRate,
                            bitDepth: fallback.bitDepth,
                            runUserScript: false,
                            preserveCandidate: true
                        )
                    } else {
                        self.previousSampleRate = nil
                        self.previousBitDepth = fallback.bitDepth
                    }
                    self.pendingCandidate = RateGateDecisionPolicy.CandidateTracking(
                        rate: suitableFormat.mSampleRate,
                        generation: generation,
                        firstSeen: Date()
                    )
                    return
                }

                let appliedBitDepth = first.bitDepth != nil
                    ? Int(suitableFormat.mBitsPerChannel)
                    : currentOutputBitDepth ?? previousBitDepth
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: appliedBitDepth, runUserScript: formatChanged)
                if let currentTrack = currentTrack {
                    self.cacheTrackResult(
                        currentTrack,
                        deviceUID: defaultDevice.uid,
                        sampleRate: suitableFormat.mSampleRate,
                        bitDepth: appliedBitDepth,
                        sourceSampleRate: sampleRate
                    )
                }
            }
        }

        // Console logs may not contain the new track's format yet right after a track change.
        // Retry once shortly instead of waiting for the slower fallback timer.
        if !didFindStat && !recursion {
            processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
            }
        }
    }


    /// Records the format applied for a track, under a hard size cap.
    /// Only `currentTrack` is ever read back, but entries survive until the
    /// next track change, so an unbounded table would retain one entry per
    /// distinct track ever played in a long-running menu bar process.
    private func cacheTrackResult(
        _ track: MediaTrack,
        deviceUID: String? = nil,
        sampleRate: Float64,
        bitDepth: Int?,
        sourceSampleRate: Float64? = nil
    ) {
        self.trackAndSample[track] = sampleRate
        self.trackAndBitDepth[track] = bitDepth
        self.trackLockedDeviceUID[track] = deviceUID
        self.cacheConfirmedDeviceMatch(
            track,
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sourceSampleRate: sourceSampleRate ?? sampleRate
        )
        // Dictionary ordering is unspecified, so this trims arbitrary
        // victims rather than a true LRU - the cap is the safety net, and
        // trackDidChange already removes entries as tracks move on.
        while self.trackAndSample.count > Self.maxCachedTracks {
            guard let victim = self.trackAndSample.keys.first(where: { $0 != self.currentTrack })
                    ?? self.trackAndSample.keys.first else { break }
            self.trackAndSample.removeValue(forKey: victim)
            self.trackAndBitDepth.removeValue(forKey: victim)
            self.trackLockedDeviceUID.removeValue(forKey: victim)
            self.trackDeviceMatch.removeValue(forKey: victim)
        }
    }

    private func cacheConfirmedDeviceMatch(
        _ track: MediaTrack,
        deviceUID: String?,
        sampleRate: Float64,
        bitDepth: Int?,
        sourceSampleRate: Float64?
    ) {
        self.trackDeviceMatch[track] = SteadyStatePollingPolicy.ConfirmedDeviceMatch(
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sourceSampleRate: sourceSampleRate
        )
        while self.trackDeviceMatch.count > Self.maxCachedTracks {
            guard let victim = self.trackDeviceMatch.keys.first(where: { $0 != self.currentTrack })
                    ?? self.trackDeviceMatch.keys.first else { break }
            self.trackDeviceMatch.removeValue(forKey: victim)
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
    
    func updateSampleRate(
        _ sampleRate: Float64,
        bitDepth: Int?,
        runUserScript: Bool = true,
        preserveCandidate: Bool = false
    ) {
        self.previousSampleRate = sampleRate
        if !preserveCandidate {
            self.pendingCandidate = nil
        }
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
                let monitored = Defaults.shared.activeTemporarySourceLock?.bundleIdentifier
                    ?? Defaults.shared.monitoredBundleIdentifier
                if let monitored, bundleID != monitored {
                    RateSyncLog.switching.info("[Reevaluate] \(bundleID ?? "?") is not the monitored source, preserve target metadata")
                    return
                }
                RateSyncLog.switching.info("[Reevaluate] re-evaluating switch for \(bundleID ?? "?")")
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

    private func handleTrackDidChange(_ newTrack: TrackInfo, eventDate: Date?, hasResumedFromPause: Bool = false) {
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
                self.appleMusicResumeRetryWorkItem?.cancel()
                self.appleMusicResumeRetryWorkItem = nil
                self.appleMusicResumeCheckAttempts = 0
                return
            } else {
                let wasNotPlaying = (self.appleMusicSampleRateState == .notPlaying)
                self.appleMusicResumeRetryWorkItem?.cancel()
                self.appleMusicResumeRetryWorkItem = nil
                self.appleMusicResumeCheckAttempts = 0
                if wasNotPlaying || hasResumedFromPause {
                    let resumedAt = eventDate ?? Date()
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
                return
            }
            let wasPaused = self.formatProbeBudget.isPaused
            if wasPaused || hasResumedFromPause {
                let resumedAt = eventDate ?? Date()
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
        self.switchLatestSampleRate(for: trackSnapshot, generation: currentTrackGeneration)
        if trackChanged && !isAppleMusicSource && newTrack.payload.isPlaying == false {
            self.formatProbeBudget.setPaused(true)
        }
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
