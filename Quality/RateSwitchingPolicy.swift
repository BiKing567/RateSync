//
//  RateSwitchingPolicy.swift
//  RateSync
//

import CoreAudioTypes
import Foundation

/// The source of a candidate format determines how much evidence is needed
/// before changing the output device.
enum RateSource {
    case mediaRemoteProbe
    case appleMusicPriority
    case appleMusicCurrentTrack
    case appleMusicFormatLog
    case decoderLog
    case audioQueueLog
    case staleAudioQueueLog
    case preset
}

struct RateGatePolicy {
    let boundary: TimeInterval
    let stability: TimeInterval
    let lockedOverride: TimeInterval

    static let standard = RateGatePolicy(boundary: 3.5, stability: 2.0, lockedOverride: 12.0)
    static let appleMusicFormat = RateGatePolicy(boundary: 1.0, stability: 0.6, lockedOverride: 2.0)
    static let audioQueue = RateGatePolicy(boundary: 0, stability: 0.6, lockedOverride: 0.6)
}

enum RateGateDecisionPolicy {
    struct CandidateTracking: Equatable {
        var rate: Float64
        var generation: UInt64
        var firstSeen: Date
    }

    static func updateCandidate(
        current: CandidateTracking?,
        rate: Float64,
        generation: UInt64,
        now: Date
    ) -> CandidateTracking {
        if let current, current.rate == rate, current.generation == generation {
            return current
        }
        return CandidateTracking(rate: rate, generation: generation, firstSeen: now)
    }

    static func requiredPersistence(isLocked: Bool, policy: RateGatePolicy) -> TimeInterval {
        isLocked ? policy.lockedOverride : policy.stability
    }

    static func isBoundarySatisfied(sinceTrackChange: TimeInterval, policy: RateGatePolicy) -> Bool {
        sinceTrackChange >= policy.boundary
    }

    static func isStabilitySatisfied(
        candidateFirstSeen: Date?,
        now: Date,
        requiredPersistence: TimeInterval
    ) -> Bool {
        guard let candidateFirstSeen else { return false }
        return now.timeIntervalSince(candidateFirstSeen) >= requiredPersistence
    }

    static func isConfirmed(
        sinceTrackChange: TimeInterval,
        candidateFirstSeen: Date?,
        now: Date,
        policy: RateGatePolicy,
        isLocked: Bool
    ) -> Bool {
        let boundarySatisfied = isBoundarySatisfied(sinceTrackChange: sinceTrackChange, policy: policy)
        let persistence = requiredPersistence(isLocked: isLocked, policy: policy)
        let stabilitySatisfied = isStabilitySatisfied(
            candidateFirstSeen: candidateFirstSeen,
            now: now,
            requiredPersistence: persistence
        )
        return boundarySatisfied && stabilitySatisfied
    }
}

enum RateSwitchingPolicy {
    static let maxPlausibleSampleRate: Double = 768_000
    static let maxPlausibleBitDepth: Int = 64

    static func gatePolicy(for source: RateSource) -> RateGatePolicy {
        switch source {
        case .audioQueueLog:
            return .audioQueue
        case .appleMusicFormatLog:
            return .appleMusicFormat
        case .staleAudioQueueLog, .mediaRemoteProbe, .appleMusicPriority, .appleMusicCurrentTrack, .decoderLog, .preset:
            return .standard
        }
    }

    static func shouldApplyBitDepthChange(
        isEnabled: Bool,
        reportedBitDepth: Int?,
        currentBitDepth: Int?,
        selectedBitDepth: Int
    ) -> Bool {
        isEnabled && reportedBitDepth != nil && currentBitDepth != selectedBitDepth
    }

    static func shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: pid_t?) -> Bool {
        expectedPID == nil
    }
}

/// Validates and merges independent sample-rate and bit-depth signals for
/// non-Apple-Music players (such as Spotify's 44.1 kHz preset paired with
/// per-track bit-depth detection).
enum TrackFormatResolutionPolicy {
    struct BitDepthEvidence: Equatable {
        enum Source: Int, Comparable, Equatable {
            case sourceFormatLog = 1
            case mediaRemoteReport = 2

            static func < (lhs: Source, rhs: Source) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        let bitDepth: Int
        let source: Source
        let date: Date
    }

    struct NonAppleMusicResolution {
        let stats: [CMPlayerStats]
        let source: RateSource
        let resolvedBitDepthEvidence: BitDepthEvidence?

        var resolvedBitDepth: Int? {
            resolvedBitDepthEvidence?.bitDepth
        }
    }

    static func validSampleRate(_ sampleRate: Double?) -> Double? {
        guard let sampleRate,
              sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
            return nil
        }
        return sampleRate
    }

    static func validBitDepth(_ bitDepth: Int?) -> Int? {
        guard let bitDepth,
              bitDepth > 0,
              bitDepth <= RateSwitchingPolicy.maxPlausibleBitDepth else {
            return nil
        }
        return bitDepth
    }

    static func shouldPreferBitDepthEvidence(
        _ candidate: BitDepthEvidence,
        over existing: BitDepthEvidence?
    ) -> Bool {
        guard let existing else { return true }
        if candidate.source != existing.source {
            return candidate.source > existing.source
        }
        return candidate.date >= existing.date
    }

    static func resolveNonAppleMusic(
        mediaRemoteSampleRate: Double?,
        mediaRemoteBitDepth: Int?,
        logStats: [CMPlayerStats],
        cachedSampleRate: Double? = nil,
        cachedBitDepthEvidence: BitDepthEvidence? = nil,
        presetSampleRate: Double?,
        audioQueueSource: RateSource,
        defaultLogSource: RateSource,
        enableBitDepthDetection: Bool = true,
        now: Date = Date()
    ) -> NonAppleMusicResolution {
        let probeRate = validSampleRate(mediaRemoteSampleRate) ?? validSampleRate(cachedSampleRate)
        let probeDepth = validBitDepth(mediaRemoteBitDepth)
        let probeEvidence = probeDepth.map {
            BitDepthEvidence(bitDepth: $0, source: .mediaRemoteReport, date: now)
        }
        let liveLogEvidence = logStats
            .compactMap { stat -> BitDepthEvidence? in
                guard let bitDepth = validBitDepth(stat.bitDepth) else { return nil }
                return BitDepthEvidence(bitDepth: bitDepth, source: .sourceFormatLog, date: stat.date)
            }
            .max(by: { $0.date < $1.date })

        var bestBitDepth = enableBitDepthDetection
            ? cachedBitDepthEvidence.flatMap { validBitDepth($0.bitDepth) != nil ? $0 : nil }
            : nil
        if let liveLogEvidence, shouldPreferBitDepthEvidence(liveLogEvidence, over: bestBitDepth) {
            bestBitDepth = liveLogEvidence
        }
        if let probeEvidence, shouldPreferBitDepthEvidence(probeEvidence, over: bestBitDepth) {
            bestBitDepth = probeEvidence
        }
        let mergedBitDepth = enableBitDepthDetection ? bestBitDepth?.bitDepth : probeDepth

        if let probeRate {
            let stat = CMPlayerStats(sampleRate: probeRate, bitDepth: mergedBitDepth, date: now)
            return NonAppleMusicResolution(
                stats: [stat],
                source: .mediaRemoteProbe,
                resolvedBitDepthEvidence: bestBitDepth
            )
        }

        if let presetRate = validSampleRate(presetSampleRate) {
            let source: RateSource
            if enableBitDepthDetection, bestBitDepth?.source == .mediaRemoteReport {
                source = .mediaRemoteProbe
            } else if enableBitDepthDetection, liveLogEvidence != nil {
                source = audioQueueSource
            } else if !enableBitDepthDetection, probeDepth != nil {
                source = .mediaRemoteProbe
            } else {
                source = .preset
            }
            let stat = CMPlayerStats(sampleRate: presetRate, bitDepth: mergedBitDepth, date: now)
            return NonAppleMusicResolution(
                stats: [stat],
                source: source,
                resolvedBitDepthEvidence: bestBitDepth
            )
        }

        if let first = logStats.first,
           let logRate = validSampleRate(first.sampleRate) {
            var mergedStats = logStats
            mergedStats[0] = CMPlayerStats(
                sampleRate: logRate,
                bitDepth: mergedBitDepth,
                date: first.date,
                isAppleMusicFormat: first.isAppleMusicFormat,
                isDolbyAtmos: first.isDolbyAtmos,
                isSpatialAudio: first.isSpatialAudio,
                trackIdentifier: first.trackIdentifier
            )
            let source: RateSource = (enableBitDepthDetection && bestBitDepth?.source == .mediaRemoteReport)
                || (!enableBitDepthDetection && probeDepth != nil)
                ? .mediaRemoteProbe
                : defaultLogSource
            return NonAppleMusicResolution(
                stats: mergedStats,
                source: source,
                resolvedBitDepthEvidence: bestBitDepth
            )
        }

        return NonAppleMusicResolution(
            stats: [],
            source: defaultLogSource,
            resolvedBitDepthEvidence: bestBitDepth
        )
    }
}

/// Bounds MediaRemote and OSLog format probing per track or playback-resume
/// window so missing fields do not permanently blacklist an app across tracks,
/// while avoiding unbounded polling and OSLog queries when bit depth is unknown.
struct FormatProbeBudget: Equatable {
    static let maxMediaRemoteMissesPerWindow = 2
    static let maxLogProbesWithoutBitDepthPerWindow = 3
    static let probeCooldown: TimeInterval = 1.5

    private(set) var mediaRemoteMisses: Int = 0
    private(set) var lastMediaRemoteProbeAt: Date?
    private(set) var logProbesWithoutBitDepth: Int = 0
    private(set) var lastLogProbeAt: Date?
    private(set) var isPaused: Bool = false

    mutating func resetForNewWindow() {
        mediaRemoteMisses = 0
        lastMediaRemoteProbeAt = nil
        logProbesWithoutBitDepth = 0
        lastLogProbeAt = nil
        isPaused = false
    }

    mutating func setPaused(_ paused: Bool) {
        if paused {
            isPaused = true
        } else if isPaused {
            resetForNewWindow()
        }
    }

    func shouldProbeMediaRemote(now: Date, ignoreCooldown: Bool = false) -> Bool {
        guard !isPaused else { return false }
        guard mediaRemoteMisses < Self.maxMediaRemoteMissesPerWindow else { return false }
        if !ignoreCooldown,
           let lastMediaRemoteProbeAt,
           now.timeIntervalSince(lastMediaRemoteProbeAt) < Self.probeCooldown {
            return false
        }
        return true
    }

    mutating func recordMediaRemoteAttempt(hasSampleRate: Bool, hasBitDepth: Bool, now: Date) {
        lastMediaRemoteProbeAt = now
        if hasSampleRate || hasBitDepth {
            mediaRemoteMisses = 0
        } else {
            mediaRemoteMisses += 1
        }
    }

    func shouldProbeLogs(
        hasPresetSampleRate: Bool,
        hasMediaRemoteBitDepth: Bool,
        enableBitDepthDetection: Bool,
        now: Date,
        ignoreCooldown: Bool = false
    ) -> Bool {
        guard !isPaused else { return false }
        guard hasPresetSampleRate else {
            return true
        }
        guard enableBitDepthDetection, !hasMediaRemoteBitDepth else {
            return false
        }
        guard logProbesWithoutBitDepth < Self.maxLogProbesWithoutBitDepthPerWindow else {
            return false
        }
        if !ignoreCooldown,
           let lastLogProbeAt,
           now.timeIntervalSince(lastLogProbeAt) < Self.probeCooldown {
            return false
        }
        return true
    }

    mutating func recordLogAttempt(foundBitDepth: Bool, now: Date) {
        lastLogProbeAt = now
        if foundBitDepth {
            logProbesWithoutBitDepth = 0
        } else {
            logProbesWithoutBitDepth += 1
        }
    }
}

enum AppleMusicSampleRateQueryResult: Equatable {
    case sampleRate(Double)
    case missingValue
    case notPlaying
    case unavailable

    var logLabel: String {
        switch self {
        case .sampleRate(let sampleRate): return "sampleRate=\(sampleRate)"
        case .missingValue: return "missing value"
        case .notPlaying: return "not playing"
        case .unavailable: return "unavailable"
        }
    }
}

enum AppleMusicSampleRateResolution: Equatable {
    case apply(Double)
    case retry(after: TimeInterval)
    case fallbackToLogs
    case noPlayback
}

enum AppleMusicSampleRatePolicy {
    static let maximumWait: TimeInterval = 6.0
    static let retryInterval: TimeInterval = 0.5

    static func resolution(
        for result: AppleMusicSampleRateQueryResult,
        elapsed: TimeInterval
    ) -> AppleMusicSampleRateResolution {
        switch result {
        case .sampleRate(let rate):
            guard rate.isFinite, rate > 0, rate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
                return .fallbackToLogs
            }
            return .apply(rate)
        case .missingValue:
            let remaining = maximumWait - max(0, elapsed)
            guard remaining > 0 else { return .fallbackToLogs }
            return .retry(after: min(retryInterval, remaining))
        case .notPlaying:
            return .noPlayback
        case .unavailable:
            return .fallbackToLogs
        }
    }
}

enum AppleMusicSampleRateQueryPolicy {
    static func isCurrent(expectedQueryID: UInt64, currentQueryID: UInt64) -> Bool {
        expectedQueryID == currentQueryID
    }
}

enum AppleMusicFormatProbePolicy {
    static let refreshInterval: TimeInterval = 1.5
    static let maxProbeWindow: TimeInterval = 10.0

    static func retryDelay(after elapsed: TimeInterval, hasPriorityEvidence: Bool) -> TimeInterval? {
        guard !hasPriorityEvidence, elapsed.isFinite else { return nil }
        let remaining = AppleMusicSampleRatePolicy.maximumWait - max(0, elapsed)
        guard remaining > 0 else { return nil }
        return min(AppleMusicSampleRatePolicy.retryInterval, remaining)
    }

    /// The initial probe is bounded by the six-second current-track window,
    /// but a decoder line can arrive after that probe completed. Allow a
    /// cooldown-limited follow-up scan for the same playback generation within
    /// `maxProbeWindow`, while skipping scans when paused or inactive.
    static func shouldSchedule(
        generation: UInt64,
        scheduledGeneration: UInt64?,
        completedGeneration: UInt64?,
        lastCompletedAt: Date?,
        now: Date,
        trackStartedAt: Date? = nil,
        sampleRateState: AppleMusicSampleRateState = .waiting
    ) -> Bool {
        if sampleRateState == .notPlaying || sampleRateState == .inactive {
            return false
        }
        guard scheduledGeneration != generation else { return false }
        guard completedGeneration == generation else { return true }
        if let trackStartedAt, now.timeIntervalSince(trackStartedAt) > maxProbeWindow {
            return false
        }
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= refreshInterval
    }
}

enum AppleMusicPlaybackRecoveryPolicy {
    static let retryInterval: TimeInterval = 3.0
    static let maxResumeChecks: Int = 2

    /// A paused player can keep the same Now Playing track snapshot. Keep a
    /// bounded recheck for unlocked tracks so a quick pause/resume right after
    /// track change is caught, without polling indefinitely while paused.
    static func retryDelay(
        hasCurrentTrack: Bool,
        isTrackLocked: Bool = false,
        attempts: Int = 0
    ) -> TimeInterval? {
        guard hasCurrentTrack, !isTrackLocked, attempts < maxResumeChecks else {
            return nil
        }
        return retryInterval
    }
}

enum AppleMusicCurrentTrackRateAction: Equatable {
    case applyCurrentTrackRate
    case applyPriorityFormat
    case waitForAtmosProbe
    case fallbackToLogs
}

enum AppleMusicSampleRateState: Equatable {
    case inactive
    case waiting
    case querying
    case resolved(Double)
    case fallbackToLogs
    case notPlaying
}

enum AppleMusicCurrentTrackRatePolicy {
    /// Music can briefly expose the previous/rendering variant's rate while a
    /// high-resolution track is settling. Recheck the same track after this
    /// short cooldown instead of treating the first valid value as final.
    static let revalidationInterval: TimeInterval = 2.0
    static let maxRevalidationWindow: TimeInterval = 8.0
    static let recoveryProbeInterval: TimeInterval = 2.5
    static let maxRecoveryAttempts: Int = 2

    static func shouldRevalidate(
        lastQueriedAt: Date?,
        now: Date,
        trackStartedAt: Date? = nil,
        isTrackLocked: Bool = false
    ) -> Bool {
        if isTrackLocked,
           let trackStartedAt,
           now.timeIntervalSince(trackStartedAt) > maxRevalidationWindow {
            return false
        }
        guard let lastQueriedAt else { return true }
        return now.timeIntervalSince(lastQueriedAt) >= revalidationInterval
    }

    static func shouldPreserveCurrentTrackRateOnFallback(
        hasKnownCurrentTrackRate: Bool
    ) -> Bool {
        hasKnownCurrentTrackRate
    }

    static func shouldScheduleRecoveryProbe(
        state: AppleMusicSampleRateState,
        hasKnownCurrentTrackRate: Bool,
        attempts: Int
    ) -> Bool {
        if case .fallbackToLogs = state, !hasKnownCurrentTrackRate, attempts < maxRecoveryAttempts {
            return true
        }
        return false
    }

    static func action(
        hasCurrentTrackRate: Bool,
        hasPriorityEvidence: Bool,
        atmosProbeCompleted: Bool
    ) -> AppleMusicCurrentTrackRateAction {
        if hasPriorityEvidence { return .applyPriorityFormat }
        if hasCurrentTrackRate { return .applyCurrentTrackRate }
        return atmosProbeCompleted ? .fallbackToLogs : .waitForAtmosProbe
    }
}

enum TrackRequestPolicy {
    static func isCurrent(expectedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        expectedGeneration == currentGeneration
    }
}

enum SteadyStatePollingPolicy {
    static let settlingWindow: TimeInterval = 8.0

    struct ConfirmedDeviceMatch: Equatable {
        let deviceUID: String?
        let sampleRate: Float64
        let bitDepth: Int?
        let sourceSampleRate: Float64?

        init(
            deviceUID: String?,
            sampleRate: Float64,
            bitDepth: Int? = nil,
            sourceSampleRate: Float64? = nil
        ) {
            self.deviceUID = deviceUID
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.sourceSampleRate = sourceSampleRate
        }
    }

    /// Returns whether the active output device currently matches the format
    /// already confirmed for the current track (either via a completed switch
    /// in `lockedSampleRate` or an equal-rate confirmation in `confirmedMatch`).
    static func isDeviceMatched(
        lockedSampleRate: Float64?,
        lockedBitDepth: Int? = nil,
        lockedDeviceUID: String? = nil,
        confirmedMatch: ConfirmedDeviceMatch? = nil,
        currentDeviceUID: String?,
        currentDeviceSampleRate: Float64?,
        currentDeviceBitDepth: Int? = nil,
        enableBitDepthDetection: Bool = false
    ) -> Bool {
        let expectedSampleRate: Float64
        let expectedBitDepth: Int?
        let expectedDeviceUID: String?

        if let confirmedMatch {
            expectedSampleRate = confirmedMatch.sampleRate
            expectedBitDepth = confirmedMatch.bitDepth
            expectedDeviceUID = confirmedMatch.deviceUID
        } else if let lockedSampleRate {
            expectedSampleRate = lockedSampleRate
            expectedBitDepth = lockedBitDepth
            expectedDeviceUID = lockedDeviceUID
        } else {
            return false
        }

        if let expectedDeviceUID, let currentDeviceUID, expectedDeviceUID != currentDeviceUID {
            return false
        } else if expectedDeviceUID != nil && currentDeviceUID == nil {
            return false
        }

        guard let currentDeviceSampleRate,
              currentDeviceSampleRate == expectedSampleRate else {
            return false
        }

        if enableBitDepthDetection,
           let expectedBitDepth,
           let currentDeviceBitDepth,
           currentDeviceBitDepth != expectedBitDepth {
            return false
        }

        return true
    }

    /// Determines whether the periodic safety-net poll (`startPolling`) needs to run
    /// the full detection pipeline for the current track.
    ///
    /// - When Apple Music is paused (`.notPlaying`), periodic polling is skipped so
    ///   AppleScript and OSLogStore are not repeatedly queried while paused.
    /// - Once the current track has a confirmed device match on the active output device,
    ///   no pending candidate is waiting for confirmation, and the initial settling window
    ///   has elapsed, periodic polling skips in O(1) without querying AppleScript or OSLogStore.
    static func shouldPollTrack(
        hasCurrentTrack: Bool,
        isTrackLocked: Bool,
        isDeviceMatched: Bool? = nil,
        hasPendingCandidate: Bool,
        appleMusicState: AppleMusicSampleRateState,
        trackStartedAt: Date?,
        now: Date,
        isPlaybackPaused: Bool = false
    ) -> Bool {
        guard hasCurrentTrack else { return false }
        if isPlaybackPaused || appleMusicState == .notPlaying {
            return false
        }
        let settledOnDevice = isDeviceMatched ?? isTrackLocked
        if settledOnDevice && !hasPendingCandidate {
            if let trackStartedAt {
                return now.timeIntervalSince(trackStartedAt) <= settlingWindow
            }
            return false
        }
        return true
    }
}

/// Coalesces rapid or backlogged track-change and clear events into a single slot
/// while preserving causal ordering between `enqueue(_:)` and `enqueueClear()`.
///
/// When the serial switching queue is busy (e.g. during an `OSLogStore` scan),
/// newly arriving `TrackInfo` events (each carrying ~1–4 MiB of artwork) overwrite
/// `pending` under a lock and immediately release the superseded event instead of
/// accumulating N separate closures in the GCD queue.
final class PendingTrackEventCoalescer<Event> {
    enum Action {
        case event(Event)
        case clear
        case clearThenEvent(Event)
        case resetArbitration
        case resetArbitrationThenEvent(Event)

        var event: Event? {
            switch self {
            case .event(let event), .clearThenEvent(let event), .resetArbitrationThenEvent(let event):
                return event
            case .clear, .resetArbitration:
                return nil
            }
        }

        var includesClear: Bool {
            switch self {
            case .clear, .clearThenEvent:
                return true
            case .event, .resetArbitration, .resetArbitrationThenEvent:
                return false
            }
        }

        var includesResetArbitration: Bool {
            switch self {
            case .resetArbitration, .resetArbitrationThenEvent:
                return true
            case .event, .clear, .clearThenEvent:
                return false
            }
        }
    }

    private let lock = NSLock()
    private var pending: Action?
    private var isDrainScheduled = false

    /// Stores only the latest event, immediately releasing any superseded event.
    /// Preserves causal ordering if a clear occurred prior to this event while queued.
    /// When `shouldOverwrite` is provided and an existing event is pending, calls it under the lock;
    /// if it returns `false`, the new event is rejected without overwriting.
    /// When `merge` is provided and an existing event is pending, it merges existing state into the new event.
    /// Returns `true` if the caller should schedule a drain block on the target queue.
    func enqueue(
        _ event: Event,
        shouldOverwrite: ((Event, Event) -> Bool)? = nil,
        merge: ((Event, Event) -> Event)? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let existing = pending?.event {
            if let shouldOverwrite, !shouldOverwrite(existing, event) {
                return false
            }
            let merged = merge?(existing, event) ?? event
            switch pending {
            case .event:
                pending = .event(merged)
            case .clearThenEvent:
                pending = .clearThenEvent(merged)
            case .resetArbitrationThenEvent:
                pending = .resetArbitrationThenEvent(merged)
            default:
                pending = .event(merged)
            }
        } else {
            switch pending {
            case nil, .event:
                pending = .event(event)
            case .clear, .clearThenEvent:
                pending = .clearThenEvent(event)
            case .resetArbitration, .resetArbitrationThenEvent:
                pending = .resetArbitrationThenEvent(event)
            }
        }
        if isDrainScheduled {
            return false
        }
        isDrainScheduled = true
        return true
    }

    /// Enqueues a clear action, immediately releasing any pending event that arrived before it.
    /// Returns `true` if the caller should schedule a drain block on the target queue.
    @discardableResult
    func enqueueClear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = .clear
        if isDrainScheduled {
            return false
        }
        isDrainScheduled = true
        return true
    }

    /// Enqueues a reset of player arbitration state without clearing the now-playing track on output devices.
    /// If an event is pending, preserves it so it is processed under the fresh arbitration state.
    /// Returns `true` if the caller should schedule a drain block on the target queue.
    @discardableResult
    func enqueueResetArbitration() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch pending {
        case nil:
            pending = .resetArbitration
        case .event(let event):
            pending = .resetArbitrationThenEvent(event)
        case .clear, .clearThenEvent:
            // Explicit clear already resets arbitration and clears the track
            break
        case .resetArbitration, .resetArbitrationThenEvent:
            break
        }
        if isDrainScheduled {
            return false
        }
        isDrainScheduled = true
        return true
    }

    /// Atomically pops the next coalesced action (including whether a clear preceded the latest event).
    /// Keeps `isDrainScheduled = true` while items remain so incoming events coalesce into the active drain loop;
    /// resets `isDrainScheduled = false` only when the queue is drained and returns `nil`.
    func takeNextAction() -> Action? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = pending else {
            isDrainScheduled = false
            return nil
        }
        pending = nil
        return next
    }

    /// Convenience for callers/tests that only inspect the latest pending event.
    func takeNext() -> Event? {
        takeNextAction()?.event
    }

    func clear() {
        _ = enqueueClear()
    }
}

enum PlayerTakeoverPolicy {
    static let defaultActivityWindow: TimeInterval = 15

    enum ActivePlayerRelation {
        case candidate
        case current
        case unknown
    }

    static func priorityIndex(
        for bundleIdentifier: String?,
        priority: [String]
    ) -> Int {
        guard let bundleIdentifier,
              let index = priority.firstIndex(of: bundleIdentifier) else {
            return priority.count
        }
        return index
    }

    /// Determines whether a newly observed source may replace the current
    /// source when the user selected automatic monitoring. A higher-priority
    /// source may take over immediately; a lower-priority source must wait
    /// until the current source has gone quiet long enough.
    static func shouldAccept(
        candidateBundleIdentifier: String?,
        currentBundleIdentifier: String?,
        currentLastSeenAt: Date?,
        now: Date,
        priority: [String],
        activityWindow: TimeInterval = defaultActivityWindow
    ) -> Bool {
        guard candidateBundleIdentifier != currentBundleIdentifier else { return true }
        guard currentBundleIdentifier != nil else { return true }

        let candidateIndex = priorityIndex(for: candidateBundleIdentifier, priority: priority)
        let currentIndex = priorityIndex(for: currentBundleIdentifier, priority: priority)
        if candidateIndex < currentIndex {
            return true
        }

        guard let currentLastSeenAt else { return true }
        return now.timeIntervalSince(currentLastSeenAt) > activityWindow
    }

    static func shouldAcceptAfterActivePlayerCheck(
        activePlayerRelation: ActivePlayerRelation,
        candidateBundleIdentifier: String?,
        currentBundleIdentifier: String?,
        currentLastSeenAt: Date?,
        now: Date,
        priority: [String],
        activityWindow: TimeInterval = defaultActivityWindow
    ) -> Bool {
        switch activePlayerRelation {
        case .candidate:
            return shouldAccept(
                candidateBundleIdentifier: candidateBundleIdentifier,
                currentBundleIdentifier: currentBundleIdentifier,
                currentLastSeenAt: currentLastSeenAt,
                now: now,
                priority: priority,
                activityWindow: activityWindow
            )
        case .current:
            return false
        case .unknown:
            return shouldAccept(
                candidateBundleIdentifier: candidateBundleIdentifier,
                currentBundleIdentifier: currentBundleIdentifier,
                currentLastSeenAt: currentLastSeenAt,
                now: now,
                priority: priority,
                activityWindow: activityWindow
            )
        }
    }
}

enum MenuSelectionState {
    static func effectiveSelectedIdentifier(
        selectedIdentifier: String?,
        temporaryLockIdentifier: String?
    ) -> String? {
        temporaryLockIdentifier ?? selectedIdentifier
    }

    static func isSelected(
        selectedIdentifier: String?,
        optionIdentifier: String?
    ) -> Bool {
        selectedIdentifier == optionIdentifier
    }
}

enum MonitoredSourceDecision: Equatable {
    case deliver
    case ignore

    static func decide(
        monitoredBundleIdentifier: String?,
        incomingBundleIdentifier: String?
    ) -> Self {
        guard let monitoredBundleIdentifier else { return .deliver }
        return incomingBundleIdentifier == monitoredBundleIdentifier ? .deliver : .ignore
    }
}

enum SourceIdentityPolicy {
    static func effectiveBundleIdentifier(
        reportedBundleIdentifier: String?,
        resolvedBundleIdentifier: String?,
        preferredBundleIdentifier: String?
    ) -> String? {
        if let preferredBundleIdentifier,
           reportedBundleIdentifier != preferredBundleIdentifier,
           resolvedBundleIdentifier == preferredBundleIdentifier {
            return resolvedBundleIdentifier
        }
        return reportedBundleIdentifier ?? resolvedBundleIdentifier
    }
}

enum MenuLabelPolicy {
    static func playerPriorityTitle(index: Int, localizedName: String) -> String {
        "\(index). \(localizedName)"
    }
}

enum AppleMusicPriorityPolicy {
    static func shouldPrioritize(
        monitoredBundleIdentifier: String?,
        sourceBundleIdentifier: String?,
        priority: [String] = PlayerProfile.defaultPriorityBundleIdentifiers,
        temporarySourceLockBundleIdentifier: String? = nil
    ) -> Bool {
        monitoredBundleIdentifier == nil
            && temporarySourceLockBundleIdentifier == nil
            && sourceBundleIdentifier != PlayerProfile.appleMusic.bundleIdentifier
            && priority.first == PlayerProfile.appleMusic.bundleIdentifier
    }
}

enum AppleMusicFormatPolicy {
    enum Resolution: Equatable {
        case logEvidence
        case cachedFallback
        case requestAppleScript
        case noFormat
    }

    static func shouldUseAppleScriptFallback(
        hasKnownFormat: Bool,
        hasAttemptedFallback: Bool = false
    ) -> Bool {
        !hasKnownFormat && !hasAttemptedFallback
    }

    static func resolution(
        hasLogEvidence: Bool,
        hasLogStats: Bool,
        hasCachedFallback: Bool,
        hasAttemptedFallback: Bool,
        isPlaying: Bool
    ) -> Resolution {
        if hasLogEvidence {
            return .logEvidence
        }
        if hasCachedFallback {
            return .cachedFallback
        }
        if !hasLogStats, isPlaying, !hasAttemptedFallback {
            return .requestAppleScript
        }
        return .noFormat
    }

    static func shouldReplaceCachedFormat(
        currentIsPriorityFormat: Bool,
        incomingIsPriorityFormat: Bool,
        currentIsAttributedToTrack: Bool = true,
        incomingIsNewer: Bool = false
    ) -> Bool {
        if incomingIsPriorityFormat {
            return true
        }
        if !currentIsPriorityFormat {
            return true
        }
        return !currentIsAttributedToTrack && incomingIsNewer
    }

    /// Priority format evidence (Dolby Atmos / Spatial Audio) may only bypass AppleScript or
    /// override a confirmed current-track sample rate when it is fresh for the current track
    /// AND explicitly attributed to the current playback track.
    static func canOverrideConfirmedTrackRate(
        formatEvidence: CMPlayerStats?,
        expectedTrackID: String? = nil,
        expectedTrackTitle: String? = nil,
        trackStartedAt: Date?,
        isAttributedToCurrentTrack: Bool = false
    ) -> Bool {
        guard let formatEvidence, formatEvidence.isPriorityAppleMusicFormat else {
            return false
        }
        if let trackStartedAt, formatEvidence.date < trackStartedAt {
            return false
        }
        return isAttributedToCurrentTrack
            || formatEvidence.isAttributed(trackID: expectedTrackID, title: expectedTrackTitle)
    }

    /// Filters parsed Apple Music console logs for fallback resolution.
    ///
    /// - Explicitly mismatched logs (carrying a non-private identifier for another track) are always rejected.
    /// - Unattributed high-level format logs (`isAppleMusicFormat` with no identifier or `<private>`) must not
    ///   predate `trackStartedAt`, preventing stale Atmos/format logs from a previous track's tail from entering.
    /// - Decoder logs (`!isAppleMusicFormat`) and explicitly matched format logs may use `toleranceThreshold`
    ///   (`lastTrackChangeDate`, slightly before the MediaRemote notification arrival time) because
    ///   a new track often begins decoding slightly before the track-change notification arrives.
    static func filterFallbackLogs(
        _ rawStats: [CMPlayerStats],
        expectedTrackID: String? = nil,
        expectedTrackTitle: String? = nil,
        trackStartedAt: Date?,
        toleranceThreshold: Date?
    ) -> [CMPlayerStats] {
        rawStats.filter { stat in
            switch stat.attribution(trackID: expectedTrackID, title: expectedTrackTitle) {
            case .mismatched:
                return false
            case .matched:
                if let toleranceThreshold {
                    return stat.date >= toleranceThreshold
                }
                if let trackStartedAt {
                    return stat.date >= trackStartedAt
                }
                return true
            case .unattributed:
                if stat.isAppleMusicFormat, let trackStartedAt {
                    return stat.date >= trackStartedAt
                }
                if let toleranceThreshold {
                    return stat.date >= toleranceThreshold
                }
                if let trackStartedAt {
                    return stat.date >= trackStartedAt
                }
                return true
            }
        }
    }

    /// Determines the effective sample rate for an Apple Music track.
    ///
    /// Confirmed current-track queries from AppleScript take precedence over unattributed log evidence.
    /// Priority format logs (Dolby Atmos / Spatial Audio) may only override a confirmed `scriptRate`
    /// when they are both fresh and attributed to the current track.
    ///
    /// Freshness & provenance validation:
    /// - Attributed priority format evidence (Dolby Atmos / Spatial Audio) dictates the spatial rendering rate.
    /// - Confirmed AppleScript current-track query rate takes precedence over unattributed Atmos or decoder logs.
    /// - Evidence carrying a known mismatched track identifier is always excluded.
    /// - When the current-track query is unavailable (nil or non-positive), fallback to fresh log evidence:
    ///   - If both formatEvidence and decoderEvidence are valid for the current window, the newer one takes precedence.
    ///   - Decoder evidence may use `decoderToleranceThreshold` (`lastTrackChangeDate`) when provided so
    ///     pre-notification decoding of the new track is not lost.
    static func effectiveSampleRate(
        scriptRate: Double?,
        decoderEvidence: CMPlayerStats?,
        formatEvidence: CMPlayerStats?,
        trackStartedAt: Date? = nil,
        expectedTrackID: String? = nil,
        expectedTrackTitle: String? = nil,
        isFormatAttributedToCurrentTrack: Bool = false,
        decoderToleranceThreshold: Date? = nil
    ) -> Double? {
        let validScriptRate: Double? = {
            guard let rate = scriptRate,
                  rate.isFinite,
                  rate > 0,
                  rate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
                return nil
            }
            return rate
        }()
        let validDecoderRate: Double? = {
            guard let decoderEvidence,
                  !decoderEvidence.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle),
                  let rate = Optional(decoderEvidence.sampleRate),
                  rate.isFinite,
                  rate > 0,
                  rate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
                return nil
            }
            return rate
        }()
        let validFormatRate: Double? = {
            guard let formatEvidence,
                  !formatEvidence.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle),
                  let rate = Optional(formatEvidence.sampleRate),
                  rate.isFinite,
                  rate > 0,
                  rate <= RateSwitchingPolicy.maxPlausibleSampleRate else {
                return nil
            }
            return rate
        }()

        let isAttributedFormat = isFormatAttributedToCurrentTrack
            || (formatEvidence?.isAttributed(trackID: expectedTrackID, title: expectedTrackTitle) == true)

        let isStalePreTrackFormat: Bool = {
            if isAttributedFormat { return false }
            guard let trackStartedAt = trackStartedAt, let formatEvidence = formatEvidence else { return false }
            return formatEvidence.date < trackStartedAt
        }()

        // 1. Fresh priority formats (Dolby Atmos / Spatial Audio) attributed to the current track take precedence.
        if canOverrideConfirmedTrackRate(
            formatEvidence: formatEvidence,
            expectedTrackID: expectedTrackID,
            expectedTrackTitle: expectedTrackTitle,
            trackStartedAt: trackStartedAt,
            isAttributedToCurrentTrack: isFormatAttributedToCurrentTrack
        ), let formatRate = validFormatRate {
            return formatRate
        }

        // 2. Confirmed current-track query takes precedence over unattributed logs or stale pre-track logs.
        if let scriptRate = validScriptRate {
            return scriptRate
        }

        // 3. Fallback when current-track query is unavailable.
        let decoderBoundary = decoderToleranceThreshold ?? trackStartedAt
        let isStalePreTrackDecoder: Bool = {
            guard let decoderBoundary, let decoderEvidence else { return false }
            return decoderEvidence.date < decoderBoundary
        }()

        if let formatRate = validFormatRate,
           let formatEvidence = formatEvidence,
           !isStalePreTrackFormat {
            if let decoderRate = validDecoderRate,
               let decoderEvidence = decoderEvidence,
               !isStalePreTrackDecoder {
                return formatEvidence.date >= decoderEvidence.date ? formatRate : decoderRate
            }
            return formatRate
        }

        if let decoderRate = validDecoderRate,
           !isStalePreTrackDecoder {
            return decoderRate
        }

        return nil
    }

    /// Selects the preferred log evidence and its `RateSource` during Apple Music log fallback.
    ///
    /// - Explicitly mismatched logs (`.mismatched`) are always rejected.
    /// - Unattributed format logs predating `trackStartedAt` are rejected.
    /// - Explicitly matched evidence takes precedence over unattributed evidence; otherwise the newer log wins.
    static func preferredFallbackEvidence(
        formatEvidence: CMPlayerStats?,
        decoderEvidence: CMPlayerStats?,
        expectedTrackID: String? = nil,
        expectedTrackTitle: String? = nil,
        trackStartedAt: Date? = nil,
        decoderToleranceThreshold: Date? = nil
    ) -> (stat: CMPlayerStats, source: RateSource)? {
        let validFormat: CMPlayerStats? = {
            guard let formatEvidence else { return nil }
            switch formatEvidence.attribution(trackID: expectedTrackID, title: expectedTrackTitle) {
            case .mismatched:
                return nil
            case .matched:
                if let boundary = decoderToleranceThreshold ?? trackStartedAt, formatEvidence.date < boundary {
                    return nil
                }
                return formatEvidence
            case .unattributed:
                if let trackStartedAt, formatEvidence.date < trackStartedAt {
                    return nil
                }
                return formatEvidence
            }
        }()

        let validDecoder: CMPlayerStats? = {
            guard let decoderEvidence else { return nil }
            guard !decoderEvidence.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle) else {
                return nil
            }
            if let boundary = decoderToleranceThreshold ?? trackStartedAt, decoderEvidence.date < boundary {
                return nil
            }
            return decoderEvidence
        }()

        if let validFormat, let validDecoder {
            let formatMatched = validFormat.isAttributed(trackID: expectedTrackID, title: expectedTrackTitle)
            let decoderMatched = validDecoder.isAttributed(trackID: expectedTrackID, title: expectedTrackTitle)
            if formatMatched && !decoderMatched {
                return (validFormat, .appleMusicFormatLog)
            }
            if decoderMatched && !formatMatched {
                return (validDecoder, .decoderLog)
            }
            if validDecoder.date > validFormat.date {
                return (validDecoder, .decoderLog)
            }
            return (validFormat, .appleMusicFormatLog)
        }

        if let validFormat {
            return (validFormat, .appleMusicFormatLog)
        }
        if let validDecoder {
            return (validDecoder, .decoderLog)
        }
        return nil
    }

    static func bitDepthEvidence(
        formatEvidence: CMPlayerStats?,
        fallbackEvidence: CMPlayerStats?,
        decoderEvidence: CMPlayerStats? = nil,
        expectedTrackID: String? = nil,
        expectedTrackTitle: String? = nil
    ) -> Int? {
        let validFormat = formatEvidence.flatMap {
            $0.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle) ? nil : $0
        }
        let validDecoder = decoderEvidence.flatMap {
            $0.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle) ? nil : $0
        }
        let validFallback = fallbackEvidence.flatMap {
            $0.isMismatched(trackID: expectedTrackID, title: expectedTrackTitle) ? nil : $0
        }
        return validFormat?.bitDepth ?? validDecoder?.bitDepth ?? validFallback?.bitDepth
    }
}

/// Selects the device format closest to the format reported by the player.
/// This is deliberately stateless so the matching policy can be tested apart
/// from CoreAudio and the event-driven switching pipeline.
enum AudioFormatSelector {
    static func nearestFormat(
        sampleRate: Float64,
        bitDepth: Int32,
        supportedSampleRates: [Float64],
        formats: [AudioStreamBasicDescription],
        preferSampleRateMultiples: Bool
    ) -> AudioStreamBasicDescription? {
        guard let closestRate = supportedSampleRates.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
        }) else {
            return nil
        }

        var targetRate = closestRate
        if preferSampleRateMultiples,
           closestRate != sampleRate,
           supportedSampleRates.contains(sampleRate / 2) {
            targetRate = sampleRate / 2
        }

        let formatsAtTargetRate = formats.filter { $0.mSampleRate == targetRate }
        let closestBitDepth = formatsAtTargetRate.min(by: {
            let lhsDistance = abs(Int32($0.mBitsPerChannel) - bitDepth)
            let rhsDistance = abs(Int32($1.mBitsPerChannel) - bitDepth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return $0.mBitsPerChannel < $1.mBitsPerChannel
        })?.mBitsPerChannel

        guard let closestBitDepth else { return nil }
        return formatsAtTargetRate.first {
            $0.mSampleRate == targetRate && $0.mBitsPerChannel == closestBitDepth
        }
    }
}

/// Manages cache key generation, TTL validation, and eviction for parsed log statistics.
enum LogStatsCachePolicy {
    static let defaultTTL: TimeInterval = 0.8
    static let maxEntries: Int = 16

    /// Generates the cache key for AudioQueue log statistics.
    /// Incorporates the current track generation and the filtering `since` boundary
    /// so different tracks or different filter thresholds never collide or share entries.
    static func audioQueueCacheKey(
        process: String,
        generation: UInt64,
        since: Date?
    ) -> String {
        let sinceKey = since.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "all"
        return "aq:\(process):\(generation):\(sinceKey)"
    }

    /// Generates the cache key for Apple Music log statistics.
    static func appleMusicCacheKey(process: String) -> String {
        return "am:\(process)"
    }

    /// Prunes expired entries, drops entries belonging to old playback generations,
    /// and ensures the cache does not exceed its maximum capacity.
    static func prune(
        _ cache: inout [String: (stats: [CMPlayerStats], at: Date)],
        currentGeneration: UInt64,
        now: Date = Date(),
        ttl: TimeInterval = defaultTTL,
        maxEntries: Int = maxEntries
    ) {
        let currentGenPrefix = ":\(currentGeneration):"
        cache = cache.filter { key, value in
            guard now.timeIntervalSince(value.at) < ttl else { return false }
            if key.hasPrefix("aq:") {
                return key.contains(currentGenPrefix)
            }
            return true
        }
        if cache.count > maxEntries {
            cache.removeAll()
        }
    }
}

enum DeviceFormatVerification {
    /// Evaluates whether a requested sample rate was successfully applied.
    ///
    /// Driver nominal sample rate must be reported, must indicate success,
    /// and must match the target within nominal tolerance (< 1.0 Hz).
    /// Measured clock rate (`actualSampleRate`) is intentionally not used because
    /// crystal oscillator jitter (e.g. 47999.8 Hz) would falsely register as failure.
    static func isSampleRateApplied(
        targetRate: Float64,
        nominalRate: Float64?,
        rateSetOk: Bool
    ) -> Bool {
        guard rateSetOk, let nominalRate = nominalRate else { return false }
        return abs(nominalRate - targetRate) < 1.0
    }

    /// Evaluates whether a requested physical stream format (sample rate + bit depth)
    /// was successfully applied to the device stream.
    ///
    /// Requires readback of the stream's physical format. Both sample rate and
    /// bit depth must match the target format. If driver nominal rate is also available,
    /// it must also match within tolerance.
    static func isPhysicalFormatApplied(
        targetRate: Float64,
        targetBitDepth: UInt32,
        streamPhysicalFormat: AudioStreamBasicDescription?,
        nominalRate: Float64?
    ) -> Bool {
        guard let streamPhysicalFormat = streamPhysicalFormat else {
            return false
        }
        let streamRateMatches = abs(streamPhysicalFormat.mSampleRate - targetRate) < 1.0
        let bitDepthMatches = streamPhysicalFormat.mBitsPerChannel == targetBitDepth
        guard streamRateMatches && bitDepthMatches else {
            return false
        }
        if let nominalRate = nominalRate, abs(nominalRate - targetRate) >= 1.0 {
            return false
        }
        return true
    }

    struct FallbackFormatState: Equatable {
        let sampleRate: Float64?
        let bitDepth: Int?

        var hasConfirmedSampleRate: Bool {
            sampleRate != nil
        }
    }

    /// Resolves the fallback state to record when applying a format to an audio device fails.
    ///
    /// Never falls back to the rejected target rate: if the device's current format cannot be
    /// read back and there is no previously confirmed sample rate, `sampleRate` remains `nil`
    /// (unconfirmed) so subsequent polling will retry applying the target format.
    static func fallbackStateOnFailure(
        nominalRate: Float64?,
        streamPhysicalFormat: AudioStreamBasicDescription?,
        currentOutputBitDepth: Int?,
        previousSampleRate: Float64?,
        previousBitDepth: Int?
    ) -> FallbackFormatState {
        let validNominal = nominalRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validStreamRate = streamPhysicalFormat.map(\.mSampleRate).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validPreviousRate = previousSampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let fallbackRate = validNominal ?? validStreamRate ?? validPreviousRate

        let validStreamDepth = streamPhysicalFormat.map { Int($0.mBitsPerChannel) }.flatMap { $0 > 0 ? $0 : nil }
        let fallbackBitDepth = validStreamDepth ?? currentOutputBitDepth ?? previousBitDepth
        return FallbackFormatState(sampleRate: fallbackRate, bitDepth: fallbackBitDepth)
    }
}

