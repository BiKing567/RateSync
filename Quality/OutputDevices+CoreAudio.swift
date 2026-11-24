//
//  OutputDevices+CoreAudio.swift
//  Quality
//

import Foundation
import CoreAudio
import SimplyCoreAudio
import CoreAudioTypes
import WidgetKit

extension OutputDevices {
    func getDeviceSampleRate() {
        processQueue.async { [weak self] in
            self?.refreshCurrentOutputFormat()
        }
    }

    func outputDeviceDidChange() {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.refreshCurrentOutputFormat()
            self.cancelRetryTimer()
            self.currentTrackGeneration &+= 1
            self.pendingCandidate = nil
            self.arbitrationTracker.resetConflict()
            self.isMultiPlayerConflictActive = false
            self.isArbitrationPending = false
            self.arbitrationConfirmedSinglePlayer = nil
            self.multiPlayerStabilizationWorkItem?.cancel()
            self.multiPlayerStabilizationWorkItem = nil
            // Preserve the current track's verified format evidence across output device
            // switches, while resetting the probe retry budget for the new DAC.
            self.formatProbeBudget.resetForNewWindow()
            if self.isAppleMusicSource {
                if let lastKnown = self.appleMusicLastKnownCurrentTrackSampleRate {
                    self.appleMusicSampleRateState = .resolved(lastKnown)
                } else if self.appleMusicSampleRateState == .querying {
                    self.appleMusicSampleRateState = .waiting
                }
            }

            let controlledDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
            guard let controlledDeviceID = controlledDevice?.id else { return }

            let processes = self.audioProcessMonitor.currentAudioProcesses()
            let activeOutputPlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
                processes: processes,
                controlledDeviceID: controlledDeviceID
            )

            guard !activeOutputPlayers.isEmpty else {
                RateSyncLog.switching.info("[OutputDevice] no registered player actively outputting to controlled device \(controlledDeviceID), preserving current format")
                self.arbitrationTracker.handleEmptyProcesses()
                return
            }

            if activeOutputPlayers.count == 1,
               let activePlayer = activeOutputPlayers.first,
               let currentTrack = self.currentTrack,
               Self.resolveBundleIdentifier(track: currentTrack) == activePlayer,
               self.isPlayerEffectivelyPlaying(activePlayer) {
                self.switchLatestSampleRate(for: currentTrack, generation: self.currentTrackGeneration)
            }

            self.evaluateMultiPlayerActivityInternal(
                controlledDeviceID: controlledDeviceID,
                processes: processes,
                activeOutputPlayers: activeOutputPlayers
            )
        }
    }

    func hasConfirmedTrackFormat(for track: MediaTrack) -> Bool {
        trackAndSample[track] != nil || trackDeviceMatch[track] != nil
    }

    func isTrackLockedOnDevice(_ track: MediaTrack, device: AudioDevice?) -> Bool {
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

    func isCurrentDeviceMatched(for track: MediaTrack, device: AudioDevice?) -> Bool {
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

    func refreshCurrentOutputFormat() {
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

    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        let streams = device.streams(scope: .output)
        guard let rangedFormats = streams?.first?.availablePhysicalFormats else { return nil }
        let supportedRates = device.nominalSampleRates ?? []
        return AudioFormatSelector.expandRangedFormats(rangedFormats, supportedSampleRates: supportedRates)
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

}
