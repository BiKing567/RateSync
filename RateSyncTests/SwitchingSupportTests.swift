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

    func testAppleMusicHighLevelFormatUsesShortEvidenceGate() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicFormatLog)

        XCTAssertEqual(policy.boundary, 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.stability, 0.6, accuracy: 0.001)
        XCTAssertEqual(policy.lockedOverride, 2.0, accuracy: 0.001)
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
                currentIsDolbyAtmos: true,
                incomingIsDolbyAtmos: false
            )
        )
        XCTAssertTrue(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsDolbyAtmos: false,
                incomingIsDolbyAtmos: true
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

        XCTAssertEqual(paths, [RateSyncWidgetConfiguration.localWidgetStateURL.path])
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

    func testPlayerPriorityMenuTitleIncludesPlayerNameAfterOrderNumber() {
        XCTAssertEqual(
            MenuLabelPolicy.playerPriorityTitle(index: 1, localizedName: "Apple Music"),
            "1. Apple Music",
            "Player priority rows must show the player name instead of only the order number."
        )
    }
}
