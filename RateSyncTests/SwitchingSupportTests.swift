import CoreAudioTypes
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

    func testAudioQueueParserDoesNotSuppressNewOutputLogWhenPriorConverterIsFromPreviousTrack() {
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 1003),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 48000 Hz, Float32, ..."
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 1000),
                message: "AudioConverter from 2 ch, 96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 44100 Hz, Float32"
            )
        ]

        // 1. Without since: converter is 3 seconds older (t - 3s), so it should not suppress the output at t
        let parsed = CMPlayerParser.parseAudioQueueConsoleLogs(entries)
        let queueStat = parsed.first(where: { $0.sampleRate == 48_000 })
        XCTAssertNotNil(queueStat, "A new track output log at t must not be suppressed by a converter from t - 3s.")

        // 2. With since: filter to the new track window (since = 1001)
        let filteredStats = CMPlayerParser.parseAudioQueueConsoleLogs(entries, since: Date(timeIntervalSince1970: 1001))
        XCTAssertEqual(filteredStats.count, 1)
        XCTAssertEqual(filteredStats.first?.sampleRate, 48_000)
    }

    func testAudioQueueParserWithProductionSincePreFilterRetainsNewTrackOutputWhenOldConverterIs800msPrior() {
        // Track change occurs at t = 1000.0, production tolerance threshold is t - 0.5s = 999.5.
        // Old converter was emitted at t - 0.8s = 999.2 (belongs to previous track, target 48 kHz).
        // New track outputs 48 kHz at t = 1000.0.
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 1000.0),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 48000 Hz, Float32, ..."
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 999.2),
                message: "AudioConverter from 2 ch, 96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 48000 Hz, Float32"
            )
        ]

        let productionThreshold = Date(timeIntervalSince1970: 999.5)

        // Passing the production threshold as `since` filters out the 999.2s old converter BEFORE
        // companion suppression, so the new track's 48 kHz output at 1000.0s is preserved.
        let parsed = CMPlayerParser.parseAudioQueueConsoleLogs(entries, since: productionThreshold)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.sampleRate, 48_000)
    }

    func testAudioQueueBoundaryConsistencyBetweenNormalAndRecursionPaths() {
        // Track change occurs at t = 1000.0.
        // Old track emitted a 96 kHz -> 48 kHz converter at t = 999.2 (800ms before track event).
        // New track emitted 48 kHz AudioQueue output at t = 1000.0.
        let entries = [
            SimpleConsole(
                date: Date(timeIntervalSince1970: 1000.0),
                message: "AudioQueueObject.cpp:488 New output; format 2 ch, 48000 Hz, Float32, ..."
            ),
            SimpleConsole(
                date: Date(timeIntervalSince1970: 999.2),
                message: "AudioConverter from 2 ch, 96000 Hz, lpcm (0x00000016) 24-bit big-endian signed integer to 2 ch, 48000 Hz, Float32"
            )
        ]

        let aqBoundary = Date(timeIntervalSince1970: 999.5) // lastTrackChangeDate (t - 0.5s)

        // 1. Normal path: uses aqBoundary (999.5)
        let normalParsed = CMPlayerParser.parseAudioQueueConsoleLogs(entries, since: aqBoundary)
            .filter { $0.date >= aqBoundary }
        XCTAssertEqual(normalParsed.count, 1)
        XCTAssertEqual(normalParsed.first?.sampleRate, 48_000, "Normal path must choose 48 kHz.")

        // 2. Recursion path: must KEEP aqBoundary consistent (must NOT widen to t - 2.0s = 998.0)
        // If it were widened to 998.0, the 999.2s old converter would enter and suppress the 48 kHz output.
        let recursionParsed = CMPlayerParser.parseAudioQueueConsoleLogs(entries, since: aqBoundary)
            .filter { $0.date >= aqBoundary }
        XCTAssertEqual(recursionParsed.count, 1)
        XCTAssertEqual(recursionParsed.first?.sampleRate, 48_000, "Recursion path must also choose 48 kHz, matching normal path.")

        // 3. Contrast: if someone erroneously passed a widened threshold (998.0) to parseAudioQueueConsoleLogs:
        let widenedParsed = CMPlayerParser.parseAudioQueueConsoleLogs(entries, since: Date(timeIntervalSince1970: 998.0))
        XCTAssertEqual(widenedParsed.first?.sampleRate, 96_000, "Demonstrates that widening to 2s re-introduces the stale 96 kHz converter, confirming why AudioQueue boundary must stay consistent.")
    }

    func testLogStatsCachePolicyAudioQueueKeyDifferentiatesSinceAndGeneration() {
        let date1 = Date(timeIntervalSince1970: 1000.5)
        let date2 = Date(timeIntervalSince1970: 1001.0)

        let key1 = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 1, since: date1)
        let key2 = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 1, since: date2)
        let keyDiffGen = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 2, since: date1)
        let keyNoSince = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 1, since: nil)

        XCTAssertNotEqual(key1, key2, "Different `since` dates must yield distinct cache keys.")
        XCTAssertNotEqual(key1, keyDiffGen, "Different generations must yield distinct cache keys.")
        XCTAssertNotEqual(key1, keyNoSince, "Presence vs absence of `since` must yield distinct cache keys.")
        XCTAssertEqual(key1, "aq:NeteaseMusic:1:1000500")
        XCTAssertEqual(keyNoSince, "aq:NeteaseMusic:1:all")
    }

    func testLogStatsCachePolicyPruningEvictsStaleGenerationsAndExpiredEntries() {
        let now = Date(timeIntervalSince1970: 2000.0)
        var cache: [String: (stats: [CMPlayerStats], at: Date)] = [:]

        let stat48 = [CMPlayerStats(sampleRate: 48000, bitDepth: nil, date: now)]
        let stat96 = [CMPlayerStats(sampleRate: 96000, bitDepth: nil, date: now)]

        // Generation 1 entry (active timestamp)
        let gen1Key = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 1, since: now)
        cache[gen1Key] = (stat48, now)

        // Generation 2 active entry (active timestamp)
        let gen2Key = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 2, since: now)
        cache[gen2Key] = (stat48, now)

        // Generation 2 expired entry (timestamp 1.0s ago, TTL is 0.8s)
        let expiredDate = now.addingTimeInterval(-1.0)
        let gen2ExpiredKey = LogStatsCachePolicy.audioQueueCacheKey(process: "NeteaseMusic", generation: 2, since: expiredDate)
        cache[gen2ExpiredKey] = (stat96, expiredDate)

        // Apple Music entry (active timestamp)
        let amKey = LogStatsCachePolicy.appleMusicCacheKey(process: "Music")
        cache[amKey] = (stat48, now)

        // Prune with currentGeneration = 2
        LogStatsCachePolicy.prune(&cache, currentGeneration: 2, now: now, ttl: 0.8)

        XCTAssertNil(cache[gen1Key], "Entries from previous generations must be evicted.")
        XCTAssertNil(cache[gen2ExpiredKey], "Expired entries exceeding TTL must be evicted.")
        XCTAssertNotNil(cache[gen2Key], "Active entries for current generation must be retained.")
        XCTAssertNotNil(cache[amKey], "Active Apple Music entries must be retained.")
    }

    func testLogStatsCachePolicyPruningEnforcesMaxEntries() {
        let now = Date(timeIntervalSince1970: 2000.0)
        var cache: [String: (stats: [CMPlayerStats], at: Date)] = [:]
        let stat = [CMPlayerStats(sampleRate: 44100, bitDepth: nil, date: now)]

        for i in 0..<20 {
            let key = "aq:test:1:\(i)"
            cache[key] = (stat, now)
        }

        XCTAssertEqual(cache.count, 20)
        LogStatsCachePolicy.prune(&cache, currentGeneration: 1, now: now, ttl: 0.8, maxEntries: 16)
        XCTAssertEqual(cache.count, 0, "Cache exceeding maxEntries must be cleared to prevent unbounded memory growth.")
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

    func testAppleMusicEffectiveSampleRatePrefersConfirmedScriptRateOverUnverifiedLogs() {
        let decoderStat = CMPlayerStats(sampleRate: 96_000, bitDepth: 24, date: Date())
        let formatStat = CMPlayerStats(sampleRate: 48_000, bitDepth: 24, date: Date())
        let unattributedAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )
        let attributedAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "track-1"
        )

        // Confirmed AppleScript current-track query takes precedence over unverified decoder log
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: decoderStat,
                formatEvidence: nil
            ),
            44_100
        )

        // Confirmed AppleScript current-track query takes precedence over unverified format log
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: formatStat
            ),
            44_100
        )

        // Unattributed Atmos log must NOT override a confirmed current-track query
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: unattributedAtmosStat,
                expectedTrackID: "track-1",
                expectedTrackTitle: "Test Song"
            ),
            44_100
        )

        // Priority format (Dolby Atmos) attributed to the current track takes precedence over 44.1 kHz
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: attributedAtmosStat,
                expectedTrackID: "track-1",
                expectedTrackTitle: "Test Song"
            ),
            48_000
        )

        // Fallback to decoder log when script query is unavailable
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: nil,
                decoderEvidence: decoderStat,
                formatEvidence: nil
            ),
            96_000
        )

        // Fallback to format log when script query is unavailable
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: nil,
                decoderEvidence: nil,
                formatEvidence: formatStat
            ),
            48_000
        )

        // Returns nil when no evidence is available
        XCTAssertNil(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: nil,
                decoderEvidence: nil,
                formatEvidence: nil
            )
        )
    }

    func testAppleMusicConfirmed44kRateNotOverriddenByPostTrackStart48kDecoderLog() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let postTrackDecoderLog = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.2) // Arrived after track start, but lacks track attribution
        )

        // Correctly switched to 44.1 kHz -> received 48 kHz decoder log -> 44.1 kHz must remain effective rate
        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 44_100,
            decoderEvidence: postTrackDecoderLog,
            formatEvidence: nil,
            trackStartedAt: trackStart
        )
        XCTAssertEqual(
            effectiveRate,
            44_100,
            "Unverified 48 kHz decoder log occurring after track start must not override confirmed 44.1 kHz track query."
        )
    }

    func testAppleMusicEffectiveSampleRatePrefersNewerFormatEvidenceOverStaleDecoderLog() {
        let staleDecoderStat = CMPlayerStats(
            sampleRate: 44_100,
            bitDepth: 16,
            date: Date(timeIntervalSince1970: 99.6)
        )
        let newerFormatStat = CMPlayerStats(
            sampleRate: 96_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.1)
        )

        // When formatEvidence (100.1) is newer than decoderEvidence (99.6) in fallback mode, formatEvidence must win
        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: staleDecoderStat,
            formatEvidence: newerFormatStat,
            trackStartedAt: Date(timeIntervalSince1970: 100.0)
        )

        XCTAssertEqual(effectiveRate, 96_000, "Newer format log must take precedence over stale decoder log from previous track.")
    }

    func testAppleMusicEffectiveSampleRateRejectsPreTrackDecoderLogConflictingWithScript() {
        let preTrackDecoderStat = CMPlayerStats(
            sampleRate: 44_100,
            bitDepth: 16,
            date: Date(timeIntervalSince1970: 99.6)
        )

        // Track started at 100.0; AppleScript returned 96 kHz for the current track.
        // A stale 44.1 kHz decoder log from 99.6s must not override the current track's 96 kHz script rate.
        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 96_000,
            decoderEvidence: preTrackDecoderStat,
            formatEvidence: nil,
            trackStartedAt: Date(timeIntervalSince1970: 100.0)
        )

        XCTAssertEqual(effectiveRate, 96_000, "Pre-track decoder log from previous track tail must not override new track's AppleScript rate.")
    }

    func testAppleMusicEffectiveSampleRateDistinguishesTrueTrackStartFromToleranceThreshold() {
        let eventDate = Date(timeIntervalSince1970: 100.0) // true track start (currentTrackStartedAt)
        let toleranceThreshold = eventDate.addingTimeInterval(-0.5) // lastTrackChangeDate (99.5)
        let stalePreTrackDecoderStat = CMPlayerStats(
            sampleRate: 44_100,
            bitDepth: 16,
            date: Date(timeIntervalSince1970: 99.6) // 0.4s before track event, passes tolerance (>= 99.5)
        )

        // 1. Confirmed script rate (96 kHz) is always protected against unverified decoder logs
        let scriptEffectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 96_000,
            decoderEvidence: stalePreTrackDecoderStat,
            formatEvidence: nil,
            trackStartedAt: eventDate
        )
        XCTAssertEqual(scriptEffectiveRate, 96_000, "Confirmed script rate must never be overridden by unverified decoder logs.")

        // 2. In fallback mode (scriptRate == nil), passing true track start (100.0) correctly
        // rejects the 99.6s log as stale pre-track evidence
        let fallbackWithTrueStart = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: stalePreTrackDecoderStat,
            formatEvidence: nil,
            trackStartedAt: eventDate
        )
        XCTAssertNil(fallbackWithTrueStart, "Using true track start (eventDate) must reject pre-track decoder log from previous track tail.")

        // 3. Conversely, passing tolerance threshold (99.5) in fallback mode mistakenly treats 99.6s as current-track evidence
        let fallbackWithTolerance = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: stalePreTrackDecoderStat,
            formatEvidence: nil,
            trackStartedAt: toleranceThreshold
        )
        XCTAssertEqual(fallbackWithTolerance, 44_100, "Passing tolerance threshold would mistake pre-track log as current evidence, confirming why currentTrackStartedAt is needed.")
    }

    func testAppleMusicConfirmed96kRateNotOverriddenByPreTrackAtmosLog() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let staleAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7), // 0.3s before track start (stale from previous track)
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )

        // Current track is confirmed as 96 kHz lossless.
        // A stale Atmos log from 99.7s (before trackStart = 100.0) MUST NOT override the 96 kHz rate!
        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 96_000,
            decoderEvidence: nil,
            formatEvidence: staleAtmosStat,
            trackStartedAt: trackStart
        )
        XCTAssertEqual(
            effectiveRate,
            96_000,
            "Stale pre-track Atmos log occurring before track start must not override confirmed 96 kHz track query."
        )
    }

    func testAppleMusicFreshAtmosLogTakesPrecedenceOverScriptRateOnlyWhenAttributed() {
        let trackStart = Date(timeIntervalSince1970: 100.0)

        // 1. Unattributed Atmos log arriving 0.25s AFTER track change must NOT override confirmed 96 kHz
        let unattributedPostTrackAtmos = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.25),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )
        XCTAssertFalse(
            AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: unattributedPostTrackAtmos,
                expectedTrackID: "song-96k",
                expectedTrackTitle: "Hi-Res Track",
                trackStartedAt: trackStart
            ),
            "Unattributed post-track Atmos log must not take the fast path or override a confirmed track rate."
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 96_000,
                decoderEvidence: nil,
                formatEvidence: unattributedPostTrackAtmos,
                trackStartedAt: trackStart,
                expectedTrackID: "song-96k",
                expectedTrackTitle: "Hi-Res Track"
            ),
            96_000,
            "Confirmed 96 kHz track must not be overridden by an unattributed Atmos log at t + 0.25s."
        )

        // 2. Attributed Atmos log belonging to the current track DOES take precedence
        let attributedAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.3),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "song-96k"
        )
        XCTAssertTrue(
            AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: attributedAtmosStat,
                expectedTrackID: "song-96k",
                expectedTrackTitle: "Hi-Res Track",
                trackStartedAt: trackStart
            )
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 44_100,
                decoderEvidence: nil,
                formatEvidence: attributedAtmosStat,
                trackStartedAt: trackStart,
                expectedTrackID: "song-96k",
                expectedTrackTitle: "Hi-Res Track"
            ),
            48_000,
            "Fresh Atmos log attributed to the current track should take precedence."
        )

        // 3. Cached unattributed Atmos log can be replaced by a newer normal lossless format log
        XCTAssertTrue(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsPriorityFormat: true,
                incomingIsPriorityFormat: false,
                currentIsAttributedToTrack: false,
                incomingIsNewer: true
            ),
            "An unattributed priority format log must be replaceable by a newer normal lossless format log."
        )
        XCTAssertFalse(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsPriorityFormat: true,
                incomingIsPriorityFormat: false,
                currentIsAttributedToTrack: true,
                incomingIsNewer: true
            ),
            "An attributed priority format log must not be replaced by a non-priority format log."
        )
    }

    func testAppleMusicPreNotificationDecoderLogRetainedInFallbackWhilePreNotificationAtmosRejected() {
        let trackStart = Date(timeIntervalSince1970: 100.0) // MediaRemote notification time
        let toleranceThreshold = trackStart.addingTimeInterval(-0.5) // lastTrackChangeDate (99.5)

        // New track started decoding at 99.7s (0.3s before notification), emitting a 96 kHz decoder log.
        let preNotificationDecoderLog = CMPlayerStats(
            sampleRate: 96_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7),
            isAppleMusicFormat: false
        )
        // Stale unattributed Atmos log also at 99.7s (0.3s before notification).
        let preNotificationAtmosLog = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )

        let filtered = AppleMusicFormatPolicy.filterFallbackLogs(
            [preNotificationAtmosLog, preNotificationDecoderLog],
            expectedTrackID: "track-96k",
            expectedTrackTitle: "Pre-decoded Track",
            trackStartedAt: trackStart,
            toleranceThreshold: toleranceThreshold
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(
            filtered.first?.sampleRate,
            96_000,
            "Fallback log filtering must keep pre-notification decoder logs within tolerance while dropping unattributed pre-notification Atmos logs."
        )

        // When AppleScript is unavailable, effectiveSampleRate with decoderToleranceThreshold selects 96 kHz
        let fallbackRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: preNotificationDecoderLog,
            formatEvidence: preNotificationAtmosLog,
            trackStartedAt: trackStart,
            expectedTrackID: "track-96k",
            expectedTrackTitle: "Pre-decoded Track",
            decoderToleranceThreshold: toleranceThreshold
        )
        XCTAssertEqual(
            fallbackRate,
            96_000,
            "When AppleScript is unavailable, pre-notification decoder log within tolerance must be selected."
        )
    }

    func testAppleMusicSubstringTitlesAndSimilarTrackIDsDoNotMatchOrOverrideConfirmed96kRate() {
        let trackStart = Date(timeIntervalSince1970: 100.0)

        // Current track is "Stay" with ID "track-96", confirmed at 96 kHz.
        let stayWithMeAtmos = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.25),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "Stay With Me"
        )
        let similarIDAtmos = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.25),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "track-961"
        )

        XCTAssertEqual(
            stayWithMeAtmos.attribution(trackID: "track-96", title: "Stay"),
            .mismatched,
            "Substring overlap ('Stay' vs 'Stay With Me') must be classified as mismatched, not matched."
        )
        XCTAssertEqual(
            similarIDAtmos.attribution(trackID: "track-96", title: "Stay"),
            .mismatched,
            "Prefix/substring ID overlap ('track-96' vs 'track-961') must be classified as mismatched."
        )

        // Reverse direction: current track is "Stay With Me" / "track-961", log has "Stay" / "track-96"
        let shortTitleAtmos = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.25),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "Stay"
        )
        XCTAssertEqual(
            shortTitleAtmos.attribution(trackID: "track-961", title: "Stay With Me"),
            .mismatched
        )

        // Neither similar-title nor similar-ID Atmos logs may override the confirmed 96 kHz rate
        XCTAssertFalse(
            AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: stayWithMeAtmos,
                expectedTrackID: "track-96",
                expectedTrackTitle: "Stay",
                trackStartedAt: trackStart
            )
        )
        XCTAssertFalse(
            AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: similarIDAtmos,
                expectedTrackID: "track-96",
                expectedTrackTitle: "Stay",
                trackStartedAt: trackStart
            )
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 96_000,
                decoderEvidence: nil,
                formatEvidence: stayWithMeAtmos,
                trackStartedAt: trackStart,
                expectedTrackID: "track-96",
                expectedTrackTitle: "Stay"
            ),
            96_000
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.effectiveSampleRate(
                scriptRate: 96_000,
                decoderEvidence: nil,
                formatEvidence: similarIDAtmos,
                trackStartedAt: trackStart,
                expectedTrackID: "track-96",
                expectedTrackTitle: "Stay"
            ),
            96_000
        )
    }

    func testAppleMusicFallbackRejectsKnownMismatchedLogsAndKeepsPreNotification96kDecoderLog() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let toleranceThreshold = trackStart.addingTimeInterval(-0.5) // 99.5

        // Current track's 96 kHz decoder log arrives 0.3s before notification (unattributed)
        let preNotification96kDecoder = CMPlayerStats(
            sampleRate: 96_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7),
            isAppleMusicFormat: false
        )
        // Later (at 100.3s), a 48 kHz format log explicitly belonging to another track arrives
        let otherTrack48kFormat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.3),
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: "Stay With Me"
        )

        // 1. filterFallbackLogs must reject the explicitly mismatched 48 kHz log and retain 96 kHz
        let filtered = AppleMusicFormatPolicy.filterFallbackLogs(
            [preNotification96kDecoder, otherTrack48kFormat],
            expectedTrackID: "track-96",
            expectedTrackTitle: "Stay",
            trackStartedAt: trackStart,
            toleranceThreshold: toleranceThreshold
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.sampleRate, 96_000)

        // 2. preferredFallbackEvidence must reject the mismatched 48 kHz format log even though it is newer
        let preferred = AppleMusicFormatPolicy.preferredFallbackEvidence(
            formatEvidence: otherTrack48kFormat,
            decoderEvidence: preNotification96kDecoder,
            expectedTrackID: "track-96",
            expectedTrackTitle: "Stay",
            trackStartedAt: trackStart,
            decoderToleranceThreshold: toleranceThreshold
        )
        XCTAssertEqual(preferred?.stat.sampleRate, 96_000)
        XCTAssertEqual(preferred?.source, .decoderLog)

        // 3. effectiveSampleRate in fallback mode (scriptRate == nil) must also return 96 kHz
        let effective = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: preNotification96kDecoder,
            formatEvidence: otherTrack48kFormat,
            trackStartedAt: trackStart,
            expectedTrackID: "track-96",
            expectedTrackTitle: "Stay",
            decoderToleranceThreshold: toleranceThreshold
        )
        XCTAssertEqual(
            effective,
            96_000,
            "Known mismatched 48 kHz log must be excluded from fallback so the retained 96 kHz decoder log wins."
        )
    }

    func testDeviceFormatFailureFallbackNeverWritesRejectedTargetRate() {
        // When device rejects setting 96 kHz and readback + history are all nil,
        // fallbackStateOnFailure must keep sampleRate nil (unconfirmed) so the next poll retries.
        let unconfirmedFallback = DeviceFormatVerification.fallbackStateOnFailure(
            nominalRate: nil,
            streamPhysicalFormat: nil,
            currentOutputBitDepth: nil,
            previousSampleRate: nil,
            previousBitDepth: nil
        )
        XCTAssertNil(
            unconfirmedFallback.sampleRate,
            "Failed format application must not fall back to the rejected target rate when readback and history are nil."
        )
        XCTAssertFalse(unconfirmedFallback.hasConfirmedSampleRate)

        // When previousSampleRate is known (e.g. 44.1 kHz) and readback is nil, preserve 44.1 kHz
        let previousFallback = DeviceFormatVerification.fallbackStateOnFailure(
            nominalRate: nil,
            streamPhysicalFormat: nil,
            currentOutputBitDepth: 16,
            previousSampleRate: 44_100,
            previousBitDepth: 24
        )
        XCTAssertEqual(previousFallback.sampleRate, 44_100)
        XCTAssertEqual(previousFallback.bitDepth, 16)

        // When device nominalRate is readable (e.g. stayed at 48 kHz), report actual 48 kHz
        let nominalFallback = DeviceFormatVerification.fallbackStateOnFailure(
            nominalRate: 48_000,
            streamPhysicalFormat: nil,
            currentOutputBitDepth: nil,
            previousSampleRate: 44_100,
            previousBitDepth: 16
        )
        XCTAssertEqual(nominalFallback.sampleRate, 48_000)
        XCTAssertEqual(nominalFallback.bitDepth, 16)
    }

    func testAppleMusicRecoveryProbePolicy() {
        // Should schedule recovery when in fallbackToLogs and no confirmed rate has been obtained
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .fallbackToLogs,
                hasKnownCurrentTrackRate: false,
                attempts: 0
            )
        )
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .fallbackToLogs,
                hasKnownCurrentTrackRate: false,
                attempts: 1
            )
        )
        // Should NOT schedule if max attempts reached
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .fallbackToLogs,
                hasKnownCurrentTrackRate: false,
                attempts: 2
            )
        )
        // Should NOT schedule if a valid rate is already known
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .fallbackToLogs,
                hasKnownCurrentTrackRate: true,
                attempts: 0
            )
        )
        // Should NOT schedule if in other states (e.g. waiting, querying, resolved)
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .waiting,
                hasKnownCurrentTrackRate: false,
                attempts: 0
            )
        )
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
                state: .resolved(96000),
                hasKnownCurrentTrackRate: false,
                attempts: 0
            )
        )
    }

    func testAppleMusicPreTrackAtmosLogCannotBypassWhenScriptRateUnavailable() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let staleAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7), // 0.3s before track start
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )

        // When AppleScript query fails or is unavailable (scriptRate == nil),
        // a stale pre-track Atmos log must NOT bypass filtering and must NOT be selected.
        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: nil,
            formatEvidence: staleAtmosStat,
            trackStartedAt: trackStart
        )
        XCTAssertNil(
            effectiveRate,
            "Stale pre-track Atmos log must not be returned when scriptRate is unavailable."
        )

        // When the Atmos log is fresh (>= trackStart), it should be accepted.
        let freshAtmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.2),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )
        let freshRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: nil,
            formatEvidence: freshAtmosStat,
            trackStartedAt: trackStart
        )
        XCTAssertEqual(
            freshRate,
            48_000,
            "Fresh Atmos log for current track should be accepted when scriptRate is unavailable."
        )
    }

    func testAppleMusicStaleLogsDoNotBlockAppleScriptFallback() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let staleLog = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )
        let rawLogs = [staleLog]
        let validLogs = rawLogs.filter { $0.date >= trackStart }

        XCTAssertTrue(validLogs.isEmpty, "Pre-track logs must be filtered out for current track.")

        // When validLogs is empty, hasLogStats is false: resolution should request AppleScript query
        let resolution = AppleMusicFormatPolicy.resolution(
            hasLogEvidence: false,
            hasLogStats: !validLogs.isEmpty,
            hasCachedFallback: false,
            hasAttemptedFallback: false,
            isPlaying: true
        )
        XCTAssertEqual(
            resolution,
            .requestAppleScript,
            "Filtered out pre-track logs must not block AppleScript playback state fallback."
        )
    }

    func testAppleMusicFallbackWithBothStaleDecoderAndStaleAtmosReturnsNil() {
        let trackStart = Date(timeIntervalSince1970: 100.0)
        let staleAtmos = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 99.7),
            isAppleMusicFormat: true,
            isDolbyAtmos: true
        )
        let staleDecoder = CMPlayerStats(
            sampleRate: 44_100,
            bitDepth: 16,
            date: Date(timeIntervalSince1970: 99.5),
            isAppleMusicFormat: false,
            isDolbyAtmos: false
        )

        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: nil,
            decoderEvidence: staleDecoder,
            formatEvidence: staleAtmos,
            trackStartedAt: trackStart
        )
        XCTAssertNil(
            effectiveRate,
            "When all evidence is pre-track and scriptRate is unavailable, effective rate must be nil."
        )
    }

    func testDeviceFormatVerificationIgnoresClockDriftAndUsesNominalRate() {
        let targetRate: Float64 = 48_000

        // Success case: nominal rate matches 48000, driver returned ok.
        // Even if actual measured clock was 47999.8 Hz, nominal rate confirmation succeeds.
        XCTAssertTrue(
            DeviceFormatVerification.isSampleRateApplied(
                targetRate: targetRate,
                nominalRate: 48_000,
                rateSetOk: true
            )
        )

        // Sub-hertz floating point tolerance (< 1.0 Hz)
        XCTAssertTrue(
            DeviceFormatVerification.isSampleRateApplied(
                targetRate: targetRate,
                nominalRate: 48_000.0001,
                rateSetOk: true
            )
        )

        // Device nominal rate mismatch (e.g. still at 44100)
        XCTAssertFalse(
            DeviceFormatVerification.isSampleRateApplied(
                targetRate: targetRate,
                nominalRate: 44_100,
                rateSetOk: true
            )
        )

        // Driver call failed
        XCTAssertFalse(
            DeviceFormatVerification.isSampleRateApplied(
                targetRate: targetRate,
                nominalRate: 48_000,
                rateSetOk: false
            )
        )

        // Nominal rate readback is nil
        XCTAssertFalse(
            DeviceFormatVerification.isSampleRateApplied(
                targetRate: targetRate,
                nominalRate: nil,
                rateSetOk: true
            )
        )
    }

    func testDevicePhysicalFormatVerificationChecksBitDepthAndSampleRate() {
        let targetRate: Float64 = 48_000
        let targetBitDepth: UInt32 = 32

        var matchingFormat = AudioStreamBasicDescription()
        matchingFormat.mSampleRate = 48_000
        matchingFormat.mBitsPerChannel = 32

        // Both sample rate and bit depth match
        XCTAssertTrue(
            DeviceFormatVerification.isPhysicalFormatApplied(
                targetRate: targetRate,
                targetBitDepth: targetBitDepth,
                streamPhysicalFormat: matchingFormat,
                nominalRate: 48_000
            )
        )

        // Bit depth failed to change (e.g. device DAC stayed at 24-bit)
        var rejectedBitDepthFormat = matchingFormat
        rejectedBitDepthFormat.mBitsPerChannel = 24
        XCTAssertFalse(
            DeviceFormatVerification.isPhysicalFormatApplied(
                targetRate: targetRate,
                targetBitDepth: targetBitDepth,
                streamPhysicalFormat: rejectedBitDepthFormat,
                nominalRate: 48_000
            ),
            "Bit depth mismatch must report failure so the target bit depth is not falsely cached."
        )

        // Sample rate mismatch in stream format
        var wrongRateFormat = matchingFormat
        wrongRateFormat.mSampleRate = 44_100
        XCTAssertFalse(
            DeviceFormatVerification.isPhysicalFormatApplied(
                targetRate: targetRate,
                targetBitDepth: targetBitDepth,
                streamPhysicalFormat: wrongRateFormat,
                nominalRate: 48_000
            )
        )

        // Stream format readback is nil
        XCTAssertFalse(
            DeviceFormatVerification.isPhysicalFormatApplied(
                targetRate: targetRate,
                targetBitDepth: targetBitDepth,
                streamPhysicalFormat: nil,
                nominalRate: 48_000
            ),
            "Nil stream format readback must report failure."
        )

        // Nominal rate mismatch when present
        XCTAssertFalse(
            DeviceFormatVerification.isPhysicalFormatApplied(
                targetRate: targetRate,
                targetBitDepth: targetBitDepth,
                streamPhysicalFormat: matchingFormat,
                nominalRate: 96_000
            )
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

    func testWidgetStateMergeDoesNotResurrectClearedTrackWhenOneFileWriteFails() {
        // File A succeeded in clearing track at t=50
        let clearedFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 16,
            formatUpdatedAt: Date(timeIntervalSince1970: 20),
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil,
            formatClearedAt: nil,
            trackClearedAt: Date(timeIntervalSince1970: 50)
        )
        // File B failed to write, remaining on stale track at t=20
        let staleFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 16,
            formatUpdatedAt: Date(timeIntervalSince1970: 20),
            title: "Stale Song",
            artist: "Stale Artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 20),
            formatClearedAt: nil,
            trackClearedAt: nil
        )

        let merged = RateSyncWidgetConfiguration.mergeStates([clearedFileState, staleFileState])

        XCTAssertNil(merged?.title, "A cleared track state at t=50 must not resurrect the stale song from t=20.")
        XCTAssertNil(merged?.artist)
        XCTAssertEqual(merged?.trackClearedAt, Date(timeIntervalSince1970: 50))
    }

    func testWidgetStateMergeDoesNotResurrectClearedFormatWhenOneFileWriteFails() {
        // File A succeeded in clearing format at t=50
        let clearedFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: nil,
            bitDepth: nil,
            formatUpdatedAt: nil,
            title: "Current Song",
            artist: "Current Artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 20),
            formatClearedAt: Date(timeIntervalSince1970: 50),
            trackClearedAt: nil
        )
        // File B failed to write, remaining on stale format at t=20
        let staleFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 96_000,
            bitDepth: 24,
            formatUpdatedAt: Date(timeIntervalSince1970: 20),
            title: "Current Song",
            artist: "Current Artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 20),
            formatClearedAt: nil,
            trackClearedAt: nil
        )

        let merged = RateSyncWidgetConfiguration.mergeStates([clearedFileState, staleFileState])

        XCTAssertNil(merged?.sampleRate, "A cleared format state at t=50 must not resurrect the stale format from t=20.")
        XCTAssertNil(merged?.bitDepth)
        XCTAssertEqual(merged?.formatClearedAt, Date(timeIntervalSince1970: 50))
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

    func testPendingTrackEventCoalescerReleasesBackloggedPayloadsImmediately() {
        final class HeavyPayload {
            let id: Int
            let data: Data
            init(id: Int) {
                self.id = id
                self.data = Data(repeating: UInt8(id & 0xFF), count: 64 * 1024)
            }
        }

        let coalescer = PendingTrackEventCoalescer<HeavyPayload>()
        var weakRefs: [ () -> HeavyPayload? ] = []

        for index in 0..<48 {
            autoreleasepool {
                let payload = HeavyPayload(id: index)
                weak var weakPayload = payload
                weakRefs.append({ weakPayload })
                let shouldSchedule = coalescer.enqueue(payload)
                if index == 0 {
                    XCTAssertTrue(shouldSchedule, "First enqueued event must schedule a drain.")
                } else {
                    XCTAssertFalse(shouldSchedule, "Subsequent events while busy must coalesce without scheduling extra blocks.")
                }
            }
        }

        // All 47 superseded payloads must already be deallocated before the queue even drains!
        for index in 0..<47 {
            XCTAssertNil(weakRefs[index](), "Superseded payload \(index) must be released immediately on overwrite.")
        }
        XCTAssertNotNil(weakRefs[47](), "Only the latest payload (47) should remain pending.")

        autoreleasepool {
            let drained = coalescer.takeNext()
            XCTAssertEqual(drained?.id, 47)
        }
        XCTAssertNil(weakRefs[47](), "Latest payload must be released once drained.")
    }

    func testSteadyStateAndPausedPollingPoliciesStopRedundantAppleScriptAndLogScans() {
        let trackStart = Date(timeIntervalSince1970: 1_000)
        let afterSettling = trackStart.addingTimeInterval(15)

        // 1. Atmos log probe must not schedule when paused (.notPlaying) or past maxProbeWindow
        XCTAssertFalse(
            AppleMusicFormatProbePolicy.shouldSchedule(
                generation: 1,
                scheduledGeneration: nil,
                completedGeneration: nil,
                lastCompletedAt: nil,
                now: trackStart.addingTimeInterval(1),
                trackStartedAt: trackStart,
                sampleRateState: .notPlaying
            ),
            "Atmos OSLog probe must never run while Apple Music is paused."
        )
        XCTAssertFalse(
            AppleMusicFormatProbePolicy.shouldSchedule(
                generation: 1,
                scheduledGeneration: nil,
                completedGeneration: 1,
                lastCompletedAt: trackStart.addingTimeInterval(2),
                now: afterSettling,
                trackStartedAt: trackStart,
                sampleRateState: .resolved(96_000)
            ),
            "Atmos OSLog probe must not keep rescanning after the track settling window has passed."
        )

        // 2. AppleScript revalidation must stop once the track is locked and past the settling window
        XCTAssertTrue(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: trackStart.addingTimeInterval(0.5),
                now: trackStart.addingTimeInterval(3.0),
                trackStartedAt: trackStart,
                isTrackLocked: true
            ),
            "Within the initial settling window, revalidation is still allowed to catch delayed Hi-Res loading."
        )
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: trackStart.addingTimeInterval(3.0),
                now: afterSettling,
                trackStartedAt: trackStart,
                isTrackLocked: true
            ),
            "Once locked and past the settling window, periodic polling must not re-query AppleScript."
        )

        // 3. SteadyStatePollingPolicy skips polling when paused or settled
        XCTAssertFalse(
            SteadyStatePollingPolicy.shouldPollTrack(
                hasCurrentTrack: true,
                isTrackLocked: false,
                hasPendingCandidate: false,
                appleMusicState: .notPlaying,
                trackStartedAt: trackStart,
                now: trackStart.addingTimeInterval(3.0)
            )
        )
        XCTAssertFalse(
            SteadyStatePollingPolicy.shouldPollTrack(
                hasCurrentTrack: true,
                isTrackLocked: true,
                hasPendingCandidate: false,
                appleMusicState: .resolved(96_000),
                trackStartedAt: trackStart,
                now: afterSettling
            )
        )

        // 4. Pause recovery check stops when track is already locked or after maxResumeChecks
        XCTAssertNil(
            AppleMusicPlaybackRecoveryPolicy.retryDelay(
                hasCurrentTrack: true,
                isTrackLocked: true,
                attempts: 0
            )
        )
        XCTAssertNil(
            AppleMusicPlaybackRecoveryPolicy.retryDelay(
                hasCurrentTrack: true,
                isTrackLocked: false,
                attempts: AppleMusicPlaybackRecoveryPolicy.maxResumeChecks
            )
        )
    }

    func testPendingTrackEventCoalescerPreservesCausalOrderAcrossClearAndSubsequentTrack() {
        final class TrackPayload {
            let title: String
            init(_ title: String) { self.title = title }
        }

        let coalescer = PendingTrackEventCoalescer<TrackPayload>()
        weak var weakTrackA: TrackPayload?
        weak var weakTrackB: TrackPayload?

        // Replay: Queue busy -> Track A -> Clear -> Track B
        autoreleasepool {
            let trackA = TrackPayload("Track A")
            weakTrackA = trackA
            XCTAssertTrue(coalescer.enqueue(trackA), "First event must schedule drain.")
        }
        XCTAssertNotNil(weakTrackA)

        XCTAssertFalse(
            coalescer.enqueueClear(),
            "Clear while drain is already scheduled must coalesce into the same drain turn."
        )
        XCTAssertNil(weakTrackA, "Clear must immediately release prior pending Track A.")

        autoreleasepool {
            let trackB = TrackPayload("Track B")
            weakTrackB = trackB
            XCTAssertFalse(
                coalescer.enqueue(trackB),
                "Track B after clear while drain is already scheduled must coalesce into the same drain turn."
            )
        }
        XCTAssertNotNil(weakTrackB)

        // Simulate draining in order: Clear must execute before Track B, leaving Track B as final state.
        var activeTrack: String? = "Old Track"
        if let action = coalescer.takeNextAction() {
            switch action {
            case .event(let track):
                activeTrack = track.title
            case .clear:
                activeTrack = nil
            case .clearThenEvent(let track):
                activeTrack = nil
                activeTrack = track.title
            case .resetArbitration:
                break
            case .resetArbitrationThenEvent(let track):
                activeTrack = track.title
            }
        }
        XCTAssertEqual(activeTrack, "Track B", "Track B arriving after Clear must survive as the active track.")

        // Also replay: Track A -> Track B -> Clear -> final state must be nil.
        _ = coalescer.enqueue(TrackPayload("Track A"))
        _ = coalescer.enqueue(TrackPayload("Track B"))
        _ = coalescer.enqueueClear()
        if let action = coalescer.takeNextAction() {
            if action.includesClear {
                activeTrack = nil
            }
            if let track = action.event {
                activeTrack = track.title
            }
        }
        XCTAssertNil(activeTrack, "Clear arriving after Track B must leave no active track.")
    }

    func testTrackEventIdentityDoesNotSuppressPauseResumeWithIdenticalTimestamp() {
        let now = Date(timeIntervalSince1970: 2_000)
        let paused = TrackEventIdentity(
            title: "Song",
            artist: "Artist",
            album: "Album",
            artworkDataBase64: "AAAA",
            bundleIdentifier: "com.apple.Music",
            processID: 123,
            timestampEpochMicros: 1_700_000_000_000_000,
            isPlaying: false
        )
        let resumed = TrackEventIdentity(
            title: "Song",
            artist: "Artist",
            album: "Album",
            artworkDataBase64: "AAAA",
            bundleIdentifier: "com.apple.Music",
            processID: 123,
            timestampEpochMicros: 1_700_000_000_000_000,
            isPlaying: true
        )

        XCTAssertFalse(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: paused,
                current: resumed,
                lastDeliveredAt: now,
                now: now.addingTimeInterval(0.1)
            ),
            "Resume event with identical timestamp must not be suppressed as a duplicate of the pause event."
        )
        XCTAssertTrue(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: resumed,
                current: resumed,
                lastDeliveredAt: now,
                now: now.addingTimeInterval(0.1)
            ),
            "Identical burst events with the same isPlaying state and timestamp must still be suppressed."
        )
    }

    func testSteadyStatePollingReevaluatesOnOutputDeviceChangeAndSettlesOnEqualRateMatch() {
        let trackStart = Date(timeIntervalSince1970: 3_000)
        let at30Seconds = trackStart.addingTimeInterval(30)

        // 1. P2 replay: 96 kHz track locked on Device A (at 96 kHz) for > 8s, then switched to Device B (at 48 kHz)
        let deviceAMatch = SteadyStatePollingPolicy.ConfirmedDeviceMatch(
            deviceUID: "Device-A",
            sampleRate: 96_000,
            bitDepth: 24,
            sourceSampleRate: 96_000
        )
        let matchedOnDeviceB = SteadyStatePollingPolicy.isDeviceMatched(
            lockedSampleRate: 96_000,
            lockedBitDepth: 24,
            lockedDeviceUID: "Device-A",
            confirmedMatch: deviceAMatch,
            currentDeviceUID: "Device-B",
            currentDeviceSampleRate: 48_000,
            currentDeviceBitDepth: 24,
            enableBitDepthDetection: false
        )
        XCTAssertFalse(matchedOnDeviceB, "Lock from Device A (96 kHz) must not consider Device B (48 kHz) matched.")
        XCTAssertTrue(
            SteadyStatePollingPolicy.shouldPollTrack(
                hasCurrentTrack: true,
                isTrackLocked: false,
                isDeviceMatched: matchedOnDeviceB,
                hasPendingCandidate: false,
                appleMusicState: .resolved(96_000),
                trackStartedAt: trackStart,
                now: at30Seconds
            ),
            "Polling must re-evaluate when the active output device does not match the confirmed rate."
        )

        // 2. P2 replay: Consecutive 44.1 kHz track when device is already at 44.1 kHz
        // `lockedSampleRate` stays nil (preserving switching lock semantics), while `confirmedMatch` is recorded.
        let equalRateMatch = SteadyStatePollingPolicy.ConfirmedDeviceMatch(
            deviceUID: "Device-A",
            sampleRate: 44_100,
            bitDepth: 16,
            sourceSampleRate: 44_100
        )
        let isEqualRateDeviceMatched = SteadyStatePollingPolicy.isDeviceMatched(
            lockedSampleRate: nil,
            lockedBitDepth: nil,
            lockedDeviceUID: nil,
            confirmedMatch: equalRateMatch,
            currentDeviceUID: "Device-A",
            currentDeviceSampleRate: 44_100,
            currentDeviceBitDepth: 16,
            enableBitDepthDetection: false
        )
        XCTAssertTrue(isEqualRateDeviceMatched, "Equal-rate no-op must record a confirmed device match.")
        XCTAssertFalse(
            SteadyStatePollingPolicy.shouldPollTrack(
                hasCurrentTrack: true,
                isTrackLocked: false,
                isDeviceMatched: isEqualRateDeviceMatched,
                hasPendingCandidate: false,
                appleMusicState: .resolved(44_100),
                trackStartedAt: trackStart,
                now: at30Seconds
            ),
            "At 30s into an equal-rate track, steady-state polling must skip redundant AppleScript queries."
        )
        XCTAssertFalse(
            AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: trackStart.addingTimeInterval(2.0),
                now: at30Seconds,
                trackStartedAt: trackStart,
                isTrackLocked: isEqualRateDeviceMatched
            ),
            "At 30s into an equal-rate track, AppleScript revalidation must not fire."
        )
    }

    func testLongPauseResetsSettlingWindowAndRevalidatesInsteadOfReusingResolvedRate() {
        let initialTrackStart = Date(timeIntervalSince1970: 10_000)
        let pausedAt = initialTrackStart.addingTimeInterval(30)
        let resumedAt = initialTrackStart.addingTimeInterval(60)

        // 1. Prior to pause, track reached 30s with confirmed 44.1 kHz lock.
        // If trackStartedAt is NOT reset on resume (remains initialTrackStart at 60s), revalidation is blocked:
        let blockedWithoutReset = AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
            lastQueriedAt: pausedAt,
            now: resumedAt.addingTimeInterval(2.0),
            trackStartedAt: initialTrackStart,
            isTrackLocked: true
        )
        XCTAssertFalse(blockedWithoutReset, "Without resetting trackStartedAt, 62s elapsed since trackStart blocks revalidation.")

        // 2. With resumedAt as the new tracking baseline, detection window is restarted:
        let allowsRevalidationWithReset = AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
            lastQueriedAt: resumedAt,
            now: resumedAt.addingTimeInterval(2.0),
            trackStartedAt: resumedAt,
            isTrackLocked: true
        )
        XCTAssertTrue(allowsRevalidationWithReset, "Restarting detection baseline at resumedAt allows revalidation to detect updated Hi-Res rate.")

        // 3. Steady state polling should poll during the restarted settling window:
        let shouldPollAfterResume = SteadyStatePollingPolicy.shouldPollTrack(
            hasCurrentTrack: true,
            isTrackLocked: true,
            isDeviceMatched: true,
            hasPendingCandidate: false,
            appleMusicState: .waiting,
            trackStartedAt: resumedAt,
            now: resumedAt.addingTimeInterval(2.0)
        )
        XCTAssertTrue(shouldPollAfterResume, "Steady state polling must stay active during the restarted settling window.")
    }

    func testBitDepthFailureClearsOldLockAndRetainsPendingCandidateForRetry() {
        // Replay: Current device is at 44.1 kHz, 16-bit. Target is 44.1 kHz, 24-bit.
        // Device rejected format change and remained at 16-bit.
        let deviceUID = "DAC-1"
        let rate: Float64 = 44_100
        let targetBitDepth = 24
        let currentDeviceBitDepth = 16

        // Old state before failure:
        var lockedRate: Float64? = rate
        var lockedBitDepth: Int? = 16
        var lockedDeviceUID: String? = deviceUID
        var confirmedMatch: SteadyStatePollingPolicy.ConfirmedDeviceMatch? = SteadyStatePollingPolicy.ConfirmedDeviceMatch(
            deviceUID: deviceUID,
            sampleRate: rate,
            bitDepth: 16,
            sourceSampleRate: rate
        )
        var pendingCandidate: RateGateDecisionPolicy.CandidateTracking? = nil

        // If only confirmedMatch is removed while old lock is kept:
        let mistakenlyMatchedWithOldLock = SteadyStatePollingPolicy.isDeviceMatched(
            lockedSampleRate: lockedRate,
            lockedBitDepth: lockedBitDepth,
            lockedDeviceUID: lockedDeviceUID,
            confirmedMatch: nil,
            currentDeviceUID: deviceUID,
            currentDeviceSampleRate: rate,
            currentDeviceBitDepth: currentDeviceBitDepth,
            enableBitDepthDetection: true
        )
        XCTAssertTrue(mistakenlyMatchedWithOldLock, "Keeping the old 16-bit lock mistakenly matches device at 16-bit.")

        // Fix: Failure clears both confirmedMatch and the old lock, retaining candidate:
        confirmedMatch = nil
        lockedRate = nil
        lockedBitDepth = nil
        lockedDeviceUID = nil
        pendingCandidate = RateGateDecisionPolicy.CandidateTracking(
            rate: rate,
            generation: 1,
            firstSeen: Date()
        )

        let isMatchedAfterProperClearing = SteadyStatePollingPolicy.isDeviceMatched(
            lockedSampleRate: lockedRate,
            lockedBitDepth: lockedBitDepth,
            lockedDeviceUID: lockedDeviceUID,
            confirmedMatch: confirmedMatch,
            currentDeviceUID: deviceUID,
            currentDeviceSampleRate: rate,
            currentDeviceBitDepth: currentDeviceBitDepth,
            enableBitDepthDetection: true
        )
        XCTAssertFalse(isMatchedAfterProperClearing, "Device at 16-bit must NOT match once old lock is cleared.")

        let shouldRetryInPolling = SteadyStatePollingPolicy.shouldPollTrack(
            hasCurrentTrack: true,
            isTrackLocked: false,
            isDeviceMatched: false,
            hasPendingCandidate: pendingCandidate != nil,
            appleMusicState: .resolved(rate),
            trackStartedAt: Date(timeIntervalSince1970: 20_000),
            now: Date(timeIntervalSince1970: 20_030)
        )
        XCTAssertTrue(shouldRetryInPolling, "Steady-state polling must continue to retry when pending candidate exists.")
    }

    func testMediaRemoteControllerUpstreamQueueCoalescesBackloggedArtworkPayloads() {
        final class HeavyArtworkPayload {
            let id: Int
            let artwork: Data
            init(id: Int) {
                self.id = id
                self.artwork = Data(repeating: UInt8(id & 0x7F), count: 1024 * 1024) // 1 MiB
            }
        }

        let coalescer = PendingTrackEventCoalescer<HeavyArtworkPayload>()
        var weakRefs: [ () -> HeavyArtworkPayload? ] = []

        // Simulate 32 track events arriving while upstream queue is blocked:
        for index in 0..<32 {
            autoreleasepool {
                let payload = HeavyArtworkPayload(id: index)
                weak var weakPayload = payload
                weakRefs.append({ weakPayload })
                let isDrainScheduled = coalescer.enqueue(payload)
                if index == 0 {
                    XCTAssertTrue(isDrainScheduled, "First event must schedule drain.")
                } else {
                    XCTAssertFalse(isDrainScheduled, "Subsequent events must overwrite without scheduling extra blocks.")
                }
            }
        }

        // Verify that 31 superseded heavy payloads were released immediately on overwrite
        for index in 0..<31 {
            XCTAssertNil(weakRefs[index](), "Upstream superseded payload \(index) with 1 MiB artwork must be freed immediately.")
        }
        XCTAssertNotNil(weakRefs[31](), "Only the 32nd (latest) payload should remain in memory.")

        autoreleasepool {
            let latest = coalescer.takeNext()
            XCTAssertEqual(latest?.id, 31)
        }
        XCTAssertNil(weakRefs[31](), "Latest payload must be released once drained.")
    }

    func testMediaRemoteControllerStartupResetConsumesQueueAndDeliversSubsequentTracks() {
        final class TrackPayload {
            let title: String
            init(_ title: String) { self.title = title }
        }

        let coalescer = PendingTrackEventCoalescer<TrackPayload>()

        // 1. Simulate startup defaults observing: 3 consecutive resets
        _ = coalescer.enqueueClear()
        _ = coalescer.enqueueClear()
        _ = coalescer.enqueueClear()

        // 2. Simulate 3 consecutive track events arriving right after startup
        _ = coalescer.enqueue(TrackPayload("Track 1"))
        _ = coalescer.enqueue(TrackPayload("Track 2"))
        _ = coalescer.enqueue(TrackPayload("Track 3"))

        // 3. Drain must take the coalesced action without stalling
        guard let action = coalescer.takeNextAction() else {
            XCTFail("Queue must not stall after startup reset.")
            return
        }

        XCTAssertTrue(action.includesClear, "Startup clear must be preserved prior to track delivery.")
        XCTAssertEqual(action.event?.title, "Track 3", "Latest track event must be preserved and consumed.")

        // Drain until empty, just like the while loop in drainPendingEvents
        XCTAssertNil(coalescer.takeNextAction(), "Queue must be empty after popping coalesced action.")

        // 4. Verify that subsequent events after drain schedule new drain turns normally
        let canScheduleNext = coalescer.enqueue(TrackPayload("Track 4"))
        XCTAssertTrue(canScheduleNext, "Queue must be open for new events after drain.")
    }

    func testMediaRemoteControllerPreFiltersUnmonitoredSourceToPreventOverwritingMonitoredSource() {
        struct MockTrackEvent {
            let title: String
            let bundleIdentifier: String
        }

        let coalescer = PendingTrackEventCoalescer<MockTrackEvent>()
        let monitoredBundleID = PlayerProfile.appleMusic.bundleIdentifier

        func enqueueIfMonitored(_ event: MockTrackEvent) -> Bool {
            let decision = MonitoredSourceDecision.decide(
                monitoredBundleIdentifier: monitoredBundleID,
                incomingBundleIdentifier: event.bundleIdentifier
            )
            guard decision == .deliver else { return false }
            return coalescer.enqueue(event)
        }

        // When queue is busy, Music arrives first, then unmonitored Spotify arrives
        let musicEvent = MockTrackEvent(title: "Music Track", bundleIdentifier: monitoredBundleID)
        let spotifyEvent = MockTrackEvent(title: "Spotify Track", bundleIdentifier: "com.spotify.client")

        let scheduledMusic = enqueueIfMonitored(musicEvent)
        XCTAssertTrue(scheduledMusic, "Monitored Music track must be enqueued.")

        let acceptedSpotify = enqueueIfMonitored(spotifyEvent)
        XCTAssertFalse(acceptedSpotify, "Unmonitored Spotify track must be rejected before enqueue.")

        // Verify that the queue retains Music Track and was not overwritten by Spotify Track
        let pending = coalescer.takeNext()
        XCTAssertEqual(pending?.title, "Music Track", "Monitored track must not be overwritten by unmonitored source.")
    }

    func testFallbackFormatReadbackPreservesPendingCandidateForRetry() {
        let targetRate: Float64 = 44_100
        let targetBitDepth = 24
        let fallbackRate: Float64 = 44_100
        let fallbackBitDepth = 16

        // Simulate state updates after format failure
        var previousSampleRate: Float64? = nil
        var previousBitDepth: Int? = nil
        var pendingCandidate: RateGateDecisionPolicy.CandidateTracking? = RateGateDecisionPolicy.CandidateTracking(
            rate: targetRate,
            generation: 1,
            firstSeen: Date()
        )

        func updateSampleRateSimulated(
            _ sampleRate: Float64,
            bitDepth: Int?,
            preserveCandidate: Bool = false
        ) {
            previousSampleRate = sampleRate
            if !preserveCandidate {
                pendingCandidate = nil
            }
            previousBitDepth = bitDepth
        }

        // The actual bug: when reading back fallback device rate, calling updateSampleRate wiped pendingCandidate.
        // With preserveCandidate: true, pendingCandidate remains preserved.
        updateSampleRateSimulated(fallbackRate, bitDepth: fallbackBitDepth, preserveCandidate: true)
        XCTAssertNotNil(pendingCandidate, "Fallback device format readback must not wipe pendingCandidate.")

        // Verify SteadyStatePollingPolicy continues to poll because candidate is preserved
        let shouldPoll = SteadyStatePollingPolicy.shouldPollTrack(
            hasCurrentTrack: true,
            isTrackLocked: false,
            isDeviceMatched: false,
            hasPendingCandidate: pendingCandidate != nil,
            appleMusicState: .resolved(targetRate),
            trackStartedAt: Date(timeIntervalSince1970: 30_000),
            now: Date(timeIntervalSince1970: 30_030)
        )
        XCTAssertTrue(shouldPoll, "Steady state polling must retry when pending candidate is preserved.")
    }

    func testAutomaticModePendingEventCoalescerProtectsHighPriorityEventUnderLock() {
        struct MockTakeoverEvent {
            let title: String
            let bundleIdentifier: String
        }

        let coalescer = PendingTrackEventCoalescer<MockTakeoverEvent>()
        let priority = PlayerProfile.normalizedPriority([PlayerProfile.appleMusic.bundleIdentifier, "com.spotify.client"])

        let musicEvent = MockTakeoverEvent(title: "Music Track", bundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier)
        let spotifyEvent = MockTakeoverEvent(title: "Spotify Track", bundleIdentifier: "com.spotify.client")

        // 1. Music (higher priority) enqueues
        let scheduledMusic = coalescer.enqueue(musicEvent, shouldOverwrite: { existing, new in
            let existingPriority = PlayerTakeoverPolicy.priorityIndex(for: existing.bundleIdentifier, priority: priority)
            let newPriority = PlayerTakeoverPolicy.priorityIndex(for: new.bundleIdentifier, priority: priority)
            return newPriority <= existingPriority
        })
        XCTAssertTrue(scheduledMusic, "Music event must enqueue.")

        // 2. Spotify (lower priority) arrives while Music is pending
        let scheduledSpotify = coalescer.enqueue(spotifyEvent, shouldOverwrite: { existing, new in
            let existingPriority = PlayerTakeoverPolicy.priorityIndex(for: existing.bundleIdentifier, priority: priority)
            let newPriority = PlayerTakeoverPolicy.priorityIndex(for: new.bundleIdentifier, priority: priority)
            return newPriority <= existingPriority
        })
        XCTAssertFalse(scheduledSpotify, "Lower priority Spotify must be rejected under lock and not overwrite pending Music.")

        // 3. Queue must preserve Music Track
        let drained = coalescer.takeNext()
        XCTAssertEqual(drained?.title, "Music Track", "Music event must survive and be consumed.")
    }

    func testTemporaryLockDecisionRejectsMismatchAndClearsPreviousTrack() {
        let lockBundleID = PlayerProfile.appleMusic.bundleIdentifier
        let incomingSpotifyBundleID = "com.spotify.client"

        var clearedNowPlaying = false
        func checkAcceptance(incomingBundleID: String) -> Bool {
            if incomingBundleID != lockBundleID {
                clearedNowPlaying = true
                return false
            }
            return true
        }

        let accepted = checkAcceptance(incomingBundleID: incomingSpotifyBundleID)
        XCTAssertFalse(accepted, "Incoming Spotify must be rejected when Music is temporarily locked.")
        XCTAssertTrue(clearedNowPlaying, "Temporary lock mismatch must clear now playing track.")
    }

    func testRapidEventsDuringActiveDrainDoNotScheduleRedundantWorkItems() {
        final class TestEvent {
            let id: Int
            init(_ id: Int) { self.id = id }
        }

        let coalescer = PendingTrackEventCoalescer<TestEvent>()

        // 1. Initial event arrives, schedules drain
        let scheduledFirst = coalescer.enqueue(TestEvent(0))
        XCTAssertTrue(scheduledFirst, "Initial event must schedule drain.")

        // 2. Worker thread starts draining: pops event 0
        var actionsProcessed = [Int]()
        var drainTurnsScheduled = 0

        while let action = coalescer.takeNextAction() {
            if let event = action.event {
                actionsProcessed.append(event.id)
            }

            // Simulate 128 rapid events arriving while this drain iteration is executing
            if actionsProcessed.count == 1 {
                for i in 1...128 {
                    let scheduled = coalescer.enqueue(TestEvent(i))
                    if scheduled {
                        drainTurnsScheduled += 1
                    }
                }
            }
        }

        // 3. Exactly 0 redundant drain turns should have been scheduled during the active loop
        XCTAssertEqual(drainTurnsScheduled, 0, "Rapid events during active drain loop must NOT schedule redundant GCD turns.")

        // The while loop must have processed event 0 and then the latest coalesced event 128
        XCTAssertEqual(actionsProcessed, [0, 128], "While loop should take the latest coalesced event.")

        // 4. Once fully drained, a new event must be able to schedule drain again
        let scheduledAfterDrain = coalescer.enqueue(TestEvent(999))
        XCTAssertTrue(scheduledAfterDrain, "New event after drain loop completed must schedule drain.")
    }

    func testTemporaryLockRejectionEnqueuesClearInSameQueuePreservingCausalOrder() {
        struct MockEvent: Equatable {
            let title: String
        }

        let coalescer = PendingTrackEventCoalescer<MockEvent>()

        // Scenario A: Music is pending in queue, then Spotify (mismatch) triggers enqueueClear()
        _ = coalescer.enqueue(MockEvent(title: "Music Track"))
        _ = coalescer.enqueueClear()

        // Strict causal order: clear supersedes earlier pending Music
        guard let actionA = coalescer.takeNextAction() else {
            XCTFail("Action must be present")
            return
        }
        XCTAssertTrue(actionA.includesClear)
        XCTAssertNil(actionA.event, "Music event must be cleared and not run after clear.")
        XCTAssertNil(coalescer.takeNextAction())

        // Scenario B: Spotify triggers enqueueClear() first, then Music is enqueued
        _ = coalescer.enqueueClear()
        _ = coalescer.enqueue(MockEvent(title: "Music Track"))

        guard let actionB = coalescer.takeNextAction() else {
            XCTFail("Action must be present")
            return
        }
        switch actionB {
        case .clearThenEvent(let event):
            XCTAssertEqual(event.title, "Music Track", "Clear must execute before Music event, not resurrect old state.")
        default:
            XCTFail("Expected clearThenEvent, got \(actionB)")
        }
    }

    func testCoalescedPauseAndResumePreservesResumeState() {
        struct MockQueuedEvent {
            let trackID: String
            let isPlaying: Bool
            var hasResumedFromPause: Bool = false
        }

        let coalescer = PendingTrackEventCoalescer<MockQueuedEvent>()

        let pauseEvent = MockQueuedEvent(trackID: "song1", isPlaying: false, hasResumedFromPause: false)
        let resumeEvent = MockQueuedEvent(trackID: "song1", isPlaying: true, hasResumedFromPause: false)

        // 1. Pause arrives while queue is busy
        _ = coalescer.enqueue(pauseEvent)

        // 2. Resume arrives before pause is drained
        _ = coalescer.enqueue(
            resumeEvent,
            merge: { existing, new in
                let isSameTrack = existing.trackID == new.trackID
                let resumed = isSameTrack && (
                    existing.hasResumedFromPause ||
                    (existing.isPlaying == false && new.isPlaying != false)
                )
                return MockQueuedEvent(
                    trackID: new.trackID,
                    isPlaying: new.isPlaying,
                    hasResumedFromPause: resumed
                )
            }
        )

        // 3. Popping action must have hasResumedFromPause == true
        guard let action = coalescer.takeNextAction(), let event = action.event else {
            XCTFail("Coalesced event must be present")
            return
        }
        XCTAssertTrue(event.isPlaying)
        XCTAssertTrue(event.hasResumedFromPause, "Coalescing pause and resume must preserve hasResumedFromPause.")
    }

    func testSameTrackNotificationResetsDetectionBaselineAllowingRevalidationPastWindow() {
        let trackStart = Date(timeIntervalSince1970: 1000)
        let settlingPassed = trackStart.addingTimeInterval(12.0) // 12 seconds in
        let lastQuery = trackStart.addingTimeInterval(1.0)

        // Without resetting trackStartedAt, revalidation and polling are blocked at t = 12s
        let blockedRevalidation = AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
            lastQueriedAt: lastQuery,
            now: settlingPassed,
            trackStartedAt: trackStart,
            isTrackLocked: true
        )
        XCTAssertFalse(blockedRevalidation, "Without baseline reset, revalidation is blocked after 8s.")

        let blockedPolling = SteadyStatePollingPolicy.shouldPollTrack(
            hasCurrentTrack: true,
            isTrackLocked: true,
            isDeviceMatched: true,
            hasPendingCandidate: false,
            appleMusicState: .resolved(44_100),
            trackStartedAt: trackStart,
            now: settlingPassed
        )
        XCTAssertFalse(blockedPolling, "Without baseline reset, steady-state polling is blocked after 8s.")

        // When a new same-track notification arrives at 12s, baseline is re-anchored to t = 12s
        let updatedBaseline = settlingPassed
        let allowedRevalidation = AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
            lastQueriedAt: lastQuery,
            now: settlingPassed,
            trackStartedAt: updatedBaseline,
            isTrackLocked: true
        )
        XCTAssertTrue(allowedRevalidation, "Re-anchored baseline at 12s allows revalidation for late-arriving format changes.")

        let allowedPolling = SteadyStatePollingPolicy.shouldPollTrack(
            hasCurrentTrack: true,
            isTrackLocked: true,
            isDeviceMatched: true,
            hasPendingCandidate: false,
            appleMusicState: .waiting,
            trackStartedAt: updatedBaseline,
            now: settlingPassed.addingTimeInterval(1.0)
        )
        XCTAssertTrue(allowedPolling, "Re-anchored baseline at 12s with .waiting state enables steady-state polling.")
    }

    func testSameTrackNotificationPreservesPlaybackStartTimeSoAtmosEvidenceDoesNotExpire() {
        let playbackStartedAt = Date(timeIntervalSince1970: 100.0)
        let trackID = "atmos-song"
        let trackTitle = "Spatial Audio Song"

        let atmosStat = CMPlayerStats(
            sampleRate: 48_000,
            bitDepth: 24,
            date: Date(timeIntervalSince1970: 100.5), // arrived at t + 0.5s
            isAppleMusicFormat: true,
            isDolbyAtmos: true,
            trackIdentifier: trackID
        )

        // 1. Initial check: Atmos evidence is fresh relative to playbackStartedAt
        let initialOverride = AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
            formatEvidence: atmosStat,
            expectedTrackID: trackID,
            expectedTrackTitle: trackTitle,
            trackStartedAt: playbackStartedAt
        )
        XCTAssertTrue(initialOverride, "Atmos log timestamped after playbackStartedAt must be valid.")

        let initialEffectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 96_000,
            decoderEvidence: nil,
            formatEvidence: atmosStat,
            trackStartedAt: playbackStartedAt,
            expectedTrackID: trackID,
            expectedTrackTitle: trackTitle
        )
        XCTAssertEqual(initialEffectiveRate, 48_000, "Atmos 48 kHz takes precedence over AppleScript 96 kHz.")

        // 2. At t = 112.0s (12s later), a same-track metadata notification arrives
        let sameTrackNotificationAt = Date(timeIntervalSince1970: 112.0)
        let requeryStartedAt = sameTrackNotificationAt

        // Playback start time remains playbackStartedAt (100.0s), NOT overwritten by requeryStartedAt (112.0s)
        let overrideAfterMetadataUpdate = AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
            formatEvidence: atmosStat,
            expectedTrackID: trackID,
            expectedTrackTitle: trackTitle,
            trackStartedAt: playbackStartedAt
        )
        XCTAssertTrue(overrideAfterMetadataUpdate, "Atmos evidence must NOT expire when same-track metadata notification arrives.")

        let effectiveRateAfterMetadataUpdate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: 96_000,
            decoderEvidence: nil,
            formatEvidence: atmosStat,
            trackStartedAt: playbackStartedAt,
            expectedTrackID: trackID,
            expectedTrackTitle: trackTitle
        )
        XCTAssertEqual(effectiveRateAfterMetadataUpdate, 48_000, "Effective rate must keep Atmos 48 kHz instead of reverting to 96 kHz.")

        // Negative check: If trackStartedAt had been overwritten with 112.0s, Atmos log at 100.5s would be rejected
        let wronglyOverwrittenOverride = AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
            formatEvidence: atmosStat,
            expectedTrackID: trackID,
            expectedTrackTitle: trackTitle,
            trackStartedAt: requeryStartedAt
        )
        XCTAssertFalse(wronglyOverwrittenOverride, "Overwriting trackStartedAt with requeryStartedAt would wrongly drop Atmos evidence.")

        // 3. Re-query window uses requeryStartedAt, allowing revalidation within its bounded window
        let allowsRevalidation = AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
            lastQueriedAt: Date(timeIntervalSince1970: 101.0),
            now: sameTrackNotificationAt,
            trackStartedAt: requeryStartedAt,
            isTrackLocked: true
        )
        XCTAssertTrue(allowsRevalidation, "Re-query window is active based on requeryStartedAt.")
    }

    func testPlayerPriorityChangeResetsArbitrationWithoutClearingNowPlayingTrack() {
        struct MockQueueTrack: Equatable {
            let title: String
        }

        let coalescer = PendingTrackEventCoalescer<MockQueueTrack>()

        // 1. Standalone priority change enqueues resetArbitration
        let scheduled = coalescer.enqueueResetArbitration()
        XCTAssertTrue(scheduled, "Reset arbitration should schedule drain.")

        guard let action = coalescer.takeNextAction() else {
            XCTFail("Action must be present.")
            return
        }
        XCTAssertTrue(action.includesResetArbitration, "Action must be resetArbitration.")
        XCTAssertFalse(action.includesClear, "Resetting player arbitration MUST NOT clear now-playing track.")
        XCTAssertNil(action.event)
        XCTAssertNil(coalescer.takeNextAction())

        // 2. Pending event followed by resetArbitration: preserves event under new arbitration
        _ = coalescer.enqueue(MockQueueTrack(title: "Music Track"))
        _ = coalescer.enqueueResetArbitration()

        guard let actionWithEvent = coalescer.takeNextAction() else {
            XCTFail("Action must be present.")
            return
        }
        XCTAssertTrue(actionWithEvent.includesResetArbitration)
        XCTAssertFalse(actionWithEvent.includesClear, "Arbitration reset with pending event must not clear now playing track.")
        XCTAssertEqual(actionWithEvent.event?.title, "Music Track", "Pending event must be preserved.")
        XCTAssertNil(coalescer.takeNextAction())

        // 3. Explicit clear still works when required (e.g. temporary lock mismatch)
        _ = coalescer.enqueue(MockQueueTrack(title: "Spotify Track"))
        _ = coalescer.enqueueClear()

        guard let clearAction = coalescer.takeNextAction() else {
            XCTFail("Clear action must be present.")
            return
        }
        XCTAssertTrue(clearAction.includesClear, "Explicit clear must still clear now playing track.")
        XCTAssertNil(clearAction.event)
    }

}
