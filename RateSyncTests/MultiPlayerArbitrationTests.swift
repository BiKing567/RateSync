//
//  MultiPlayerArbitrationTests.swift
//  RateSyncTests
//
//  Created by Vincent Neo on 1/5/22.
//

import XCTest
import CoreAudio

final class MultiPlayerArbitrationTests: XCTestCase {

    let controlledDeviceID: AudioObjectID = 128
    let otherDeviceID: AudioObjectID = 99

    // MARK: - Process Filtering & Deduplication

    func testDeduplicatesMultipleProcessesForSamePlayer() {
        let processes = [
            AudioProcessSnapshot(
                pid: 101,
                bundleIdentifier: "com.spotify.client",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            ),
            AudioProcessSnapshot(
                pid: 102,
                bundleIdentifier: "com.spotify.client",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            )
        ]

        let result = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: controlledDeviceID
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.contains("com.spotify.client"))
    }

    func testIgnoresNonRegisteredProcesses() {
        let processes = [
            AudioProcessSnapshot(
                pid: 201,
                bundleIdentifier: "com.apple.Safari",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            ),
            AudioProcessSnapshot(
                pid: 202,
                bundleIdentifier: "com.google.Chrome",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            ),
            AudioProcessSnapshot(
                pid: 203,
                bundleIdentifier: "com.apple.systemsoundserverd",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            )
        ]

        let result = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: controlledDeviceID
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testIgnoresProcessesOutputtingToOtherDevices() {
        let processes = [
            AudioProcessSnapshot(
                pid: 301,
                bundleIdentifier: "com.apple.Music",
                isRunningOutput: true,
                outputDeviceIDs: [otherDeviceID] // Outputting to headphones, not controlled DAC
            ),
            AudioProcessSnapshot(
                pid: 302,
                bundleIdentifier: "com.spotify.client",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID]
            )
        ]

        let result = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: controlledDeviceID
        )

        XCTAssertEqual(result, ["com.spotify.client"])
    }

    func testIgnoresProcessesNotRunningOutput() {
        let processes = [
            AudioProcessSnapshot(
                pid: 401,
                bundleIdentifier: "com.apple.Music",
                isRunningOutput: false,
                outputDeviceIDs: [controlledDeviceID]
            )
        ]

        let result = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: controlledDeviceID
        )

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Arbitration Actions

    func testNoRegisteredPlayerPlayingKeepsCurrent() {
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: [],
            playbackStatuses: [:],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: false
        )

        if case .keepCurrent = action {
            // Success
        } else {
            XCTFail("Expected .keepCurrent but got \(action)")
        }
    }

    func testSinglePlayerPlayingFollowsSinglePlayerMode() {
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music"],
            playbackStatuses: ["com.apple.Music": .playing],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: false
        )

        XCTAssertEqual(
            action,
            .singlePlayer(bundleIdentifier: "com.apple.Music", isTransitionFromMultiPlayer: false)
        )
    }

    func testPausedPlayerWithRunningStreamDoesNotCountAsPlaying() {
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.spotify.client"],
            playbackStatuses: ["com.spotify.client": .paused],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: false
        )

        if case .keepCurrent = action {
            // Paused player means 0 active playing players -> keep current rate, no extra switch.
        } else {
            XCTFail("Expected .keepCurrent when player is paused, got \(action)")
        }
    }

    func testTwoPlayersPlayingSwitchesTo48kHzWhenSupported() {
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .playing,
                "com.spotify.client": .playing
            ],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: false
        )

        XCTAssertEqual(
            action,
            .multiPlayerConflict(targetRate: 48_000, isSupportedByDevice: true)
        )
    }

    func testTwoPlayersPlayingPreservesFormatWhenDeviceLacks48kHz() {
        // Device only supports 44.1, 88.2, 96 kHz (no 48 kHz support)
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .playing,
                "com.spotify.client": .playing
            ],
            supportedSampleRates: [44_100, 88_200, 96_000],
            previousWasMultiPlayer: false
        )

        XCTAssertEqual(
            action,
            .multiPlayerConflict(targetRate: 48_000, isSupportedByDevice: false)
        )
    }

    func testUnknownPlaybackStatePreservesCurrentFormat() {
        // Player output is active but state cannot be determined -> wait for confirmation, keep current format
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.tencent.QQMusicMac"],
            playbackStatuses: ["com.tencent.QQMusicMac": .unknown],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: false
        )

        if case .keepCurrent(let reason) = action {
            XCTAssertTrue(reason.contains("cannot be determined"))
        } else {
            XCTFail("Expected .keepCurrent when state cannot be read, got \(action)")
        }
    }

    func testTransitionFromMultipleToSingleSignalsReevaluation() {
        // Apple Music and Spotify were both playing; now Spotify paused.
        let action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .playing,
                "com.spotify.client": .paused
            ],
            supportedSampleRates: [44_100, 48_000, 96_000],
            previousWasMultiPlayer: true
        )

        XCTAssertEqual(
            action,
            .singlePlayer(bundleIdentifier: "com.apple.Music", isTransitionFromMultiPlayer: true)
        )
    }

    // MARK: - Full End-to-End Acceptance Scenario

    func testCompleteAcceptanceScenario() {
        let supportedRates: [Double] = [44_100, 48_000, 88_200, 96_000, 192_000]

        // 1. Apple Music plays 96 kHz
        var step1Action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music"],
            playbackStatuses: ["com.apple.Music": .playing],
            supportedSampleRates: supportedRates,
            previousWasMultiPlayer: false
        )
        XCTAssertEqual(step1Action, .singlePlayer(bundleIdentifier: "com.apple.Music", isTransitionFromMultiPlayer: false))

        // 2. Spotify joins playing -> 2 players active -> output switches to 48 kHz
        var step2Action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .playing,
                "com.spotify.client": .playing
            ],
            supportedSampleRates: supportedRates,
            previousWasMultiPlayer: false
        )
        XCTAssertEqual(step2Action, .multiPlayerConflict(targetRate: 48_000, isSupportedByDevice: true))

        // 3. Pause Spotify -> Apple Music remains -> immediate match back to 96 kHz without song change
        var step3Action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .playing,
                "com.spotify.client": .paused
            ],
            supportedSampleRates: supportedRates,
            previousWasMultiPlayer: true
        )
        XCTAssertEqual(step3Action, .singlePlayer(bundleIdentifier: "com.apple.Music", isTransitionFromMultiPlayer: true))

        // 4. Both pause -> 0 players playing -> keep current format (96 kHz preserved, no extra switch)
        var step4Action = MultiPlayerArbitrationPolicy.evaluate(
            activeOutputPlayers: ["com.apple.Music", "com.spotify.client"],
            playbackStatuses: [
                "com.apple.Music": .paused,
                "com.spotify.client": .paused
            ],
            supportedSampleRates: supportedRates,
            previousWasMultiPlayer: false
        )
        if case .keepCurrent = step4Action {
            // Preserves 96 kHz
        } else {
            XCTFail("Step 4: expected .keepCurrent when both paused, got \(step4Action)")
        }
    }

    // MARK: - Regression Tests for Arbitration Call Chain (P1 & P2s)

    /// [P1] Multiple evaluations within the 1-second stabilization window must not cancel
    /// the running stabilization timer or leave the device stuck at previous sample rate.
    func testP1_RepeatedEvaluationsWithinStabilizationWindowDoNotInvalidateTimer() {
        let tracker = MultiPlayerArbitrationTracker()

        // 1. Initial detection of multi-player conflict
        let q1 = tracker.beginQuery()
        XCTAssertEqual(q1, 1)

        // Conflict confirmed by first query -> schedules timer at version 1
        let (firstScheduled, v1) = tracker.scheduleStabilization(targetRate: 48_000)
        XCTAssertTrue(firstScheduled, "First conflict evaluation must schedule a stabilization timer")
        XCTAssertTrue(tracker.isStabilizationScheduled)
        XCTAssertEqual(v1, 1)

        // 2. Second evaluation occurs within 1 second (e.g. at 300ms)
        let q2 = tracker.beginQuery()
        XCTAssertEqual(q2, 2)

        // Late result from q1 arrives after q2 started -> discarded as stale
        XCTAssertFalse(tracker.isQueryResultValid(queryGen: q1))

        // q2 result arrives -> valid
        XCTAssertTrue(tracker.isQueryResultValid(queryGen: q2))

        // Duplicate conflict confirmation must NOT reschedule or cancel running timer
        let (secondScheduled, v2) = tracker.scheduleStabilization(targetRate: 48_000)
        XCTAssertFalse(secondScheduled, "Duplicate confirmation must not start a second timer")
        XCTAssertTrue(tracker.isStabilizationScheduled, "Existing stabilization timer must remain active")
        XCTAssertEqual(v1, v2, "State version must not change on duplicate conflict confirmation")

        // 3. Stabilization timer fires after delay
        let activePlayers: Set<String> = ["com.apple.Music", "com.spotify.client"]
        let canCommit = tracker.canCommitStabilization(timerVersion: v1, activeOutputPlayers: activePlayers)
        XCTAssertTrue(canCommit, "Stabilization timer must be valid to commit when active players >= 2")

        let committed = tracker.commitStabilization(timerVersion: v1)
        XCTAssertTrue(committed)
        XCTAssertTrue(tracker.isConflictActive)
        XCTAssertFalse(tracker.isStabilizationScheduled, "Stabilization flag must be cleared on execution")
    }

    /// [P2-New] Pause or state change cancels stabilization, advances stateVersion,
    /// and rejects any delayed timer callbacks.
    func testP2_PauseOrStateChangeAdvancesStateVersionAndRejectsPreviousTimer() {
        let tracker = MultiPlayerArbitrationTracker()

        // 1. Conflict scheduled at version 1
        let (scheduled, v1) = tracker.scheduleStabilization(targetRate: 48_000)
        XCTAssertTrue(scheduled)
        XCTAssertEqual(v1, 1)

        // 2. Player reports pause -> cancels stabilization and advances stateVersion
        tracker.cancelStabilization(reason: "player paused")
        XCTAssertFalse(tracker.isStabilizationScheduled)
        XCTAssertEqual(tracker.stateVersion, 2, "cancelStabilization must bump stateVersion")

        // 3. Delayed timer callback for version 1 attempts commit -> must be rejected
        let activePlayers: Set<String> = ["com.apple.Music", "com.spotify.client"]
        let canCommit = tracker.canCommitStabilization(timerVersion: v1, activeOutputPlayers: activePlayers)
        XCTAssertFalse(canCommit, "Stale timer version must be rejected by canCommitStabilization")

        let committed = tracker.commitStabilization(timerVersion: v1)
        XCTAssertFalse(committed, "commitStabilization must fail for stale timer version")
        XCTAssertFalse(tracker.isConflictActive)
    }

    /// [P2-New] Stabilization timer expiration must abort if a player has reported pause/stop
    /// even if Core Audio process output stream hasn't closed yet.
    func testP2_StabilizationTimerAbortsWhenPlayerReportsPauseWhileAudioStreamStillRunning() {
        let tracker = MultiPlayerArbitrationTracker()

        // 1. Conflict scheduled at version 1
        let (scheduled, v1) = tracker.scheduleStabilization(targetRate: 48_000)
        XCTAssertTrue(scheduled)

        // 2. CoreAudio still reports 2 audio streams (buffer draining):
        let activeStreams: Set<String> = ["com.apple.Music", "com.spotify.client"]

        // But Spotify has already reported pause in its playback record:
        let records: [String: PlayerPlaybackRecordSnapshot] = [
            "com.apple.Music": PlayerPlaybackRecordSnapshot(bundleIdentifier: "com.apple.Music", isPlaying: true),
            "com.spotify.client": PlayerPlaybackRecordSnapshot(bundleIdentifier: "com.spotify.client", isPlaying: false)
        ]

        // 3. Timer checks eligibility before committing:
        let canCommit = tracker.canCommitStabilization(
            timerVersion: v1,
            activeOutputPlayers: activeStreams,
            records: records
        )
        XCTAssertFalse(canCommit, "Must not commit 48 kHz when an active output player has reported isPlaying == false")

        // Once cancelled, conflict is not active
        tracker.cancelStabilization(reason: "condition not met")
        XCTAssertFalse(tracker.isConflictActive)
    }

    /// [P2-New] Unsupported 48 kHz DAC must not leave conflict marked active,
    /// and subsequent switch to a supported DAC must properly trigger 48 kHz stabilization.
    func testP2_UnsupportedRateDoesNotLeaveConflictActiveAndAllowsNewDACSwitch() {
        let tracker = MultiPlayerArbitrationTracker()
        let initialPlayers: Set<String> = ["com.apple.Music", "com.spotify.client"]

        // 1. Initial detection of conflict on DAC 1 (unsupported 48 kHz)
        let (scheduled1, v1) = tracker.scheduleStabilization(targetRate: 48_000, players: initialPlayers)
        XCTAssertTrue(scheduled1)

        // Timer fires for DAC 1, but device does not support 48 kHz
        let canCommit1 = tracker.canCommitStabilization(timerVersion: v1, activeOutputPlayers: initialPlayers)
        XCTAssertTrue(canCommit1)

        // Ending stabilization timer:
        tracker.endStabilizationTimer(timerVersion: v1)
        // Device write fails or is unsupported -> must reset conflict:
        tracker.resetConflict()
        XCTAssertFalse(tracker.isConflictActive, "isConflictActive must remain false when DAC rejects/lacks 48 kHz")

        // 2. User switches to DAC 2 which supports 48 kHz
        // New DAC must NOT be rejected by a stale isConflictActive flag!
        let (scheduled2, v2) = tracker.scheduleStabilization(targetRate: 48_000, players: initialPlayers)
        XCTAssertTrue(scheduled2, "New DAC supporting 48 kHz must successfully schedule stabilization")
        XCTAssertEqual(v2, tracker.stateVersion)

        // DAC 2 timer fires and succeeds:
        let canCommit2 = tracker.canCommitStabilization(timerVersion: v2, activeOutputPlayers: initialPlayers)
        XCTAssertTrue(canCommit2)
        tracker.endStabilizationTimer(timerVersion: v2)
        tracker.markConflictActive()
        XCTAssertTrue(tracker.isConflictActive, "isConflictActive should only be set after verified write")
    }

    /// [P2-New] Playback member set change during stabilization waiting window must invalidate
    /// old timer and reject commit for the unconfirmed player set.
    func testP2_ActivePlayerMemberChangeInvalidatesStabilizationAndRejectsStaleSet() {
        let tracker = MultiPlayerArbitrationTracker()
        let initialPlayers: Set<String> = ["com.apple.Music", "com.spotify.client"]

        // 1. Stabilization scheduled for Music + Spotify
        let (scheduled, v1) = tracker.scheduleStabilization(targetRate: 48_000, players: initialPlayers)
        XCTAssertTrue(scheduled)
        XCTAssertEqual(v1, 1)

        // 2. While waiting, Spotify drops out and QQ Music joins
        let changedPlayers: Set<String> = ["com.apple.Music", "com.tencent.QQMusicMac"]
        let memberChanged = tracker.updateActiveOutputPlayers(changedPlayers)
        XCTAssertTrue(memberChanged)
        XCTAssertFalse(tracker.isStabilizationScheduled, "Member change must cancel waiting stabilization")
        XCTAssertEqual(tracker.stateVersion, 2, "Member change must advance stateVersion")

        // 3. Delayed timer callback for version 1 attempts commit for the changed players -> rejected!
        let canCommit = tracker.canCommitStabilization(timerVersion: v1, activeOutputPlayers: changedPlayers)
        XCTAssertFalse(canCommit, "Must not commit 48 kHz when active players mismatch scheduled players")

        let timerEnded = tracker.endStabilizationTimer(timerVersion: v1)
        XCTAssertFalse(timerEnded)
        XCTAssertFalse(tracker.isConflictActive)

        // 4. Also verify scheduleStabilization with a changed set cancels old and reschedules
        let (rescheduled1, v3) = tracker.scheduleStabilization(targetRate: 48_000, players: initialPlayers)
        XCTAssertTrue(rescheduled1)

        // Duplicate call with SAME set does not reschedule:
        let (duplicate, _) = tracker.scheduleStabilization(targetRate: 48_000, players: initialPlayers)
        XCTAssertFalse(duplicate, "Duplicate call with same player set must not reschedule")

        // Call with DIFFERENT set reschedules with new version:
        let (rescheduled2, v5) = tracker.scheduleStabilization(targetRate: 48_000, players: changedPlayers)
        XCTAssertTrue(rescheduled2, "Call with different player set must reschedule fresh window")
        XCTAssertNotEqual(v3, v5)
        XCTAssertEqual(tracker.scheduledPlayers, changedPlayers)
    }

    /// [P2-2] Track events from players outputting to another audio device must be rejected
    /// before initiating format recognition, preventing them from hijacking the controlled DAC.
    func testP2_OtherDevicePlayerDoesNotHijackControlledDevice() {
        let processes = [
            AudioProcessSnapshot(
                pid: 1001,
                bundleIdentifier: "com.spotify.client",
                isRunningOutput: true,
                outputDeviceIDs: [controlledDeviceID] // Playing to DAC
            ),
            AudioProcessSnapshot(
                pid: 1002,
                bundleIdentifier: "com.apple.Music",
                isRunningOutput: true,
                outputDeviceIDs: [otherDeviceID] // Playing to AirPods
            )
        ]

        // Spotify on controlled DAC must be accepted
        let acceptSpotify = MultiPlayerArbitrationPolicy.shouldAcceptTrackEvent(
            forControlledDeviceID: controlledDeviceID,
            playerBundleIdentifier: "com.spotify.client",
            processes: processes
        )
        XCTAssertTrue(acceptSpotify)

        // Apple Music on AirPods must be rejected for the controlled DAC
        let acceptAppleMusic = MultiPlayerArbitrationPolicy.shouldAcceptTrackEvent(
            forControlledDeviceID: controlledDeviceID,
            playerBundleIdentifier: "com.apple.Music",
            processes: processes
        )
        XCTAssertFalse(acceptAppleMusic, "Apple Music event from another device must not be accepted for controlled DAC")

        // Controlled device active players should contain only Spotify
        let activePlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: controlledDeviceID
        )
        XCTAssertEqual(activePlayers, ["com.spotify.client"])
    }

    /// [P2-3] When all playback processes stop, in-flight queries must be invalidated upfront
    /// so delayed query returns cannot switch output to 48 kHz.
    func testP2_InFlightQueryInvalidatedWhenProcessesBecomeEmpty() {
        let tracker = MultiPlayerArbitrationTracker()

        // 1. Query dispatched
        let queryGen = tracker.beginQuery()
        XCTAssertEqual(queryGen, 1)

        // 2. Both players stop playback -> empty active processes
        tracker.handleEmptyProcesses()
        XCTAssertFalse(tracker.isStabilizationScheduled)
        XCTAssertFalse(tracker.isConflictActive)

        // 3. Delayed async query result arrives -> must be rejected
        let isValid = tracker.isQueryResultValid(queryGen: queryGen)
        XCTAssertFalse(isValid, "Delayed query result must be rejected after empty processes event")
    }

    /// [P2-4] Playback cache must validate PID identity, launchDate, and freshness TTL.
    /// Mismatched PID, stale age, or pre-launch date must return invalid (triggering .unknown).
    func testP2_PlaybackRecordValidation_PIDMismatchAndStaleCache() {
        let now = Date()
        let appLaunchDate = now.addingTimeInterval(-60) // App launched 1 min ago

        // 1. Fresh, matching PID, after launch date -> valid
        let valid = PlayerPlaybackRecordValidator.isValid(
            recordPID: 2001,
            recordTimestamp: now.addingTimeInterval(-2), // 2s old
            activeProcessPIDs: [2001],
            appProcessID: 2001,
            appLaunchDate: appLaunchDate,
            now: now,
            maxFreshness: 15.0
        )
        XCTAssertTrue(valid)

        // 2. Stale cache (>15s old) -> invalid
        let stale = PlayerPlaybackRecordValidator.isValid(
            recordPID: 2001,
            recordTimestamp: now.addingTimeInterval(-20), // 20s old
            activeProcessPIDs: [2001],
            appProcessID: 2001,
            appLaunchDate: appLaunchDate,
            now: now,
            maxFreshness: 15.0
        )
        XCTAssertFalse(stale, "Record older than maxFreshness must be rejected")

        // 3. PID mismatch (app restarted with PID 2002, record has old PID 2001) -> invalid
        let pidMismatch = PlayerPlaybackRecordValidator.isValid(
            recordPID: 2001,
            recordTimestamp: now.addingTimeInterval(-1),
            activeProcessPIDs: [2002],
            appProcessID: 2002,
            appLaunchDate: appLaunchDate,
            now: now,
            maxFreshness: 15.0
        )
        XCTAssertFalse(pidMismatch, "Mismatched PID must be rejected")

        // 4. Record predates application launch date -> invalid
        let preLaunch = PlayerPlaybackRecordValidator.isValid(
            recordPID: 2001,
            recordTimestamp: appLaunchDate.addingTimeInterval(-10), // Captured before current app launched
            activeProcessPIDs: [2001],
            appProcessID: 2001,
            appLaunchDate: appLaunchDate,
            now: now,
            maxFreshness: 15.0
        )
        XCTAssertFalse(preLaunch, "Record predating app launch must be rejected")
    }

    /// [P2-5] Device hardware verification: if setNominalSampleRate fails or readback
    /// nominal rate does not match target, verification must fail and prevent reporting success.
    func testP2_HardwareVerificationRejectionDoesNotPublishTargetRate() {
        // Driver setNominalSampleRate returns false
        let setFailed = DeviceFormatVerification.isSampleRateApplied(
            targetRate: 48_000,
            nominalRate: 96_000,
            rateSetOk: false
        )
        XCTAssertFalse(setFailed, "Failed setNominalSampleRate must not report success")

        // Driver returned true, but hardware silently kept 96 kHz
        let silentReject = DeviceFormatVerification.isSampleRateApplied(
            targetRate: 48_000,
            nominalRate: 96_000,
            rateSetOk: true
        )
        XCTAssertFalse(silentReject, "Readback nominal rate mismatch must reject application")

        // Driver returned true and nominal rate read back as 48 kHz
        let applied = DeviceFormatVerification.isSampleRateApplied(
            targetRate: 48_000,
            nominalRate: 48_000,
            rateSetOk: true
        )
        XCTAssertTrue(applied, "Matching confirmed nominal rate must succeed")
    }
}
