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

enum AppleMusicCurrentTrackRatePolicy {
    /// Music can briefly expose the previous/rendering variant's rate while a
    /// high-resolution track is settling. Recheck the same track after this
    /// short cooldown instead of treating the first valid value as final.
    static let revalidationInterval: TimeInterval = 2.0

    static func shouldRevalidate(lastQueriedAt: Date?, now: Date) -> Bool {
        guard let lastQueriedAt else { return true }
        return now.timeIntervalSince(lastQueriedAt) >= revalidationInterval
    }

    static func shouldPreserveCurrentTrackRateOnFallback(
        hasKnownCurrentTrackRate: Bool
    ) -> Bool {
        hasKnownCurrentTrackRate
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
        incomingIsPriorityFormat: Bool
    ) -> Bool {
        !currentIsPriorityFormat || incomingIsPriorityFormat
    }

    /// Determines the effective sample rate for an Apple Music track.
    /// Ground-truth decoder evidence (from ACAppleLosslessDecoder.cpp) and media format
    /// logs (from asbdSampleRate) take precedence over the iTunes AppleScript database query,
    /// because AppleScript returns a static 44.1 kHz template value for cloud streaming tracks.
    static func effectiveSampleRate(
        scriptRate: Double?,
        decoderEvidence: CMPlayerStats?,
        formatEvidence: CMPlayerStats?
    ) -> Double? {
        if let decoderRate = decoderEvidence?.sampleRate, decoderRate > 0 {
            return decoderRate
        }
        if let formatRate = formatEvidence?.sampleRate, formatRate > 0 {
            return formatRate
        }
        return scriptRate
    }

    static func bitDepthEvidence(
        formatEvidence: CMPlayerStats?,
        fallbackEvidence: CMPlayerStats?,
        decoderEvidence: CMPlayerStats? = nil
    ) -> Int? {
        formatEvidence?.bitDepth ?? decoderEvidence?.bitDepth ?? fallbackEvidence?.bitDepth
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
