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

enum RateSwitchingPolicy {
    static let maxPlausibleSampleRate: Double = 768_000
    static let maxPlausibleBitDepth: Int = 64

    static func gatePolicy(for source: RateSource) -> RateGatePolicy {
        switch source {
        case .audioQueueLog:
            return .audioQueue
        case .appleMusicFormatLog:
            return .appleMusicFormat
        case .staleAudioQueueLog, .mediaRemoteProbe, .appleMusicPriority, .decoderLog, .preset:
            return .standard
        }
    }

    static func bitDepth(reportedByMediaRemote: Int?, fallback: Int?) -> Int {
        reportedByMediaRemote ?? fallback ?? 24
    }

    static func shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: pid_t?) -> Bool {
        expectedPID == nil
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
        currentIsDolbyAtmos: Bool,
        incomingIsDolbyAtmos: Bool
    ) -> Bool {
        !currentIsDolbyAtmos || incomingIsDolbyAtmos
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
