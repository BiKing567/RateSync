//
//  OutputDevices+Arbitration.swift
//  Quality
//

import Foundation
import CoreAudio
import SimplyCoreAudio
import OSLog
import WidgetKit
import MediaRemoteAdapter

extension OutputDevices {
    // MARK: - Multi-Player Arbitration & Stabilization

    func recordPlayerTrackInfo(_ trackInfo: TrackInfo, bundleIdentifier: String?, recordedAt: Date = Date()) {
        guard let bundleID = bundleIdentifier ?? trackInfo.payload.bundleIdentifier else { return }
        let record = PlayerTrackRecord(
            trackInfo: trackInfo,
            bundleIdentifier: bundleID,
            processID: trackInfo.payload.PID,
            recordedAt: recordedAt
        )
        processQueue.async { [weak self] in
            self?.latestPlayerRecords[bundleID] = record
        }
    }

    func handlePlayerPauseOrStop(_ trackInfo: TrackInfo, eventDate: Date?) {
        // Invalidate current single-track generation & pending candidate so in-flight queries are discarded
        self.cancelRetryTimer()
        self.currentTrackGeneration &+= 1
        self.pendingCandidate = nil

        let newMediaTrack = MediaTrack(trackInfo: trackInfo)
        let trackChanged = (self.currentTrack != newMediaTrack)

        let isAppleMusic = (trackInfo.payload.bundleIdentifier ?? self.currentTrack.flatMap { Self.resolveBundleIdentifier(track: $0) }) == PlayerProfile.appleMusic.bundleIdentifier
        if isAppleMusic {
            self.appleMusic.invalidatePlaybackStateCache()
            self.appleMusicSampleRateState = .notPlaying
            self.appleMusicSampleRateWaitStartedAt = nil
            self.appleMusicSampleRateQueryID &+= 1
            self.appleMusicResumeRetryWorkItem?.cancel()
            self.appleMusicResumeRetryWorkItem = nil
            self.appleMusicResumeCheckAttempts = 0
            self.appleMusicRecoveryWorkItem?.cancel()
            self.appleMusicRecoveryWorkItem = nil
            self.appleMusicRecoveryAttempts = 0
            let isConfirmed = self.hasConfirmedTrackFormat(for: newMediaTrack)
            if trackChanged || !isConfirmed {
                self.appleMusicLastKnownCurrentTrackSampleRate = nil
                self.appleMusicFormatEvidence = nil
                self.appleMusicDecoderFormatEvidence = nil
                self.appleMusicFallbackFormat = nil
                self.appleMusicFallbackAttemptedForTrack = false
                self.appleMusicAtmosProbeScheduledGeneration = nil
                self.appleMusicAtmosProbeCompletedGeneration = nil
                self.appleMusicAtmosProbeLastCompletedAt = nil
            }
        } else {
            self.formatProbeBudget.setPaused(true)
        }

        if trackChanged, let bundleID = trackInfo.payload.bundleIdentifier {
            let receivedAt = eventDate ?? Date()
            self.trackStartedAtByPlayer[bundleID] = receivedAt
            self.lastTrackChangeDatesByPlayer[bundleID] = receivedAt.addingTimeInterval(-0.5)
        }

        // Update widget metadata on pause if needed without triggering format switches
        self.previousTrack = self.currentTrack
        self.currentTrack = newMediaTrack
        let sharedTrack = RateSyncWidgetConfiguration.loadNowPlayingTrack()
        let widgetMetadataChanged = sharedTrack?.title != trackInfo.payload.title
            || sharedTrack?.artist != trackInfo.payload.artist
            || sharedTrack?.artworkDataBase64 != trackInfo.payload.artworkDataBase64
        if widgetMetadataChanged {
            RateSyncWidgetConfiguration.saveNowPlayingTrack(
                title: trackInfo.payload.title,
                artist: trackInfo.payload.artist,
                artworkDataBase64: trackInfo.payload.artworkDataBase64,
                updatedAt: eventDate ?? Date()
            )
            reloadWidgetTimeline(reason: "now playing metadata updated on pause")
        }
    }

    func playerTrackInfoDidChange(_ trackInfo: TrackInfo, bundleIdentifier: String?, eventDate: Date?) {
        guard let bundleID = bundleIdentifier ?? trackInfo.payload.bundleIdentifier else { return }
        let receivedAt = eventDate ?? Date()
        let record = PlayerTrackRecord(
            trackInfo: trackInfo,
            bundleIdentifier: bundleID,
            processID: trackInfo.payload.PID,
            recordedAt: receivedAt
        )

        processQueue.async { [weak self] in
            guard let self else { return }

            let previousRecord = self.latestPlayerRecords[bundleID]
            let previousRecordTrack = previousRecord.map { MediaTrack(trackInfo: $0.trackInfo) }
            self.latestPlayerRecords[bundleID] = record

            let newMediaTrack = MediaTrack(trackInfo: trackInfo)
            let isSameSong = (previousRecordTrack == newMediaTrack)
                && (self.lastTrackChangeDatesByPlayer[bundleID] != nil)

            if !isSameSong {
                self.confirmedPlayerFormats.removeValue(forKey: bundleID)
                if bundleID == PlayerProfile.appleMusic.bundleIdentifier {
                    self.appleMusicLastKnownCurrentTrackSampleRate = nil
                    self.appleMusicFormatEvidence = nil
                    self.appleMusicDecoderFormatEvidence = nil
                    self.appleMusicFallbackFormat = nil
                    self.appleMusicFallbackAttemptedForTrack = false
                    self.appleMusicAtmosProbeScheduledGeneration = nil
                    self.appleMusicAtmosProbeCompletedGeneration = nil
                    self.appleMusicAtmosProbeLastCompletedAt = nil
                }
                self.trackStartedAtByPlayer[bundleID] = receivedAt
                self.lastTrackChangeDatesByPlayer[bundleID] = receivedAt.addingTimeInterval(-0.5)
            } else if self.trackStartedAtByPlayer[bundleID] == nil && trackInfo.payload.isPlaying != false {
                self.trackStartedAtByPlayer[bundleID] = receivedAt
                self.lastTrackChangeDatesByPlayer[bundleID] = receivedAt.addingTimeInterval(-0.5)
            }

            let controlledDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let controlledDeviceID = controlledDevice?.id else { return }

            let processes = self.audioProcessMonitor.currentAudioProcesses()
            let activePlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                processes: processes,
                controlledDeviceID: controlledDeviceID
            )
            let shouldAccept = MultiPlayerArbitrationPolicy.shouldAcceptTrackEvent(
                forControlledDeviceID: controlledDeviceID,
                playerBundleIdentifier: bundleID,
                processes: processes
            )

            let isCurrentPlayer = (self.currentTrack.flatMap { Self.resolveBundleIdentifier(track: $0) } == bundleID)
            let isPauseOrStop = (trackInfo.payload.isPlaying == false)

            if isPauseOrStop {
                // Any pause or stop notification from a registered player immediately cancels pending stabilization
                self.arbitrationTracker.cancelStabilization(reason: "player \(bundleID) reported pause/stop")
                self.multiPlayerStabilizationWorkItem?.cancel()
                self.multiPlayerStabilizationWorkItem = nil

                self.confirmedPlayingDatesByPlayer[bundleID] = nil
                if self.arbitrationConfirmedSinglePlayer == bundleID {
                    self.arbitrationConfirmedSinglePlayer = nil
                }

                if bundleID == PlayerProfile.appleMusic.bundleIdentifier {
                    self.appleMusic.invalidatePlaybackStateCache()
                }

                if isCurrentPlayer {
                    RateSyncLog.switching.info("[Pause/Stop] current player \(bundleID, privacy: .public) paused/stopped (shouldAccept=\(shouldAccept)), invalidating in-flight track queries")
                    self.handlePlayerPauseOrStop(trackInfo, eventDate: receivedAt)
                }
            } else if shouldAccept {
                let hasMultipleActivePlayers = activePlayers.count > 1
                let isMultiPlayerPendingOrActive = self.isMultiPlayerConflictActive || self.arbitrationTracker.isStabilizationScheduled
                if !hasMultipleActivePlayers && !isMultiPlayerPendingOrActive {
                    self.handleTrackDidChange(trackInfo, eventDate: receivedAt)
                }
            } else {
                RateSyncLog.switching.info("[Takeover] \(bundleID, privacy: .public) is not outputting to controlled device \(controlledDeviceID), ignoring track change for controlled device")
            }

            self.evaluateMultiPlayerActivityInternal(
                controlledDeviceID: controlledDeviceID,
                processes: processes,
                activeOutputPlayers: activePlayers
            )
        }
    }

    func evaluateMultiPlayerActivity() {
        processQueue.async { [weak self] in
            guard let self else { return }
            let controlledDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let controlledDeviceID = controlledDevice?.id else { return }

            let processes = self.audioProcessMonitor.currentAudioProcesses()
            let activeOutputPlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                processes: processes,
                controlledDeviceID: controlledDeviceID
            )

            self.evaluateMultiPlayerActivityInternal(
                controlledDeviceID: controlledDeviceID,
                processes: processes,
                activeOutputPlayers: activeOutputPlayers
            )
        }
    }

    func evaluateMultiPlayerActivityInternal(
        controlledDeviceID: AudioObjectID,
        processes: [AudioProcessSnapshot],
        activeOutputPlayers: Set<String>
    ) {
        // Increment query generation UPFRONT via tracker so any pending previous async query results are discarded!
        let queryGen = self.arbitrationTracker.beginQuery()

        // Track active player members; if member set changed, cancel old stabilization timer and bump version!
        let playersChanged = self.arbitrationTracker.updateActiveOutputPlayers(activeOutputPlayers)
        if playersChanged {
            self.multiPlayerStabilizationWorkItem?.cancel()
            self.multiPlayerStabilizationWorkItem = nil
        }

        if let current = self.currentTrack,
           let currentBundleID = Self.resolveBundleIdentifier(track: current),
           !activeOutputPlayers.contains(currentBundleID) {
            self.currentTrackGeneration &+= 1
            self.pendingCandidate = nil
        }

        if activeOutputPlayers.isEmpty {
            self.arbitrationTracker.handleEmptyProcesses()
            self.multiPlayerStabilizationWorkItem?.cancel()
            self.multiPlayerStabilizationWorkItem = nil
            self.isArbitrationPending = false
            self.arbitrationConfirmedSinglePlayer = nil
            if self.isMultiPlayerConflictActive {
                self.isMultiPlayerConflictActive = false
            }
            return
        }

        if activeOutputPlayers.count > 1 || playersChanged {
            self.isArbitrationPending = true
            self.arbitrationConfirmedSinglePlayer = nil
        }

        // Map active PIDs for each player outputting to the controlled device
        var playerActivePIDs: [String: Set<pid_t>] = [:]
        for proc in processes where proc.isRunningOutput && proc.outputDeviceIDs.contains(controlledDeviceID) {
            if let bID = proc.bundleIdentifier, activeOutputPlayers.contains(bID) {
                playerActivePIDs[bID, default: []].insert(proc.pid)
            }
        }

        let group = DispatchGroup()
        var statuses: [String: PlayerPlaybackStatus] = [:]
        let lock = NSLock()

        for player in activeOutputPlayers {
            group.enter()
            let latestRecord = self.latestPlayerRecords[player]
            let activePIDs = playerActivePIDs[player] ?? []
            self.playerPlaybackResolver.resolvePlaybackStatus(
                for: player,
                activeProcessIDs: activePIDs,
                latestRecord: latestRecord
            ) { status in
                lock.lock()
                statuses[player] = status
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: self.processQueue) { [weak self] in
            guard let self else { return }
            for (player, status) in statuses where status == .playing {
                self.confirmedPlayingDatesByPlayer[player] = Date()
            }
            // Stale query guard: must match the query generation recorded at start
            guard self.arbitrationTracker.isQueryResultValid(queryGen: queryGen) else {
                RateSyncLog.switching.info("[MultiPlayer] stale query result generation \(queryGen) vs current \(self.arbitrationTracker.queryGeneration), discarded")
                return
            }
            self.isArbitrationPending = false

            // Controlled device check: verify device has not changed during async query
            let currentDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let currentDeviceID = currentDevice?.id, currentDeviceID == controlledDeviceID else {
                RateSyncLog.switching.info("[MultiPlayer] controlled device changed during arbitration, discarded")
                return
            }

            let supportedRates = currentDevice?.nominalSampleRates ?? []
            let action = MultiPlayerArbitrationPolicy.evaluate(
                activeOutputPlayers: activeOutputPlayers,
                playbackStatuses: statuses,
                supportedSampleRates: supportedRates,
                previousWasMultiPlayer: self.isMultiPlayerConflictActive
            )

            switch action {
            case .multiPlayerConflict(let targetRate, let isSupported):
                self.arbitrationConfirmedSinglePlayer = nil
                // Invalidate in-flight single track probes immediately
                self.currentTrackGeneration &+= 1
                self.pendingCandidate = nil

                guard isSupported else {
                    RateSyncLog.switching.info("[MultiPlayer] device does not support \(targetRate, privacy: .public) Hz, keeping current format")
                    self.arbitrationTracker.cancelStabilization(reason: "device does not support target rate")
                    self.multiPlayerStabilizationWorkItem?.cancel()
                    self.multiPlayerStabilizationWorkItem = nil
                    if self.isMultiPlayerConflictActive {
                        self.isMultiPlayerConflictActive = false
                    }
                    self.arbitrationTracker.resetConflict()
                    return
                }

                if self.isMultiPlayerConflictActive {
                    if currentDevice?.nominalSampleRate != targetRate {
                        self.commitMultiPlayerConflict(targetRate: targetRate, isSupportedByDevice: true, deviceID: controlledDeviceID)
                    }
                } else {
                    let scheduleResult = self.arbitrationTracker.scheduleStabilization(
                        targetRate: targetRate,
                        players: activeOutputPlayers
                    )
                    if scheduleResult.shouldSchedule {
                        let timerVersion = scheduleResult.version
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.processQueue.async {
                                self.multiPlayerStabilizationWorkItem = nil

                                let nowDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
                                guard let nowDeviceID = nowDevice?.id, nowDeviceID == controlledDeviceID else {
                                    self.arbitrationTracker.cancelStabilization(reason: "controlled device changed during stabilization")
                                    return
                                }

                                let nowProcesses = self.audioProcessMonitor.currentAudioProcesses()
                                let nowActive = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                                    processes: nowProcesses,
                                    controlledDeviceID: nowDeviceID
                                )

                                let recordSnapshots: [String: PlayerPlaybackRecordSnapshot] = self.latestPlayerRecords.mapValues {
                                    PlayerPlaybackRecordSnapshot(
                                        bundleIdentifier: $0.bundleIdentifier,
                                        isPlaying: $0.trackInfo.payload.isPlaying,
                                        processID: $0.processID,
                                        recordedAt: $0.recordedAt
                                    )
                                }

                                guard self.arbitrationTracker.canCommitStabilization(
                                    timerVersion: timerVersion,
                                    activeOutputPlayers: nowActive,
                                    records: recordSnapshots
                                ) else {
                                    RateSyncLog.switching.info("[MultiPlayer] stabilization condition no longer met (version=\(timerVersion)), cancelling 48 kHz switch")
                                    self.arbitrationTracker.cancelStabilization(reason: "condition not met at stabilization expiration")
                                    return
                                }

                                self.arbitrationTracker.endStabilizationTimer(timerVersion: timerVersion)
                                self.commitMultiPlayerConflict(targetRate: targetRate, isSupportedByDevice: isSupported, deviceID: nowDeviceID)
                            }
                        }
                        self.multiPlayerStabilizationWorkItem = workItem
                        self.processQueue.asyncAfter(
                            deadline: .now() + Self.multiPlayerStabilizationDelay,
                            execute: workItem
                        )
                    }
                }

            case .singlePlayer(let bundleID, let isTransitionFromMultiPlayer):
                self.arbitrationTracker.cancelStabilization(reason: "transition to single player \(bundleID)")
                self.multiPlayerStabilizationWorkItem?.cancel()
                self.multiPlayerStabilizationWorkItem = nil
                self.arbitrationConfirmedSinglePlayer = bundleID
                self.confirmedPlayingDatesByPlayer[bundleID] = Date()

                let currentTrackBundleID = self.currentTrack.flatMap { Self.resolveBundleIdentifier(track: $0) }
                let currentTrackUID = self.currentTrack?.id
                let latestTrackUID = self.latestPlayerRecords[bundleID]?.trackInfo.payload.uniqueIdentifier
                let isTrackChanged = latestTrackUID != nil && currentTrackUID != latestTrackUID
                let needsRecovery = self.isMultiPlayerConflictActive || isTransitionFromMultiPlayer || currentTrackBundleID != bundleID || isTrackChanged

                if needsRecovery {
                    self.isMultiPlayerConflictActive = false
                    self.arbitrationTracker.resetConflict()
                    RateSyncLog.switching.info("[MultiPlayer] recovering single player \(bundleID, privacy: .public)")
                    self.reevaluateSinglePlayerFormat(bundleIdentifier: bundleID)
                }

            case .keepCurrent(let reason):
                self.arbitrationConfirmedSinglePlayer = nil
                self.arbitrationTracker.cancelStabilization(reason: reason)
                self.multiPlayerStabilizationWorkItem?.cancel()
                self.multiPlayerStabilizationWorkItem = nil
                if !reason.contains("cannot be determined") {
                    if self.isMultiPlayerConflictActive {
                        self.isMultiPlayerConflictActive = false
                        self.arbitrationTracker.resetConflict()
                    }
                }
                RateSyncLog.switching.info("[MultiPlayer] keepCurrent: \(reason, privacy: .public)")
            }
        }
    }

    func commitMultiPlayerConflict(targetRate: Double, isSupportedByDevice: Bool, deviceID: AudioObjectID) {
        guard isSupportedByDevice else {
            RateSyncLog.switching.info("[MultiPlayer] device does not support \(targetRate, privacy: .public) Hz, keeping current format")
            self.isMultiPlayerConflictActive = false
            self.arbitrationTracker.resetConflict()
            return
        }
        guard let device = self.selectedOutputDevice ?? self.defaultOutputDevice,
              device.id == deviceID else {
            self.isMultiPlayerConflictActive = false
            self.arbitrationTracker.resetConflict()
            return
        }
        RateSyncLog.switching.info("[MultiPlayer] multiple players active, switching output to \(targetRate, privacy: .public) Hz")
        self.currentTrackGeneration &+= 1
        self.pendingCandidate = nil
        let rateOk = device.setNominalSampleRate(targetRate)
        let confirmedNominal = device.nominalSampleRate
        let applySucceeded = DeviceFormatVerification.isSampleRateApplied(
            targetRate: targetRate,
            nominalRate: confirmedNominal,
            rateSetOk: rateOk
        )
        if applySucceeded {
            self.isMultiPlayerConflictActive = true
            self.arbitrationTracker.markConflictActive()
            RateSyncLog.switching.info("[MultiPlayer] 48 kHz verified and applied to device '\(device.name, privacy: .public)'")
            self.updateSampleRate(targetRate, bitDepth: self.currentBitDepth, runUserScript: true, preserveCandidate: false)
        } else {
            self.isMultiPlayerConflictActive = false
            self.arbitrationTracker.resetConflict()
            RateSyncLog.switching.error("[MultiPlayer] Device '\(device.name, privacy: .public)' rejected 48 kHz (rateSetOk=\(rateOk), confirmedNominal=\(confirmedNominal ?? -1, privacy: .public) Hz), preserving current format")
        }
    }

    func reevaluateSinglePlayerFormat(bundleIdentifier: String) {
        RateSyncLog.switching.info("[MultiPlayer] re-evaluating single player format for \(bundleIdentifier, privacy: .public)")
        self.currentTrackGeneration &+= 1
        self.pendingCandidate = nil

        let latestRecord = self.latestPlayerRecords[bundleIdentifier]
        let trackSnapshot: MediaTrack?
        let trackChanged: Bool
        if let record = latestRecord {
            let mediaTrack = MediaTrack(trackInfo: record.trackInfo)
            trackChanged = (self.currentTrack != mediaTrack)
            self.previousTrack = self.currentTrack
            self.currentTrack = mediaTrack
            trackSnapshot = mediaTrack

            RateSyncWidgetConfiguration.saveNowPlayingTrack(
                title: record.trackInfo.payload.title,
                artist: record.trackInfo.payload.artist,
                artworkDataBase64: record.trackInfo.payload.artworkDataBase64,
                updatedAt: record.recordedAt
            )
            reloadWidgetTimeline(reason: "now playing metadata updated on single player recovery")
        } else {
            trackChanged = false
            trackSnapshot = self.currentTrack
        }

        if let confirmedDate = self.confirmedPlayerFormats[bundleIdentifier]?.lastTrackChangeDate {
            self.lastTrackChangeDate = confirmedDate
        } else if let playerBoundary = self.lastTrackChangeDatesByPlayer[bundleIdentifier] {
            self.lastTrackChangeDate = playerBoundary
        }
        if let confirmedStartedAt = self.confirmedPlayerFormats[bundleIdentifier]?.trackStartedAt {
            self.currentTrackStartedAt = confirmedStartedAt
        } else if let playerStartedAt = self.trackStartedAtByPlayer[bundleIdentifier] {
            self.currentTrackStartedAt = playerStartedAt
        }

        if bundleIdentifier == PlayerProfile.appleMusic.bundleIdentifier {
            self.appleMusic.invalidatePlaybackStateCache()
            self.appleMusicSampleRateQueryID &+= 1
            self.appleMusicSampleRateState = .waiting
            let now = Date()
            self.appleMusicSampleRateWaitStartedAt = now
            self.appleMusicSampleRateLastQueriedAt = nil
            self.currentTrackStartedAt = now
            self.currentTrackRequeryStartedAt = now
            let isConfirmed = trackSnapshot.map { self.hasConfirmedTrackFormat(for: $0) } ?? false
            if trackChanged || !isConfirmed {
                self.appleMusicLastKnownCurrentTrackSampleRate = nil
                self.appleMusicFormatEvidence = nil
                self.appleMusicDecoderFormatEvidence = nil
                self.appleMusicFallbackFormat = nil
                self.appleMusicFallbackAttemptedForTrack = false
                self.appleMusicAtmosProbeScheduledGeneration = nil
                self.appleMusicAtmosProbeCompletedGeneration = nil
                self.appleMusicAtmosProbeLastCompletedAt = nil
            }
            self.renewTimer()
            if let track = trackSnapshot {
                self.trackDeviceMatch.removeValue(forKey: track)
                self.trackAndSample.removeValue(forKey: track)
                self.trackAndBitDepth.removeValue(forKey: track)
                self.trackLockedDeviceUID.removeValue(forKey: track)
                self.switchLatestSampleRate(for: track, generation: self.currentTrackGeneration)
            }
        } else {
            self.resetNonAppleMusicProbeWindow()
            let now = Date()
            self.currentTrackRequeryStartedAt = now
            self.renewTimer()
            if let track = trackSnapshot {
                self.trackDeviceMatch.removeValue(forKey: track)
                self.trackAndSample.removeValue(forKey: track)
                self.trackAndBitDepth.removeValue(forKey: track)
                self.trackLockedDeviceUID.removeValue(forKey: track)
                if let confirmed = self.confirmedPlayerFormats[bundleIdentifier],
                   confirmed.track == track {
                    RateSyncLog.switching.info("[MultiPlayer] restoring preserved format \(confirmed.sampleRate, privacy: .public) Hz / \(confirmed.sourceBitDepth.map { "\($0)bit" } ?? "nil", privacy: .public) for \(bundleIdentifier, privacy: .public)")
                    let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
                    let stat = CMPlayerStats(
                        sampleRate: confirmed.sourceSampleRate ?? confirmed.sampleRate,
                        bitDepth: confirmed.sourceBitDepth,
                        date: confirmed.lastTrackChangeDate ?? self.lastTrackChangeDate ?? now
                    )
                    self.cacheConfirmedDeviceMatch(
                        track,
                        deviceUID: confirmed.deviceUID ?? defaultDevice?.uid,
                        sampleRate: confirmed.sampleRate,
                        bitDepth: confirmed.sourceBitDepth ?? confirmed.bitDepth,
                        sourceSampleRate: confirmed.sourceSampleRate ?? confirmed.sampleRate
                    )
                    self.applyStats(
                        [stat],
                        source: .decoderLog,
                        expectedTrack: track,
                        generation: self.currentTrackGeneration,
                        recursion: false
                    )
                } else {
                    self.switchLatestSampleRate(for: track, generation: self.currentTrackGeneration)
                }
            }
        }
    }

}
