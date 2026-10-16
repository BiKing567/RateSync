import Foundation
import XCTest

final class SwitchingSupportTests: XCTestCase {
    func testResolvesAudioQueueProfileForKnownBundleIdentifier() {
        // Given
        let netEaseMusicBundleIdentifier = "com.netease.163music"

        // When
        let profile = PlayerProfile.profile(for: netEaseMusicBundleIdentifier)

        // Then
        XCTAssertEqual(profile?.processName, "NeteaseMusic")
        XCTAssertEqual(profile?.formatDetection, .audioQueueLogs)
    }

    func testFreshAudioQueueCandidateDoesNotWaitTwelveSecondsAfterExistingResult() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .audioQueueLog)

        XCTAssertEqual(
            policy.lockedOverride,
            policy.stability,
            accuracy: 0.001,
            "fresh AudioQueue evidence should use the short stability window even after a prior result"
        )
    }

    func testStaleAudioQueueCandidateKeepsConservativePersistenceWindow() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .staleAudioQueueLog)

        XCTAssertEqual(
            policy.lockedOverride,
            12.0,
            accuracy: 0.001,
            "stale AudioQueue evidence must not bypass the long persistence guard"
        )
    }

    func testMediaRemoteOnlyAcceptsUnverifiedFormatWithoutExpectedPID() {
        XCTAssertTrue(
            RateSwitchingPolicy.shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: nil)
        )
        XCTAssertFalse(
            RateSwitchingPolicy.shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: 42)
        )
    }

    func testAppleMusicParserPrefersDolbyAtmosFormatOverNearbyLossless44_1Log() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 106),
                message: "ACAppleLosslessDecoder.cpp:680 Input format: 2 ch, 44100 Hz, alac (0x00000001) from 16-bit source"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 107),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qlac, lossless, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 105),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qaac, sdFormatID = aac, stereo (lossy), asbdSampleRate = 48.0 kHz, is binaural, is rendering spatial audio, 16 original channels, original is Atmos"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicParserRecognizesQc3DolbyAtmosMarker() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 305),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qc+3, sdFormatID = ec+3, Dolby Atmos, asbdNumChannels = 16, asbdSampleRate = 48.0 kHz, is not rendering spatial audio, is Atmos"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicParserPrefersActiveSpatialAudioRateOverNewerLosslessLog() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 107),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qlac, lossless, asbdNumChannels = 2, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 105),
                message: "play> cm>> mediaFormatinfo '<private>' , audioCapabilities: 0x0 -> 0x8, asbdFormatID = qaac, stereo (lossy), asbdNumChannels = 2, asbdSampleRate = 48.0 kHz, is binaural, is rendering spatial audio"
            )
        ]

        let stat = CMPlayerParser.parseAppleMusicConsoleLogs(entries).first

        XCTAssertEqual(
            stat?.sampleRate,
            48_000,
            "A delayed active spatial-audio line must outrank a nearby 44.1 kHz lossless log."
        )
        XCTAssertTrue(stat?.isSpatialAudio == true)
        XCTAssertFalse(stat?.isDolbyAtmos == true, "A spatial-rendering marker alone must not be mislabeled as explicit Atmos metadata.")
    }

    func testAppleMusicParserUsesHighLevelLosslessFormatBeforeDecoderLog() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 205),
                message: "ACAppleLosslessDecoder.cpp:680 Input format: 2 ch, 44100 Hz, alac (0x00000001) from 16-bit source"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 204),
                message: "play> cm>> mediaFormatinfo '<private>' , audioCapabilities: 0x0 -> 0x4, asbdFormatID = qlac, lossless, asbdNumChannels = 2, asbdSampleRate = 48.0 kHz, is not rendering spatial audio"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertFalse(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicParserDoesNotInventBitDepthWhenHighLevelLogOmitsIt() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 405),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qlac, lossless, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            )
        ]

        let stat = CMPlayerParser.parseAppleMusicConsoleLogs(entries).first

        XCTAssertEqual(stat?.sampleRate, 44_100)
        XCTAssertNil(stat?.bitDepth, "An omitted bit depth must remain unknown, not become a 24-bit switching instruction.")
    }

    func testAudioQueueParserDoesNotInventBitDepthWithoutLPCMEvidence() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 407),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 44100 Hz, Float32, ..."
            )
        ]

        let stat = CMPlayerParser.parseAudioQueueConsoleLogs(entries).first

        XCTAssertEqual(stat?.sampleRate, 44_100)
        XCTAssertNil(stat?.bitDepth, "A sample-rate-only AudioQueue log must not become a 16-bit instruction.")
    }

    func testAudioQueueParserPreservesExplicitLPCMBitDepth() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 408),
                message: "AudioConverter from 2 ch, 44100 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to ..."
            )
        ]

        let stat = CMPlayerParser.parseAudioQueueConsoleLogs(entries).first

        XCTAssertEqual(stat?.sampleRate, 44_100)
        XCTAssertEqual(stat?.bitDepth, 24)
    }

    func testAudioQueueParserPrefersLPCMConverterSourceRateOverResampledOutput() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 409),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 44100 Hz, Float32, ..."
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 408),
                message: "AudioConverter from 2 ch, 48000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 44100 Hz, Float32"
            )
        ]

        let stat = CMPlayerParser.parseAudioQueueConsoleLogs(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000, "The 48 kHz source rate from AudioConverter must supersede the 44.1 kHz hardware output rate.")
        XCTAssertEqual(stat?.bitDepth, 24)
    }

    func testAudioQueueParserPrefersLPCM96kSourceRateOverResampled48kOutput() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 502),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 48000 Hz, Float32, ..."
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 501),
                message: "AudioConverter from 2 ch, 96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 48000 Hz, Float32"
            )
        ]

        let stat = CMPlayerParser.parseAudioQueueConsoleLogs(entries).first

        XCTAssertEqual(stat?.sampleRate, 96_000, "The 96 kHz source rate from AudioConverter must supersede the 48 kHz hardware output rate.")
        XCTAssertEqual(stat?.bitDepth, 24)
    }

    func testSampleRateOnlyCandidateCarriesNoBitDepthEvidence() {
        let stat = CMPlayerStats.sampleRateOnly(
            sampleRate: 44_100,
            date: Date(timeIntervalSince1970: 409)
        )

        XCTAssertEqual(stat.sampleRate, 44_100)
        XCTAssertNil(stat.bitDepth)
    }

    func testAppleMusicParserPreservesReportedBitDepth() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 406),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qlac, sdBitDepth = 16 bit, lossless, asbdSampleRate = 44.1 kHz"
            )
        ]

        let stat = CMPlayerParser.parseAppleMusicConsoleLogs(entries).first

        XCTAssertEqual(stat?.bitDepth, 16)
    }

    func testUnknownBitDepthCannotTriggerSameRateBitDepthReapplication() {
        XCTAssertFalse(
            RateSwitchingPolicy.shouldApplyBitDepthChange(
                isEnabled: true,
                reportedBitDepth: nil,
                currentBitDepth: 16,
                selectedBitDepth: 24
            )
        )
    }

    func testExplicitBitDepthCanTriggerBitDepthReapplication() {
        XCTAssertTrue(
            RateSwitchingPolicy.shouldApplyBitDepthChange(
                isEnabled: true,
                reportedBitDepth: 24,
                currentBitDepth: 16,
                selectedBitDepth: 24
            )
        )
    }

    func testAppleMusicHighLevelFormatUsesShortEvidenceGate() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicFormatLog)

        XCTAssertEqual(policy.boundary, 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.stability, 0.6, accuracy: 0.001)
        XCTAssertEqual(policy.lockedOverride, 2.0, accuracy: 0.001)
    }

    func testAppleMusicCurrentTrackScriptUsesStandardStabilityGate() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicCurrentTrack)

        XCTAssertEqual(policy.boundary, RateGatePolicy.standard.boundary, accuracy: 0.001)
        XCTAssertEqual(policy.stability, RateGatePolicy.standard.stability, accuracy: 0.001)
        XCTAssertEqual(policy.lockedOverride, RateGatePolicy.standard.lockedOverride, accuracy: 0.001)
    }

    func testConcurrentGateConfirmsEarlyStableCandidateAsSoonAsBoundaryWindowElapses() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let policy = RateGatePolicy.standard // boundary: 3.5, stability: 2.0

        // Candidate 96 kHz observed at t = 0.5s after track change
        let candidateSeenAt = t0.addingTimeInterval(0.5)
        let candidate = RateGateDecisionPolicy.updateCandidate(
            current: nil,
            rate: 96_000,
            generation: 1,
            now: candidateSeenAt
        )

        // At t = 2.5s (2.0s persistence reached, but boundary is 2.5s < 3.5s)
        let at2_5s = t0.addingTimeInterval(2.5)
        XCTAssertTrue(
            RateGateDecisionPolicy.isStabilitySatisfied(
                candidateFirstSeen: candidate.firstSeen,
                now: at2_5s,
                requiredPersistence: RateGateDecisionPolicy.requiredPersistence(isLocked: false, policy: policy)
            )
        )
        XCTAssertFalse(
            RateGateDecisionPolicy.isBoundarySatisfied(
                sinceTrackChange: 2.5,
                policy: policy
            )
        )
        XCTAssertFalse(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 2.5,
                candidateFirstSeen: candidate.firstSeen,
                now: at2_5s,
                policy: policy,
                isLocked: false
            )
        )

        // At t = 3.5s (boundary 3.5s reached and persistence 3.0s >= 2.0s reached)
        let at3_5s = t0.addingTimeInterval(3.5)
        XCTAssertTrue(
            RateGateDecisionPolicy.isBoundarySatisfied(
                sinceTrackChange: 3.5,
                policy: policy
            )
        )
        XCTAssertTrue(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 3.5,
                candidateFirstSeen: candidate.firstSeen,
                now: at3_5s,
                policy: policy,
                isLocked: false
            )
        )
    }

    func testConcurrentGateResetsStabilityWhenCandidateRateChangesDuringBoundaryWindow() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let policy = RateGatePolicy.standard // boundary: 3.5, stability: 2.0

        // Transient 44.1 kHz candidate observed at t = 0.5s
        var candidate = RateGateDecisionPolicy.updateCandidate(
            current: nil,
            rate: 44_100,
            generation: 1,
            now: t0.addingTimeInterval(0.5)
        )

        // At t = 2.0s, real format settles on 96 kHz
        candidate = RateGateDecisionPolicy.updateCandidate(
            current: candidate,
            rate: 96_000,
            generation: 1,
            now: t0.addingTimeInterval(2.0)
        )

        // At t = 3.5s, boundary window has elapsed (3.5s >= 3.5s), but 96 kHz only stable for 1.5s (< 2.0s)
        let at3_5s = t0.addingTimeInterval(3.5)
        XCTAssertTrue(RateGateDecisionPolicy.isBoundarySatisfied(sinceTrackChange: 3.5, policy: policy))
        XCTAssertFalse(
            RateGateDecisionPolicy.isStabilitySatisfied(
                candidateFirstSeen: candidate.firstSeen,
                now: at3_5s,
                requiredPersistence: policy.stability
            )
        )
        XCTAssertFalse(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 3.5,
                candidateFirstSeen: candidate.firstSeen,
                now: at3_5s,
                policy: policy,
                isLocked: false
            )
        )

        // At t = 4.0s, 96 kHz stability reaches 2.0s (2.0s to 4.0s) -> confirmed!
        let at4_0s = t0.addingTimeInterval(4.0)
        XCTAssertTrue(
            RateGateDecisionPolicy.isStabilitySatisfied(
                candidateFirstSeen: candidate.firstSeen,
                now: at4_0s,
                requiredPersistence: policy.stability
            )
        )
        XCTAssertTrue(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 4.0,
                candidateFirstSeen: candidate.firstSeen,
                now: at4_0s,
                policy: policy,
                isLocked: false
            )
        )
    }

    func testConcurrentGateResetsStabilityWhenPlaybackGenerationChanges() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let policy = RateGatePolicy.standard

        // Generation 1 candidate seen at t = 0s
        let gen1Candidate = RateGateDecisionPolicy.updateCandidate(
            current: nil,
            rate: 96_000,
            generation: 1,
            now: t0
        )

        // Playback resumes / new generation at t = 3.0s with same rate
        let gen2Candidate = RateGateDecisionPolicy.updateCandidate(
            current: gen1Candidate,
            rate: 96_000,
            generation: 2,
            now: t0.addingTimeInterval(3.0)
        )

        // Candidate firstSeen was reset to t = 3.0s
        XCTAssertEqual(gen2Candidate.firstSeen, t0.addingTimeInterval(3.0))
        XCTAssertFalse(
            RateGateDecisionPolicy.isStabilitySatisfied(
                candidateFirstSeen: gen2Candidate.firstSeen,
                now: t0.addingTimeInterval(3.5),
                requiredPersistence: policy.stability
            )
        )
    }

    func testConcurrentGatePreservesLockedOverrideForMidTrackChanges() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let policy = RateGatePolicy.standard // lockedOverride: 12.0

        // Boundary window has long passed (mid-song change: 30s)
        let candidate = RateGateDecisionPolicy.updateCandidate(
            current: nil,
            rate: 192_000,
            generation: 1,
            now: t0
        )

        // At 2.0s (normal stability reached, but locked requires 12.0s)
        XCTAssertFalse(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 32.0,
                candidateFirstSeen: candidate.firstSeen,
                now: t0.addingTimeInterval(2.0),
                policy: policy,
                isLocked: true
            )
        )

        // At 12.0s (locked override reached)
        XCTAssertTrue(
            RateGateDecisionPolicy.isConfirmed(
                sinceTrackChange: 42.0,
                candidateFirstSeen: candidate.firstSeen,
                now: t0.addingTimeInterval(12.0),
                policy: policy,
                isLocked: true
            )
        )
    }

    func testAppleMusicMissingScriptRateRetriesUntilSixSecondDeadline() {
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .missingValue, elapsed: 0),
            .retry(after: 0.5)
        )
        guard case .retry(let retryDelay) = AppleMusicSampleRatePolicy.resolution(
            for: .missingValue,
            elapsed: 5.8
        ) else {
            return XCTFail("A missing value before the deadline should schedule the final retry.")
        }
        XCTAssertEqual(retryDelay, 0.2, accuracy: 0.001)
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .missingValue, elapsed: 6.0),
            .fallbackToLogs
        )
    }

    func testAppleMusicScriptRateAppliesWithoutBitDepthEvidence() {
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .sampleRate(96_000), elapsed: 0),
            .apply(96_000)
        )
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .sampleRate(.nan), elapsed: 0),
            .fallbackToLogs
        )
    }

    func testAppleMusicFormatProbeRetriesAfterMissUntilSixSecondDeadline() {
        XCTAssertEqual(
            AppleMusicFormatProbePolicy.retryDelay(after: 2.0, hasPriorityEvidence: false),
            0.5
        )
        XCTAssertEqual(
            AppleMusicFormatProbePolicy.retryDelay(after: 5.8, hasPriorityEvidence: false) ?? -1,
            0.2,
            accuracy: 0.001
        )
        XCTAssertNil(AppleMusicFormatProbePolicy.retryDelay(after: 6.0, hasPriorityEvidence: false))
        XCTAssertNil(AppleMusicFormatProbePolicy.retryDelay(after: 2.0, hasPriorityEvidence: true))
    }

    func testAppleMusicValidTrackRateIsNotHeldForAtmosProbe() {
        XCTAssertEqual(
            AppleMusicCurrentTrackRatePolicy.action(
                hasCurrentTrackRate: true,
                hasPriorityEvidence: false,
                atmosProbeCompleted: false
            ),
            .applyCurrentTrackRate,
            "A valid AppleScript rate must enter the stability gate while Atmos logs continue probing."
        )
    }

    func testAppleMusicPriorityFormatWinsOverCurrentTrackRate() {
        XCTAssertEqual(
            AppleMusicCurrentTrackRatePolicy.action(
                hasCurrentTrackRate: true,
                hasPriorityEvidence: true,
                atmosProbeCompleted: false
            ),
            .applyPriorityFormat
        )
    }

    func testAppleMusicScriptUnavailableFallsBackImmediatelyAndStoppedPlaybackDoesNotUseLogs() {
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .unavailable, elapsed: 0.1),
            .fallbackToLogs
        )
        XCTAssertEqual(
            AppleMusicSampleRatePolicy.resolution(for: .notPlaying, elapsed: 0.1),
            .noPlayback
        )
    }

    func testAppleMusicNoPlaybackSchedulesAResumeCheckWhileTrackIsRetained() {
        XCTAssertEqual(
            AppleMusicPlaybackRecoveryPolicy.retryDelay(hasCurrentTrack: true),
            3.0,
            "A pause must not permanently terminate sampling for a retained Now Playing track."
        )
        XCTAssertNil(AppleMusicPlaybackRecoveryPolicy.retryDelay(hasCurrentTrack: false))
    }

    func testAppleMusicAtmosProbeCanRefreshAfterInitialGenerationCompletes() {
        let completedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            AppleMusicFormatProbePolicy.shouldSchedule(
                generation: 4,
                scheduledGeneration: nil,
                completedGeneration: 4,
                lastCompletedAt: completedAt,
                now: completedAt.addingTimeInterval(0.5)
            )
        )
        XCTAssertTrue(
            AppleMusicFormatProbePolicy.shouldSchedule(
                generation: 4,
                scheduledGeneration: nil,
                completedGeneration: 4,
                lastCompletedAt: completedAt,
                now: completedAt.addingTimeInterval(1.5)
            ),
            "A later log line must be eligible for a follow-up Atmos scan."
        )
    }

    func testAppleMusicCurrentTrackRateRetainsLosslessBitDepthEvidence() {
        let evidence = CMPlayerStats(
            sampleRate: 44_100,
            bitDepth: 16,
            date: Date(timeIntervalSince1970: 1_001),
            isAppleMusicFormat: true
        )

        XCTAssertEqual(
            AppleMusicFormatPolicy.bitDepthEvidence(
                formatEvidence: evidence,
                fallbackEvidence: nil
            ),
            16,
            "AppleScript supplies the rate, but the parsed lossless evidence still supplies bit depth."
        )
    }

    func testAppleMusicCurrentTrackRateRevalidatesAfterSettlingDelay() {
        let queriedAt = Date(timeIntervalSince1970: 2_000)

        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: queriedAt,
                now: queriedAt.addingTimeInterval(0.5)
            )
        )
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: queriedAt,
                now: queriedAt.addingTimeInterval(2.0)
            ),
            "Music may report a temporary 44.1 kHz value while a high-resolution track is loading."
        )
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(lastQueriedAt: nil, now: queriedAt)
        )
    }

    func testAppleMusicTimeoutDoesNotReplaceKnownScriptRateWithLogEvidence() {
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldPreserveCurrentTrackRateOnFallback(
                hasKnownCurrentTrackRate: true
            ),
            "A timeout during same-track revalidation must preserve the last valid AppleScript rate."
        )
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldPreserveCurrentTrackRateOnFallback(
                hasKnownCurrentTrackRate: false
            ),
            "Log fallback is allowed only when AppleScript never supplied a valid rate for this track."
        )
    }

    func testStaleAppleMusicQueryCannotFinishNewSameTrackRequest() {
        XCTAssertTrue(
            AppleMusicSampleRateQueryPolicy.isCurrent(expectedQueryID: 12, currentQueryID: 12)
        )
        XCTAssertFalse(
            AppleMusicSampleRateQueryPolicy.isCurrent(expectedQueryID: 11, currentQueryID: 12),
            "An old timeout must not end a newer AppleScript query for the same track and playback generation."
        )
    }

    func testAppleMusicCurrentTrackRateUsesDecoderBitDepthEvidence() {
        let decoderEvidence = CMPlayerStats(
            sampleRate: 96_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 1_002)
        )

        XCTAssertEqual(
            AppleMusicFormatPolicy.bitDepthEvidence(
                formatEvidence: nil,
                fallbackEvidence: nil,
                decoderEvidence: decoderEvidence
            ),
            24,
            "The AppleScript rate path must retain explicit bit depth parsed from the decoder log."
        )
    }

    func testStalePlaybackGenerationCannotApplyAfterTheSameTrackResumes() {
        XCTAssertTrue(TrackRequestPolicy.isCurrent(expectedGeneration: 7, currentGeneration: 7))
        XCTAssertFalse(TrackRequestPolicy.isCurrent(expectedGeneration: 7, currentGeneration: 8))
    }

    func testAppleMusicEvidenceWindowRetainsDelayedDolbyFormat() {
        let atmosphericDate = Date(timeIntervalSince1970: 100)
        let losslessDate = Date(timeIntervalSince1970: 107)
        let queryDate = Date(timeIntervalSince1970: 110)
        let entries = [
            AppleMusicLogEntry(
                date: atmosphericDate,
                message: "asbdFormatID = qaac, asbdSampleRate = 48.0 kHz, original is Atmos"
            ),
            AppleMusicLogEntry(
                date: losslessDate,
                message: "asbdFormatID = qlac, lossless, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            )
        ].filter { $0.date >= queryDate.addingTimeInterval(-AppleMusicFormatParser.logWindowSeconds) }

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicKnownFormatBlocksScriptFallbackAndKeepsAtmosEvidence() {
        XCTAssertFalse(AppleMusicFormatPolicy.shouldUseAppleScriptFallback(hasKnownFormat: true))
        XCTAssertTrue(AppleMusicFormatPolicy.shouldUseAppleScriptFallback(hasKnownFormat: false))
        XCTAssertFalse(
            AppleMusicFormatPolicy.shouldUseAppleScriptFallback(
                hasKnownFormat: false,
                hasAttemptedFallback: true
            )
        )
        XCTAssertFalse(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsPriorityFormat: true,
                incomingIsPriorityFormat: false
            )
        )
        XCTAssertTrue(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsPriorityFormat: false,
                incomingIsPriorityFormat: true
            )
        )
    }

    func testAppleMusicEffectiveSampleRatePrefersDecoderEvidenceOverAppleScript44k() {
        let decoderStat = CMPlayerStats(sampleRate: 96_000, bitDepth: 24, date: Date())
        let formatStat = CMPlayerStats(sampleRate: 48_000, bitDepth: 24, date: Date())

        // Decoder log (ACAppleLosslessDecoder.cpp) takes top priority
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: decoderStat,
                formatEvidence: nil
            ),
            96_000
        )

        // Media format log (asbdSampleRate) takes priority over static AppleScript template
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: formatStat
            ),
            48_000
        )

        // Fallback to script rate when no log evidence is available yet
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: nil
            ),
            44_100
        )
    }

    func testResolvesPresetRateForSpotify() {
        // Given
        let spotifyBundleIdentifier = "com.spotify.client"

        // When
        let profile = PlayerProfile.profile(for: spotifyBundleIdentifier)

        // Then
        XCTAssertEqual(profile?.fallbackSampleRate, 44_100)
    }

    func testPlayerPriorityNormalizationKeepsCustomOrderAndAddsMissingPlayers() {
        let priority = PlayerProfile.normalizedPriority([
            PlayerProfile.qqMusic.bundleIdentifier,
            PlayerProfile.qqMusic.bundleIdentifier,
            PlayerProfile.appleMusic.bundleIdentifier,
            "com.example.unknown-player"
        ])

        XCTAssertEqual(
            priority,
            [
                PlayerProfile.qqMusic.bundleIdentifier,
                PlayerProfile.appleMusic.bundleIdentifier,
                PlayerProfile.spotify.bundleIdentifier,
                PlayerProfile.neteaseMusic.bundleIdentifier
            ]
        )
    }

    func testHigherPriorityPlayerCanTakeOverImmediately() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testLowerPriorityPlayerWaitsWhileCurrentSourceIsFresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testLowerPriorityPlayerCanTakeOverAfterCurrentSourceGoesQuiet() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(PlayerTakeoverPolicy.defaultActivityWindow + 1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testActiveLowerPriorityPlayerStillWaitsWhileCurrentSourceIsFresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            PlayerTakeoverPolicy.shouldAcceptAfterActivePlayerCheck(
                activePlayerRelation: .candidate,
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            ),
            "an active lower-priority candidate must not bypass the freshness window"
        )
    }

    func testMismatchedMonitoredSourceIsIgnored() {
        XCTAssertEqual(
            MonitoredSourceDecision.decide(
                monitoredBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                incomingBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier
            ),
            .ignore,
            "an event from outside the monitored source must not clear the selected source"
        )
    }

    func testStaleReportedSourceUsesResolvedPreferredSource() {
        XCTAssertEqual(
            SourceIdentityPolicy.effectiveBundleIdentifier(
                reportedBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                resolvedBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                preferredBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier
            ),
            PlayerProfile.appleMusic.bundleIdentifier,
            "a stale MediaRemote source id must not hide the monitored process identity"
        )
    }

    func testTemporaryLockBecomesTheEffectiveMonitorSelection() {
        XCTAssertEqual(
            MenuSelectionState.effectiveSelectedIdentifier(
                selectedIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                temporaryLockIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier
            ),
            PlayerProfile.neteaseMusic.bundleIdentifier,
            "the temporary lock must be the source shown as effective in the menu"
        )
    }

    func testResolvesBundleIdentifierForKnownProcessName() {
        // Given
        let processName = "Music"

        // When
        let bundleIdentifier = PlayerProfile.bundleIdentifier(forProcessName: processName)

        // Then
        XCTAssertEqual(bundleIdentifier, "com.apple.Music")
    }

    func testMonitoringSourcesExposeTheirLocalizationKeys() {
        XCTAssertEqual(
            PlayerProfile.monitoringSources.map(\.localizationKey),
            ["Apple Music", "Spotify", "NetEase Music", "QQ Music"]
        )
    }

    func testMenuSelectionStateMarksMatchingIdentifierAsSelected() {
        XCTAssertTrue(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: "device-a"
            )
        )
        XCTAssertFalse(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: "device-b"
            )
        )
    }

    func testMenuSelectionStateMarksDefaultOptionOnlyWhenSelectionIsNil() {
        XCTAssertTrue(
            MenuSelectionState.isSelected(
                selectedIdentifier: nil,
                optionIdentifier: nil
            )
        )
        XCTAssertFalse(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: nil
            )
        )
    }

    func testCompletesOneShotCallbackOnlyOnce() {
        // Given
        var values = [Int]()
        let completion = OneShotCompletion<Int> { values.append($0) }

        // When
        completion.complete(1)
        completion.complete(2)

        // Then
        XCTAssertEqual(values, [1])
    }

    func testCompletesOneShotCallbackOnceWhenCallsRace() {
        // Given
        let callbackExpectation = expectation(description: "callback")
        let completion = OneShotCompletion<Int> { _ in callbackExpectation.fulfill() }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "OneShotCompletionTests", attributes: .concurrent)

        // When
        for value in 0..<100 {
            group.enter()
            queue.async {
                completion.complete(value)
                group.leave()
            }
        }

        // Then
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        wait(for: [callbackExpectation], timeout: 1)
    }

    func testWidgetKindKeepsExistingInstalledWidgetsCompatible() {
        XCTAssertEqual(RateSyncWidgetConfiguration.widgetKind, "RateSyncAudioFormatWidget")
    }

    func testWidgetRefreshRetriesAfterAppUpdateToOutliveStaleExtensionHost() {
        XCTAssertEqual(
            RateSyncWidgetConfiguration.launchRefreshDelays,
            [0, 5, 15]
        )
    }

    func testWidgetTimelineHasFallbackRefreshForExternalFormatChanges() {
        let start = Date(timeIntervalSince1970: 1_000)

        let refresh = RateSyncWidgetConfiguration.nextRefreshDate(after: start)

        XCTAssertEqual(
            refresh.timeIntervalSince(start),
            RateSyncWidgetConfiguration.fallbackRefreshInterval,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(RateSyncWidgetConfiguration.fallbackRefreshInterval, 0)
    }

    func testWidgetNowPlayingFallbackTextIsReadable() {
        let track = SharedNowPlayingTrack(
            title: "  ",
            artist: nil,
            artworkDataBase64: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(track.titleText, "Not Playing")
        XCTAssertEqual(track.artistText, "No Artist")
    }

    func testWidgetStateFallbackURLLivesInWidgetContainer() {
        let path = RateSyncWidgetConfiguration.localWidgetStateURL.path

        XCTAssertTrue(
            path.hasSuffix(
                "/Library/Containers/com.biking.RateSync.Widget/Data/Library/Application Support/RateSync/ratesync-widget-state.plist"
            )
        )
    }

    func testWidgetStateUsesOnlyStandaloneContainerFileBridge() {
        let paths = RateSyncWidgetConfiguration.stateStorageURLs.map(\.path)

        XCTAssertEqual(
            paths,
            [
                RateSyncWidgetConfiguration.sharedApplicationSupportStateURL.path,
                RateSyncWidgetConfiguration.localWidgetStateURL.path,
            ]
        )
        XCTAssertFalse(paths.contains { $0.contains("/Library/Group Containers/") })
    }

    func testReplayWithSameMetadataButNewNowPlayingTimestampIsNotSuppressed() {
        let first = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 1_000_000
        )
        let replay = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 2_000_000
        )

        XCTAssertFalse(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: first,
                current: replay,
                lastDeliveredAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 100.1)
            )
        )
    }

    func testRepeatedCallbackWithSameNowPlayingTimestampIsSuppressed() {
        let first = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 1_000_000
        )

        XCTAssertTrue(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: first,
                current: first,
                lastDeliveredAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 100.1)
            )
        )
    }

    func testArtworkSanitizerRejectsOversizedBase64Payload() {
        let oversizedArtwork = Data(
            repeating: 0,
            count: RateSyncWidgetConfiguration.maxArtworkDataBytes + 1
        ).base64EncodedString()

        XCTAssertNil(
            RateSyncWidgetConfiguration.sanitizedArtworkDataBase64(oversizedArtwork)
        )
    }

    func testArtworkSanitizerKeepsValidBase64Payload() {
        let artwork = Data([0x01, 0x02, 0x03]).base64EncodedString()

        XCTAssertEqual(
            RateSyncWidgetConfiguration.sanitizedArtworkDataBase64(artwork),
            artwork
        )
    }

    func testAppleMusicFallbackKeepsPollingForLaterLogEvidence() {
        XCTAssertEqual(
            AppleMusicFormatPolicy.resolution(
                hasLogEvidence: false,
                hasLogStats: false,
                hasCachedFallback: true,
                hasAttemptedFallback: true,
                isPlaying: true
            ),
            .cachedFallback
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.resolution(
                hasLogEvidence: true,
                hasLogStats: true,
                hasCachedFallback: true,
                hasAttemptedFallback: true,
                isPlaying: true
            ),
            .logEvidence
        )
    }

    func testWidgetStateMergesLatestIndependentFormatAndTrackSnapshots() {
        let older = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 16,
            formatUpdatedAt: Date(timeIntervalSince1970: 10),
            title: "Older title",
            artist: "Older artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 20)
        )
        let newerFormat = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 48_000,
            bitDepth: 24,
            formatUpdatedAt: Date(timeIntervalSince1970: 30),
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )

        let merged = RateSyncWidgetConfiguration.mergeStates([older, newerFormat])

        XCTAssertEqual(merged?.sampleRate, 48_000)
        XCTAssertEqual(merged?.bitDepth, 24)
        XCTAssertEqual(merged?.title, "Older title")
        XCTAssertEqual(merged?.artist, "Older artist")
        XCTAssertEqual(merged?.trackUpdatedAt, Date(timeIntervalSince1970: 20))
    }

    func testWidgetStateUsesFreshSharedDefaultsWhenStateFileIsStale() {
        let staleFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 48_000,
            bitDepth: 32,
            formatUpdatedAt: Date(timeIntervalSince1970: 10),
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        let freshSharedDefaultsState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 24,
            formatUpdatedAt: Date(timeIntervalSince1970: 30),
            title: "Current song",
            artist: "Current artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 31)
        )

        let merged = RateSyncWidgetConfiguration.mergePersistedStates(
            fileStates: [staleFileState],
            sharedDefaultsState: freshSharedDefaultsState
        )

        XCTAssertEqual(merged?.sampleRate, 44_100)
        XCTAssertEqual(merged?.bitDepth, 24)
        XCTAssertEqual(merged?.title, "Current song")
        XCTAssertEqual(merged?.artist, "Current artist")
        XCTAssertEqual(merged?.trackUpdatedAt, Date(timeIntervalSince1970: 31))
    }

    func testWidgetPrefersLiveOutputFormatWhenPersistedStateIsStale() {
        let persisted = SharedAudioFormat(
            sampleRate: 44_100,
            bitDepth: 16,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let live = SharedAudioFormat(
            sampleRate: 48_000,
            bitDepth: 24,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            RateSyncWidgetConfiguration.preferredAudioFormat(
                persisted: persisted,
                live: live
            ),
            live
        )
    }

    func testWidgetAudioFormatUsesPersistedStateWithoutLiveOutputProbe() {
        let persisted = SharedAudioFormat(
            sampleRate: 44_100,
            bitDepth: 32,
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            RateSyncWidgetConfiguration.widgetAudioFormat(persisted: persisted),
            persisted
        )
    }

    func testPlayerPriorityMenuTitleIncludesPlayerNameAfterOrderNumber() {
        XCTAssertEqual(
            MenuLabelPolicy.playerPriorityTitle(index: 1, localizedName: "Apple Music"),
            "1. Apple Music",
            "Player priority rows must show the player name instead of only the order number."
        )
    }

}
