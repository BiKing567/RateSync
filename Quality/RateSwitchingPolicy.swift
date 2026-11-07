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

    static func retryDelay(after elapsed: TimeInterval, hasPriorityEvidence: Bool) -> TimeInterval? {
        guard !hasPriorityEvidence, elapsed.isFinite else { return nil }
        let remaining = AppleMusicSampleRatePolicy.maximumWait - max(0, elapsed)
        guard remaining > 0 else { return nil }
        return min(AppleMusicSampleRatePolicy.retryInterval, remaining)
    }

    /// The initial probe is bounded by the six-second current-track window,
    /// but a decoder line can arrive after that probe completed. Allow a
    /// cooldown-limited follow-up scan for the same playback generation.
    static func shouldSchedule(
        generation: UInt64,
        scheduledGeneration: UInt64?,
        completedGeneration: UInt64?,
        lastCompletedAt: Date?,
        now: Date
    ) -> Bool {
        guard scheduledGeneration != generation else { return false }
        guard completedGeneration == generation else { return true }
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= refreshInterval
    }
}

enum AppleMusicPlaybackRecoveryPolicy {
    static let retryInterval: TimeInterval = 3.0

    /// A paused player can keep the same Now Playing track snapshot. Keep a
    /// low-frequency recheck alive so a later resume is not dependent on a
    /// second metadata event from MediaRemote.
    static func retryDelay(hasCurrentTrack: Bool) -> TimeInterval? {
        hasCurrentTrack ? retryInterval : nil
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
    static let recoveryProbeInterval: TimeInterval = 2.5
    static let maxRecoveryAttempts: Int = 2

    static func shouldRevalidate(lastQueriedAt: Date?, now: Date) -> Bool {
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

