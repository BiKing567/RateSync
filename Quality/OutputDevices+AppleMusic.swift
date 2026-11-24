//
//  OutputDevices+AppleMusic.swift
//  Quality
//

import Foundation
import CoreAudio
import SimplyCoreAudio
import OSLog

extension OutputDevices {
    /// Applies Apple Music's EQ preset matching the current track's genre.
    /// Apple Music-specific automation is kept in AppleMusicService.
    func applyAppleMusicEQIfNeeded() {
        processQueue.async { [weak self] in
            self?.scheduleAppleMusicEQUpdate()
        }
    }

    func scheduleAppleMusicEQUpdate() {
        let isEnabled = Defaults.shared.autoEQEnabled
        let isCurrentSource = isAppleMusicSource
        DispatchQueue.global(qos: .userInitiated).async { [appleMusic] in
            appleMusic.applyEQIfNeeded(isEnabled: isEnabled, isCurrentSource: isCurrentSource)
        }
    }

    func resolveAppleMusicCurrentTrackSampleRate(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        scheduleAppleMusicAtmosProbeIfNeeded(expectedTrack: expectedTrack, generation: generation)

        switch appleMusicSampleRateState {
        case .inactive:
            return
        case .querying:
            return
        case .notPlaying:
            // MediaRemote can retain the same track snapshot across pause/resume.
            // Reset the detection and query windows when playback resumes; otherwise a
            // long pause would make the first resumed query look timed out or settled.
            let resumedAt = Date()
            currentTrackStartedAt = resumedAt
            currentTrackRequeryStartedAt = resumedAt
            appleMusicSampleRateState = .waiting
            appleMusicSampleRateWaitStartedAt = resumedAt
            appleMusicAtmosProbeCompletedGeneration = nil
            appleMusicAtmosProbeLastCompletedAt = nil
        case .resolved(let sampleRate):
            let now = Date()
            guard AppleMusicCurrentTrackRatePolicy.shouldRevalidate(
                lastQueriedAt: appleMusicSampleRateLastQueriedAt,
                now: now,
                trackStartedAt: currentTrackRequeryStartedAt ?? currentTrackStartedAt,
                isTrackLocked: hasConfirmedTrackFormat(for: expectedTrack)
            ) else {
                applyAppleMusicCurrentTrackSampleRate(
                    sampleRate,
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: recursion
                )
                return
            }

            // A quick first answer can be a transient 44.1 kHz value while
            // Music finishes loading a 96/192 kHz track. Start a fresh bounded
            // query window for the same track instead of reusing that answer.
            RateSyncLog.switching.info(
                "[AM CurrentTrackRate] revalidating settled track after \(AppleMusicCurrentTrackRatePolicy.revalidationInterval, privacy: .public)s"
            )
            appleMusicSampleRateState = .waiting
            appleMusicSampleRateWaitStartedAt = now
        case .fallbackToLogs:
            if !preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            ) {
                runAppleMusicLogFallback(expectedTrack: expectedTrack, generation: generation, recursion: recursion)
            }
            return
        case .waiting:
            break
        }

        let startedAt = appleMusicSampleRateWaitStartedAt ?? Date()
        appleMusicSampleRateWaitStartedAt = startedAt
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= AppleMusicSampleRatePolicy.maximumWait {
            logAppleMusicSampleRateDecision(
                track: expectedTrack,
                elapsed: elapsed,
                result: "missing value",
                fallback: appleMusicLastKnownCurrentTrackSampleRate == nil
                    ? "timeout"
                    : "timeout_preserveCurrentTrack"
            )
            if !preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            ) {
                appleMusicSampleRateState = .fallbackToLogs
                runAppleMusicLogFallback(
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: true
                )
            }
            return
        }

        appleMusicSampleRateQueryID &+= 1
        let queryID = appleMusicSampleRateQueryID
        appleMusicSampleRateState = .querying
        appleMusicSampleRateLastQueriedAt = Date()
        let remaining = max(0, AppleMusicSampleRatePolicy.maximumWait - elapsed)
        processQueue.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self,
                  AppleMusicSampleRateQueryPolicy.isCurrent(
                      expectedQueryID: queryID,
                      currentQueryID: self.appleMusicSampleRateQueryID
                  ),
                  self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  case .querying = self.appleMusicSampleRateState else { return }
            let timeoutElapsed = Date().timeIntervalSince(startedAt)
            self.logAppleMusicSampleRateDecision(
                track: expectedTrack,
                elapsed: timeoutElapsed,
                result: "AppleScript request timed out",
                fallback: self.appleMusicLastKnownCurrentTrackSampleRate == nil
                    ? "timeout"
                    : "timeout_preserveCurrentTrack"
            )
            if !self.preserveAppleMusicCurrentTrackRateOrFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            ) {
                self.appleMusicSampleRateState = .fallbackToLogs
                self.runAppleMusicLogFallback(
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: true
                )
            }
        }
        appleMusic.fetchCurrentTrackSampleRate { [weak self] result in
            guard let self else { return }
            self.processQueue.async { [weak self] in
                guard let self else { return }
                guard AppleMusicSampleRateQueryPolicy.isCurrent(
                    expectedQueryID: queryID,
                    currentQueryID: self.appleMusicSampleRateQueryID
                ) else { return }
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                    RateSyncLog.switching.info("[AM CurrentTrackRate] stale AppleScript result discarded")
                    if case .querying = self.appleMusicSampleRateState {
                        if let lastKnown = self.appleMusicLastKnownCurrentTrackSampleRate {
                            self.appleMusicSampleRateState = .resolved(lastKnown)
                        } else {
                            self.appleMusicSampleRateState = .waiting
                        }
                    }
                    return
                }
                guard case .querying = self.appleMusicSampleRateState else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let resolution = elapsed >= AppleMusicSampleRatePolicy.maximumWait
                    ? AppleMusicSampleRateResolution.fallbackToLogs
                    : AppleMusicSampleRatePolicy.resolution(for: result, elapsed: elapsed)
                self.logAppleMusicSampleRateDecision(
                    track: expectedTrack,
                    elapsed: elapsed,
                    result: result.logLabel,
                    fallback: resolution == .fallbackToLogs
                        ? (elapsed >= AppleMusicSampleRatePolicy.maximumWait || result == .missingValue ? "timeout" : "unavailable")
                        : nil
                )

                switch resolution {
                case .apply(let sampleRate):
                    self.applyAppleMusicCurrentTrackSampleRate(
                        sampleRate,
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: recursion
                    )
                case .retry(let delay):
                    self.appleMusicSampleRateState = .waiting
                    self.processQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self,
                              AppleMusicSampleRateQueryPolicy.isCurrent(
                                  expectedQueryID: queryID,
                                  currentQueryID: self.appleMusicSampleRateQueryID
                              ),
                              self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                        self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
                    }
                case .fallbackToLogs:
                    if !self.preserveAppleMusicCurrentTrackRateOrFallback(
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: true
                    ) {
                        self.appleMusicSampleRateState = .fallbackToLogs
                        self.runAppleMusicLogFallback(
                            expectedTrack: expectedTrack,
                            generation: generation,
                            recursion: true
                        )
                    }
                case .noPlayback:
                    self.appleMusicSampleRateState = .notPlaying
                    self.appleMusicSampleRateWaitStartedAt = nil
                    self.scheduleAppleMusicResumeCheck(
                        expectedTrack: expectedTrack,
                        generation: generation
                    )
                }
            }
        }
    }

    func scheduleAppleMusicResumeCheck(
        expectedTrack: MediaTrack,
        generation: UInt64
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation),
              appleMusicResumeRetryWorkItem == nil,
              let delay = AppleMusicPlaybackRecoveryPolicy.retryDelay(
                  hasCurrentTrack: true,
                  isTrackLocked: hasConfirmedTrackFormat(for: expectedTrack),
                  attempts: appleMusicResumeCheckAttempts
              ) else {
            return
        }
        appleMusicResumeCheckAttempts += 1

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appleMusicResumeRetryWorkItem = nil
            guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  case .notPlaying = self.appleMusicSampleRateState else {
                return
            }
            self.switchLatestSampleRate(
                for: expectedTrack,
                recursion: true,
                generation: generation
            )
        }
        appleMusicResumeRetryWorkItem = workItem
        processQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func applyAppleMusicCurrentTrackSampleRate(
        _ sampleRate: Double,
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }

        let effectiveRate = AppleMusicFormatPolicy.effectiveSampleRate(
            scriptRate: sampleRate,
            decoderEvidence: appleMusicDecoderFormatEvidence,
            formatEvidence: appleMusicFormatEvidence,
            trackStartedAt: currentTrackStartedAt,
            expectedTrackID: expectedTrack.id,
            expectedTrackTitle: expectedTrack.title,
            decoderToleranceThreshold: lastTrackChangeDate
        ) ?? sampleRate

        if effectiveRate.isFinite,
           effectiveRate > 0,
           effectiveRate <= RateSwitchingPolicy.maxPlausibleSampleRate {
            appleMusicLastKnownCurrentTrackSampleRate = effectiveRate
        }

        // A later AppleScript or decoder answer for the same track is new evidence, not
        // jitter from another track. Drop the old same-track lock so the
        // normal stability gate can confirm and apply the corrected rate.
        if let cachedSampleRate = trackAndSample[expectedTrack],
           cachedSampleRate != effectiveRate {
            trackAndSample.removeValue(forKey: expectedTrack)
            trackAndBitDepth.removeValue(forKey: expectedTrack)
            trackLockedDeviceUID.removeValue(forKey: expectedTrack)
            pendingCandidate = nil
            RateSyncLog.switching.info(
                "[AM CurrentTrackRate] replacing stale same-track rate \(cachedSampleRate, privacy: .public) with \(effectiveRate, privacy: .public)"
            )
        }
        if let matched = trackDeviceMatch[expectedTrack],
           matched.sourceSampleRate != effectiveRate,
           matched.sampleRate != effectiveRate {
            trackDeviceMatch.removeValue(forKey: expectedTrack)
        }
        let atmosphere = appleMusicFormatEvidence.flatMap { stat -> CMPlayerStats? in
            guard AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                formatEvidence: stat,
                expectedTrackID: expectedTrack.id,
                expectedTrackTitle: expectedTrack.title,
                trackStartedAt: currentTrackStartedAt
            ) else {
                return nil
            }
            return stat
        }
        let action = AppleMusicCurrentTrackRatePolicy.action(
            hasCurrentTrackRate: effectiveRate.isFinite && effectiveRate > 0,
            hasPriorityEvidence: atmosphere != nil,
            atmosProbeCompleted: appleMusicAtmosProbeCompletedGeneration == generation
        )

        switch action {
        case .applyPriorityFormat:
            guard let atmosphere else { return }
            applyStats(
                [atmosphere],
                source: .appleMusicFormatLog,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        case .waitForAtmosProbe:
            appleMusicSampleRateState = .resolved(effectiveRate)
            return
        case .fallbackToLogs:
            appleMusicSampleRateState = .fallbackToLogs
            runAppleMusicLogFallback(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            )
            return
        case .applyCurrentTrackRate:
            break
        }

        appleMusicSampleRateState = .resolved(effectiveRate)
        let atmosProbeStatus = appleMusicAtmosProbeCompletedGeneration == generation ? "complete" : "pending"
        let bitDepthEvidence = AppleMusicFormatPolicy.bitDepthEvidence(
            formatEvidence: appleMusicFormatEvidence,
            fallbackEvidence: appleMusicFallbackFormat,
            decoderEvidence: appleMusicDecoderFormatEvidence,
            targetSampleRate: effectiveRate,
            expectedTrackID: expectedTrack.id,
            expectedTrackTitle: expectedTrack.title
        )
        RateSyncLog.switching.info("[AM RateDecision] source=AppleScript/Decoder action=stabilityGate sampleRate=\(effectiveRate, privacy: .public) bitDepth=\(bitDepthEvidence.map { "\($0)bit" } ?? "nil", privacy: .public) atmosProbe=\(atmosProbeStatus, privacy: .public)")

        let stat = CMPlayerStats.sampleRateOnly(
            sampleRate: effectiveRate,
            bitDepth: bitDepthEvidence
        )
        applyStats(
            [stat],
            source: .appleMusicCurrentTrack,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
        scheduleAppleMusicEQUpdate()
    }

    /// Keep a valid same-track AppleScript result authoritative when a later
    /// revalidation times out. Log fallback remains available for tracks for
    /// which AppleScript never supplied a usable current-track rate.
    @discardableResult
    func preserveAppleMusicCurrentTrackRateOrFallback(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) -> Bool {
        let hasKnownCurrentTrackRate = appleMusicLastKnownCurrentTrackSampleRate != nil
        guard AppleMusicCurrentTrackRatePolicy.shouldPreserveCurrentTrackRateOnFallback(
                  hasKnownCurrentTrackRate: hasKnownCurrentTrackRate
              ),
              let sampleRate = appleMusicLastKnownCurrentTrackSampleRate else {
            return false
        }

        appleMusicSampleRateState = .resolved(sampleRate)
        RateSyncLog.switching.info(
            "[AM CurrentTrackRate] revalidation fallback preserved last AppleScript rate \(sampleRate, privacy: .public)"
        )
        applyAppleMusicCurrentTrackSampleRate(
            sampleRate,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
        return true
    }

    func runAppleMusicLogFallback(
        expectedTrack: MediaTrack,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        appleMusicFallbackAttemptedForTrack = true
        runLogChain(expectedTrack: expectedTrack, generation: generation, recursion: recursion)
        scheduleAppleMusicRecoveryProbeIfNeeded(expectedTrack: expectedTrack, generation: generation)
    }

    func scheduleAppleMusicRecoveryProbeIfNeeded(expectedTrack: MediaTrack, generation: UInt64) {
        guard AppleMusicCurrentTrackRatePolicy.shouldScheduleRecoveryProbe(
            state: appleMusicSampleRateState,
            hasKnownCurrentTrackRate: appleMusicLastKnownCurrentTrackSampleRate != nil,
            attempts: appleMusicRecoveryAttempts
        ) else { return }
        guard appleMusicRecoveryWorkItem == nil else { return }

        let attempts = appleMusicRecoveryAttempts + 1
        appleMusicRecoveryAttempts = attempts
        let delay = AppleMusicCurrentTrackRatePolicy.recoveryProbeInterval
        RateSyncLog.switching.info("[AM RecoveryProbe] scheduling recovery attempt \(attempts, privacy: .public)/\(AppleMusicCurrentTrackRatePolicy.maxRecoveryAttempts, privacy: .public) in \(delay, privacy: .public)s")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appleMusicRecoveryWorkItem = nil
            guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                  self.isAppleMusicSource,
                  case .fallbackToLogs = self.appleMusicSampleRateState,
                  self.appleMusicLastKnownCurrentTrackSampleRate == nil else { return }

            RateSyncLog.switching.info("[AM RecoveryProbe] attempting to recover primary AppleScript source (attempt \(attempts, privacy: .public))")
            self.appleMusicSampleRateState = .waiting
            self.appleMusicFallbackAttemptedForTrack = false
            self.appleMusicSampleRateWaitStartedAt = Date()
            self.resolveAppleMusicCurrentTrackSampleRate(
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: true
            )
        }
        appleMusicRecoveryWorkItem = workItem
        processQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func scheduleAppleMusicAtmosProbeIfNeeded(expectedTrack: MediaTrack, generation: UInt64) {
        guard AppleMusicFormatProbePolicy.shouldSchedule(
            generation: generation,
            scheduledGeneration: appleMusicAtmosProbeScheduledGeneration,
            completedGeneration: appleMusicAtmosProbeCompletedGeneration,
            lastCompletedAt: appleMusicAtmosProbeLastCompletedAt,
            now: Date(),
            trackStartedAt: currentTrackRequeryStartedAt ?? currentTrackStartedAt,
            sampleRateState: appleMusicSampleRateState
        ) else { return }
        appleMusicAtmosProbeScheduledGeneration = generation
        let logThreshold = lastTrackChangeDate
        let trackID = expectedTrack.id ?? "unknown"
        let probeStartedAt = appleMusicSampleRateWaitStartedAt ?? Date()

        appleMusicAtmosProbeQueue.async { [weak self] in
            guard let self else { return }
            let stats = self.getAllStats(
                process: PlayerProfile.appleMusic.processName,
                parser: CMPlayerParser.parseAppleMusicConsoleLogs,
                durationSeconds: AppleMusicFormatParser.logWindowSeconds
            ).filter { stat in
                guard let logThreshold else { return true }
                return stat.date >= logThreshold
            }

            self.processQueue.async { [weak self] in
                guard let self else { return }
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                      self.isAppleMusicSource else { return }
                self.rememberAppleMusicFormat(from: stats, for: expectedTrack)
                self.rememberAppleMusicDecoderFormat(from: stats, for: expectedTrack)
                if let preferredFormat = self.appleMusicFormatEvidence,
                   preferredFormat.isPriorityAppleMusicFormat {
                    let isMismatched = preferredFormat.isMismatched(trackID: expectedTrack.id, title: expectedTrack.title)
                    if isMismatched || (self.currentTrackStartedAt.map { preferredFormat.date < $0 } == true && !preferredFormat.isAttributed(trackID: expectedTrack.id, title: expectedTrack.title)) {
                        self.appleMusicFormatEvidence = nil
                        return
                    }
                    let canOverrideConfirmed = AppleMusicFormatPolicy.canOverrideConfirmedTrackRate(
                        formatEvidence: preferredFormat,
                        expectedTrackID: expectedTrack.id,
                        expectedTrackTitle: expectedTrack.title,
                        trackStartedAt: self.currentTrackStartedAt
                    )
                    let canUseUnattributedFallback = (self.appleMusicSampleRateState == .fallbackToLogs)
                        && (self.appleMusicLastKnownCurrentTrackSampleRate == nil)
                        && !isMismatched
                    if canOverrideConfirmed || canUseUnattributedFallback {
                        self.appleMusicAtmosProbeCompletedGeneration = generation
                        self.appleMusicAtmosProbeScheduledGeneration = nil
                        self.appleMusicAtmosProbeLastCompletedAt = Date()
                        guard self.appleMusicSampleRateState != .notPlaying else { return }

                        let elapsed = Date().timeIntervalSince(probeStartedAt)
                        let evidenceType = preferredFormat.isDolbyAtmos ? "DolbyAtmos" : "spatialAudio"
                        RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) source=AppleMusicLog type=\(evidenceType, privacy: .public) sampleRate=\(preferredFormat.sampleRate, privacy: .public) elapsed=\(elapsed, privacy: .public)s")
                        self.applyStats(
                            [preferredFormat],
                            source: .appleMusicFormatLog,
                            expectedTrack: expectedTrack,
                            generation: generation,
                            recursion: false
                        )
                        return
                    }
                }

                let elapsed = Date().timeIntervalSince(probeStartedAt)
                guard self.appleMusicSampleRateState != .notPlaying else {
                    self.appleMusicAtmosProbeCompletedGeneration = generation
                    self.appleMusicAtmosProbeScheduledGeneration = nil
                    self.appleMusicAtmosProbeLastCompletedAt = Date()
                    return
                }

                if let retryDelay = AppleMusicFormatProbePolicy.retryDelay(
                    after: elapsed,
                    hasPriorityEvidence: false
                ) {
                    RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) found=false elapsed=\(elapsed, privacy: .public)s retryIn=\(retryDelay, privacy: .public)s")
                    self.processQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                        guard let self,
                              self.isExpectedTrackCurrent(expectedTrack, generation: generation),
                              self.appleMusicAtmosProbeScheduledGeneration == generation else { return }
                        self.appleMusicAtmosProbeScheduledGeneration = nil
                        self.scheduleAppleMusicAtmosProbeIfNeeded(
                            expectedTrack: expectedTrack,
                            generation: generation
                        )
                    }
                    return
                }

                self.appleMusicAtmosProbeCompletedGeneration = generation
                self.appleMusicAtmosProbeScheduledGeneration = nil
                self.appleMusicAtmosProbeLastCompletedAt = Date()
                RateSyncLog.switching.info("[AM AtmosEvidence] track=\(trackID, privacy: .public) found=false elapsed=\(elapsed, privacy: .public)s fallback=AppleScript")
                if case .resolved(let sampleRate) = self.appleMusicSampleRateState {
                    self.applyAppleMusicCurrentTrackSampleRate(
                        sampleRate,
                        expectedTrack: expectedTrack,
                        generation: generation,
                        recursion: true
                    )
                }
            }
        }
    }

    func logAppleMusicSampleRateDecision(
        track: MediaTrack,
        elapsed: TimeInterval,
        result: String,
        fallback: String?
    ) {
        let fallbackDescription = fallback ?? "none"
        RateSyncLog.switching.info("[AM CurrentTrackRate] track=\(track.id ?? "unknown", privacy: .public) source=AppleScript elapsed=\(elapsed, privacy: .public)s result=\(result, privacy: .public) fallback=\(fallbackDescription, privacy: .public)")
    }

    func rememberAppleMusicFormat(from stats: [CMPlayerStats], for track: MediaTrack? = nil) {
        let targetTrack = track ?? currentTrack
        if let existing = appleMusicFormatEvidence,
           existing.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) {
            appleMusicFormatEvidence = nil
        }
        let trackStartedAt = currentTrackStartedAt
        let validStats = stats.filter { stat in
            guard stat.isAppleMusicFormat else { return false }
            switch stat.attribution(trackID: targetTrack?.id, title: targetTrack?.title) {
            case .mismatched:
                return false
            case .matched:
                return true
            case .unattributed:
                guard let trackStartedAt else { return true }
                return stat.date >= trackStartedAt
            }
        }
        let incoming = validStats.first(where: { $0.isPriorityAppleMusicFormat && $0.isAttributed(trackID: targetTrack?.id, title: targetTrack?.title) })
            ?? validStats.max(by: { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return !lhs.isPriorityAppleMusicFormat && rhs.isPriorityAppleMusicFormat
            })
        guard let incoming else {
            return
        }
        let existing = appleMusicFormatEvidence
        guard AppleMusicFormatPolicy.shouldReplaceCachedFormat(
            currentIsPriorityFormat: existing?.isPriorityAppleMusicFormat == true,
            incomingIsPriorityFormat: incoming.isPriorityAppleMusicFormat,
            currentIsAttributedToTrack: existing?.isAttributed(trackID: targetTrack?.id, title: targetTrack?.title) == true,
            incomingIsNewer: existing.map { incoming.date > $0.date } ?? true
        ) else {
            return
        }
        appleMusicFormatEvidence = incoming
    }

    func rememberAppleMusicDecoderFormat(from stats: [CMPlayerStats], for track: MediaTrack? = nil) {
        let targetTrack = track ?? currentTrack
        if let existing = appleMusicDecoderFormatEvidence,
           existing.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) {
            appleMusicDecoderFormatEvidence = nil
        }
        let minDate = lastTrackChangeDate ?? currentTrackStartedAt
        guard let incoming = stats
            .filter({ stat in
                guard !stat.isAppleMusicFormat && stat.bitDepth != nil else { return false }
                guard !stat.isMismatched(trackID: targetTrack?.id, title: targetTrack?.title) else { return false }
                if let minDate {
                    return stat.date >= minDate
                }
                return true
            })
            .max(by: { $0.date < $1.date }) else {
            return
        }
        if let existing = appleMusicDecoderFormatEvidence,
           incoming.date < existing.date {
            return
        }
        appleMusicDecoderFormatEvidence = incoming
    }

    func cachedAppleMusicStats(process: String) -> [CMPlayerStats] {
        pruneLogStatsCache()
        let key = LogStatsCachePolicy.appleMusicCacheKey(process: process)
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            RateSyncLog.switching.info("[LogCache] hit for Apple Music (\(cached.stats.count) stats)")
            return cached.stats
        }
        let stats = self.getAllStats(
            process: process,
            parser: CMPlayerParser.parseAppleMusicConsoleLogs,
            durationSeconds: AppleMusicFormatParser.logWindowSeconds
        )
        if stats.isEmpty {
            logStatsCache.removeValue(forKey: key)
        } else {
            logStatsCache[key] = (stats, Date())
            RateSyncLog.switching.info("[LogCache] stored for Apple Music (\(stats.count) stats)")
        }
        return stats
    }

}
