//
//  OutputDevices+AudioLogs.swift
//  Quality
//

import Foundation
import CoreAudio
import SimplyCoreAudio
import OSLog

extension OutputDevices {
    func getAllStats(process: String = PlayerProfile.appleMusic.processName,
                     parser: ([SimpleConsole]) -> [CMPlayerStats] = CMPlayerParser.parseCoreAudioConsoleLogs,
                     durationSeconds: TimeInterval = 5.0) -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()

        do {
            let entryTypes: [EntryType] = process == PlayerProfile.appleMusic.processName
                ? [.coreAudio, .appleMusic]
                : [.coreAudio]
            let logs = try Console.getRecentEntries(types: entryTypes, process: process, durationSeconds: durationSeconds)
            allStats.append(contentsOf: parser(logs))
            let statsSummary = allStats.map { "\($0.sampleRate)Hz/\($0.bitDepth.map { "\($0)bit" } ?? "nil")" }.joined(separator: ", ")
            RateSyncLog.switching.info("[getAllStats] count=\(allStats.count, privacy: .public) [\(statsSummary, privacy: .public)]")
        }
        catch {
            RateSyncLog.switching.info("[getAllStats, error] \(String(describing: error), privacy: .public)")
        }

        return allStats
    }

    func applyAppleMusicPriorityOrMediaRemote(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard shouldPrioritizeAppleMusic, appleMusic.isRunning else {
            applyMediaRemoteProbe(
                sampleRate: sampleRate,
                reportedBitDepth: reportedBitDepth,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }

        appleMusic.fetchPlaybackState { [weak self] state in
            guard let self else { return }
            self.processQueue.async {
                guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                    RateSyncLog.switching.info("stale switch task after Apple Music priority check, skip")
                    return
                }
                if let state,
                   state.isPlaying,
                   let appleMusicSampleRate = state.sampleRate,
                   appleMusicSampleRate > 0 {
                    // This fallback reports only the rate; output bit depth is not source evidence.
                    let stat = CMPlayerStats.sampleRateOnly(sampleRate: appleMusicSampleRate)
                    RateSyncLog.switching.info("[AM Priority] Apple Music is playing, using its sample rate")
                    self.applyStats([stat], source: .appleMusicPriority, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    self.scheduleAppleMusicEQUpdate()
                    return
                }
                self.applyMediaRemoteProbe(
                    sampleRate: sampleRate,
                    reportedBitDepth: reportedBitDepth,
                    expectedTrack: expectedTrack,
                    generation: generation,
                    recursion: recursion
                )
            }
        }
    }

    func recordMediaRemoteBitDepthEvidence(_ validDepth: Int?, at date: Date) {
        guard let validDepth else { return }
        let probeEvidence = TrackFormatResolutionPolicy.BitDepthEvidence(
            bitDepth: validDepth,
            source: .mediaRemoteReport,
            date: date
        )
        if TrackFormatResolutionPolicy.shouldPreferBitDepthEvidence(
            probeEvidence,
            over: cachedBitDepthEvidence
        ) {
            cachedBitDepthEvidence = probeEvidence
        }
    }

    func applyMediaRemoteProbe(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        let now = Date()
        let validRate = TrackFormatResolutionPolicy.validSampleRate(sampleRate)
        if let validRate {
            cachedMediaRemoteSampleRate = validRate
        }
        let validDepth = TrackFormatResolutionPolicy.validBitDepth(reportedBitDepth)
        recordMediaRemoteBitDepthEvidence(validDepth, at: now)
        let effectiveRate = validRate ?? cachedMediaRemoteSampleRate
        let targetTrack = expectedTrack ?? currentTrack
        let bundleID = Self.resolveBundleIdentifier(track: targetTrack)
        let presetRate = Self.presetSampleRate(for: bundleID)

        if let effectiveRate,
           validDepth != nil || !enableBitDepthDetection || presetRate == nil {
            let effectiveDepth = validDepth ?? (enableBitDepthDetection ? cachedBitDepthEvidence?.bitDepth : nil)
            let stat = CMPlayerStats(sampleRate: effectiveRate, bitDepth: effectiveDepth, date: now)
            RateSyncLog.switching.info("[MRProbe] direct audio format: \(effectiveRate) Hz, \(effectiveDepth ?? -1) bit")
            applyStats([stat], source: .mediaRemoteProbe, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
            return
        }

        runLogChain(
            probeSampleRate: effectiveRate,
            probeBitDepth: validDepth,
            expectedTrack: expectedTrack,
            generation: generation,
            recursion: recursion
        )
    }

    /// Log-based rate resolution plus preset/MediaRemote field merging, run after the
    /// MediaRemote probe reported partial/no format data (or was skipped).
    func runLogChain(
        probeSampleRate: Double? = nil,
        probeBitDepth: Int? = nil,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        let targetTrack = expectedTrack ?? currentTrack
        let now = Date()

        if !isAppleMusicSource {
            let bundleID = Self.resolveBundleIdentifier(track: targetTrack)
            let presetRate = Self.presetSampleRate(for: bundleID)
            let validProbeDepth = TrackFormatResolutionPolicy.validBitDepth(probeBitDepth)
            let hasVerifiedMediaRemoteBitDepth = validProbeDepth != nil
                || cachedBitDepthEvidence?.source == .mediaRemoteReport
            let shouldQueryLogs = formatProbeBudget.shouldProbeLogs(
                hasPresetSampleRate: presetRate != nil,
                hasMediaRemoteBitDepth: hasVerifiedMediaRemoteBitDepth,
                enableBitDepthDetection: enableBitDepthDetection,
                now: now
            )
            let rawLogStats: [CMPlayerStats]
            if shouldQueryLogs {
                rawLogStats = self.statsFromLogs(for: targetTrack, recursion: recursion)
                if presetRate != nil {
                    let foundBitDepth = rawLogStats.contains { TrackFormatResolutionPolicy.validBitDepth($0.bitDepth) != nil }
                    formatProbeBudget.recordLogAttempt(foundBitDepth: foundBitDepth, now: now)
                }
            } else {
                rawLogStats = []
            }

            let aqSource = self.audioQueueSource(for: rawLogStats)
            let resolution = TrackFormatResolutionPolicy.resolveNonAppleMusic(
                mediaRemoteSampleRate: probeSampleRate,
                mediaRemoteBitDepth: probeBitDepth,
                logStats: rawLogStats,
                cachedSampleRate: cachedMediaRemoteSampleRate,
                cachedBitDepthEvidence: cachedBitDepthEvidence,
                presetSampleRate: presetRate,
                audioQueueSource: aqSource,
                defaultLogSource: aqSource,
                enableBitDepthDetection: enableBitDepthDetection,
                now: now
            )
            if let resolvedEvidence = resolution.resolvedBitDepthEvidence,
               TrackFormatResolutionPolicy.shouldPreferBitDepthEvidence(resolvedEvidence, over: cachedBitDepthEvidence) {
                cachedBitDepthEvidence = resolvedEvidence
            }
            if let first = resolution.stats.first, let bundleID, presetRate != nil {
                RateSyncLog.switching.info("[PresetMerge] \(bundleID, privacy: .public) -> \(first.sampleRate, privacy: .public) Hz, \(first.bitDepth ?? -1, privacy: .public) bit")
            }
            var statsToApply = resolution.stats
            if statsToApply.isEmpty,
               let bID = bundleID,
               let confirmed = self.confirmedPlayerFormats[bID],
               confirmed.track == targetTrack {
                let fallbackStat = CMPlayerStats(
                    sampleRate: confirmed.sourceSampleRate ?? confirmed.sampleRate,
                    bitDepth: confirmed.sourceBitDepth,
                    date: confirmed.lastTrackChangeDate ?? self.lastTrackChangeDate ?? now
                )
                statsToApply = [fallbackStat]
                RateSyncLog.switching.info("[RetryFallback] using confirmed format \(confirmed.sampleRate, privacy: .public) Hz for \(bID, privacy: .public)")
            }
            self.applyStats(
                statsToApply,
                source: resolution.stats.isEmpty && !statsToApply.isEmpty ? .decoderLog : resolution.source,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }

        let rawLogStats = self.statsFromLogs(for: targetTrack, recursion: recursion)
        let toleranceThreshold = recursion ? lastTrackChangeDate?.addingTimeInterval(-1.5) : lastTrackChangeDate
        let logStats = AppleMusicFormatPolicy.filterFallbackLogs(
            rawLogStats,
            expectedTrackID: targetTrack?.id,
            expectedTrackTitle: targetTrack?.title,
            trackStartedAt: currentTrackStartedAt,
            toleranceThreshold: toleranceThreshold
        )
        rememberAppleMusicFormat(from: logStats, for: targetTrack)
        rememberAppleMusicDecoderFormat(from: logStats, for: targetTrack)
        let preferredFallback = AppleMusicFormatPolicy.preferredFallbackEvidence(
            formatEvidence: appleMusicFormatEvidence,
            decoderEvidence: appleMusicDecoderFormatEvidence,
            expectedTrackID: targetTrack?.id,
            expectedTrackTitle: targetTrack?.title,
            trackStartedAt: currentTrackStartedAt,
            decoderToleranceThreshold: toleranceThreshold
        )
        let appleMusicResolution = AppleMusicFormatPolicy.resolution(
            hasLogEvidence: preferredFallback != nil,
            hasLogStats: !logStats.isEmpty,
            hasCachedFallback: appleMusicFallbackFormat != nil,
            hasAttemptedFallback: appleMusicFallbackAttemptedForTrack,
            isPlaying: appleMusic.isRunning
        )
        if appleMusicResolution == .logEvidence,
           let preferredFallback {
            applyStats(
                [preferredFallback.stat],
                source: preferredFallback.source,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }
        if appleMusicResolution == .cachedFallback,
           let appleMusicFallbackFormat {
            applyStats(
                [appleMusicFallbackFormat],
                source: .decoderLog,
                expectedTrack: expectedTrack,
                generation: generation,
                recursion: recursion
            )
            return
        }
        if appleMusicResolution == .requestAppleScript {
            appleMusicFallbackAttemptedForTrack = true
            appleMusic.fetchPlaybackState { [weak self] state in
                guard let self else { return }
                self.processQueue.async {
                    guard self.isExpectedTrackCurrent(expectedTrack, generation: generation) else {
                        RateSyncLog.switching.info("stale switch task after Apple Music log fallback, skip")
                        return
                    }
                    if let state,
                       state.isPlaying,
                       let sampleRate = state.sampleRate,
                       sampleRate > 0 {
                        // This fallback reports only the rate; output bit depth is not source evidence.
                        let stat = CMPlayerStats.sampleRateOnly(sampleRate: sampleRate)
                        self.appleMusicFallbackFormat = stat
                        RateSyncLog.switching.info("[LogFallback] Apple Music AppleScript sample rate: \(sampleRate)")
                        self.applyStats([stat], source: .decoderLog, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    } else {
                        self.applyStats([], source: .decoderLog, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
                    }
                }
            }
            return
        }
        let source: RateSource = logStats.first?.isAppleMusicFormat == true ? .appleMusicFormatLog : .decoderLog
        self.applyStats(logStats, source: source, expectedTrack: expectedTrack, generation: generation, recursion: recursion)
    }

    /// Classifies an AudioQueue log result for the gate.
    ///
    /// A line written BEFORE the current track change describes the previous
    /// track. Recursive retries widen the staleness filter by 1.5s, so such a
    /// line does reach applyStats - deliberately, because on a slow first
    /// write it is the only available data. It is still real data, but it is
    /// not trustworthy enough to apply immediately: the fast AudioQueue gate
    /// would lock in the OLD track's rate before the new line lands. Those
    /// results fall back to the conservative gate, which confirms long enough
    /// for the new track's own line to be written.
    func audioQueueSource(for stats: [CMPlayerStats]) -> RateSource {
        guard let lastTrackChangeDate, let newest = stats.map(\.date).max() else {
            return .audioQueueLog
        }
        if newest < lastTrackChangeDate {
            RateSyncLog.switching.info("[Gate] AudioQueue log predates track change, using conservative gate")
            return .staleAudioQueueLog
        }
        return .audioQueueLog
    }

    /// Best-effort preset sample rates for apps that expose no sample rate
    /// anywhere (no Now Playing audio format keys, no parseable decoder logs,
    /// no AppleScript access). Verified facts only:
    /// - Spotify streams (lossy or the 2025 CD-lossless "HD" tier) are 44.1 kHz.
    /// Extend this table per app after measuring its actual behaviour.
    static func presetSampleRate(for bundleIdentifier: String?) -> Double? {
        guard let bundleIdentifier else { return nil }
        return PlayerProfile.profile(for: bundleIdentifier)?.fallbackSampleRate
    }

    /// Log-based fallback chain, per source process:
    /// - Any other process (e.g. "NeteaseMusic"): AudioQueue "New output"
    ///   entries, which report the decoded sample rate for players that
    ///   render through AudioQueue without resampling.
    func statsFromLogs(for track: MediaTrack? = nil, recursion: Bool) -> [CMPlayerStats] {
        guard let processName = Self.resolveProcessName(track: track ?? currentTrack) else {
            RateSyncLog.switching.info("cannot resolve source process name, skipping log chain")
            return []
        }
        let isMusicProcess = (processName == PlayerProfile.appleMusic.processName)

        var allStats: [CMPlayerStats]
        if isMusicProcess {
            guard isAppleMusicSource else { return [] }
            // P2: recursive retries widen the tolerance window. Apple Music decoder logs can be
            // written more than 0.5s before the MediaRemote event (e.g. delayed UI state updates);
            // a strict filter would permanently discard them and, if the AppleScript fallback
            // also fails, the switch would be lost.
            let threshold = recursion
                ? lastTrackChangeDate?.addingTimeInterval(-1.5)
                : lastTrackChangeDate
            allStats = self.cachedAppleMusicStats(process: processName)
            if let threshold {
                allStats = allStats.filter { $0.date >= threshold }
            }
        } else {
            RateSyncLog.switching.info("log chain for process \(processName) via AudioQueue parser")
            // AudioQueue session pairing boundary must remain strictly consistent across retries.
            // Widening the boundary for retries would pull in previous-track converter logs (e.g. t - 0.8s)
            // that erroneously suppress the new track's hardware output logs (t), causing wrong switches.
            let bundleID = (track ?? currentTrack)?.bundleIdentifier
            let playerBoundary = bundleID.flatMap { self.lastTrackChangeDatesByPlayer[$0] }
            let aqBoundary = playerBoundary ?? lastTrackChangeDate
            allStats = self.cachedAudioQueueStats(process: processName, since: aqBoundary)
            if let aqBoundary {
                allStats = allStats.filter { $0.date >= aqBoundary }
            }
        }
        return allStats
    }

    /// Prunes expired entries from `logStatsCache` so old generation/track entries
    /// do not accumulate across songs.
    func pruneLogStatsCache(now: Date = Date()) {
        LogStatsCachePolicy.prune(
            &logStatsCache,
            currentGeneration: currentTrackGeneration,
            now: now,
            ttl: Self.logStatsTTL
        )
    }

    /// AudioQueue stats for `process`, reusing a recent parse when possible.
    ///
    /// One OSLog query costs ~0.70 s of blocking work regardless of window
    /// size, and the gate re-evaluates every 0.5 s, so an uncached chain pays
    /// for a dozen near-identical queries per track change. Results are
    /// cached for `logStatsTTL`.
    ///
    /// Only NON-EMPTY results are cached: an empty result usually means the
    /// log line has not been written yet, and caching that would freeze the
    /// retry loop into returning nothing until the TTL expires.
    ///
    /// The cached value is keyed by process, generation, and since boundary,
    /// with pre-filtering by `since` ensuring companion suppression only evaluates
    /// entries belonging to the current playback window.
    func cachedAudioQueueStats(process: String, since: Date? = nil) -> [CMPlayerStats] {
        pruneLogStatsCache()
        let key = LogStatsCachePolicy.audioQueueCacheKey(
            process: process,
            generation: currentTrackGeneration,
            since: since
        )
        if let cached = logStatsCache[key],
           Date().timeIntervalSince(cached.at) < Self.logStatsTTL {
            RateSyncLog.switching.info("[LogCache] hit for \(process, privacy: .public) (\(cached.stats.count) stats)")
            return cached.stats
        }
        let stats = self.getAllStats(process: process,
                                     parser: { CMPlayerParser.parseAudioQueueConsoleLogs($0, since: since) },
                                     durationSeconds: 60)
        if stats.isEmpty {
            // Do not cache "nothing found" - the line may simply not be
            // written yet, and the gate must be able to re-query.
            logStatsCache.removeValue(forKey: key)
            RateSyncLog.switching.info("[LogCache] miss for \(process, privacy: .public) (no stats, not cached)")
        } else {
            logStatsCache[key] = (stats, Date())
            RateSyncLog.switching.info("[LogCache] stored for \(process, privacy: .public) (\(stats.count) stats)")
        }
        return stats
    }

    /// Applies the best matching device format for the given stats, and
    /// schedules one retry when nothing usable was found yet.
    func applyStats(
        _ allStats: [CMPlayerStats],
        source: RateSource = .decoderLog,
        expectedTrack: MediaTrack?,
        generation: UInt64,
        recursion: Bool
    ) {
        guard !isMultiPlayerConflictActive && !arbitrationTracker.isStabilizationScheduled else {
            RateSyncLog.switching.info("[MultiPlayer] active conflict or stabilization scheduled, skipping applyStats")
            return
        }
        guard isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
        let policy = RateSwitchingPolicy.gatePolicy(for: source)
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let defaultDeviceID = defaultDevice?.id else { return }

        let processes = self.audioProcessMonitor.currentAudioProcesses()
        let activePlayers = MultiPlayerArbitrationPolicy.registeredPlayersWithActiveOutput(
            processes: processes,
            controlledDeviceID: defaultDeviceID
        )

        let targetTrack = expectedTrack ?? currentTrack
        let targetBundleID = targetTrack.flatMap { Self.resolveBundleIdentifier(track: $0) }

        if activePlayers.count > 1 || self.isArbitrationPending {
            guard let bID = targetBundleID, self.arbitrationConfirmedSinglePlayer == bID else {
                RateSyncLog.switching.info("[applyStats] multi-player arbitration pending or active on device \(defaultDeviceID), skipping single-player format write")
                return
            }
        }

        if let bundleID = targetBundleID {
            guard activePlayers.contains(bundleID),
                  self.isPlayerEffectivelyPlaying(bundleID) else {
                RateSyncLog.switching.info("[applyStats] player \(bundleID, privacy: .public) is not actively outputting/playing to controlled device \(defaultDeviceID), skipping format write")
                return
            }
        }

        var didFindStat = false

        if let first = allStats.first,
           let supported = defaultDevice?.nominalSampleRates,
           // Reject implausible rates before they can reach CoreAudio:
           // 0 Hz / negative rates would select the LOWEST supported rate
           // and absurd rates the highest, silently forcing the device to
           // an extreme format. A rejected stat leaves didFindStat false, so
           // the single non-recursive retry below can still pick up a later,
           // valid reading without starting a retry loop.
           first.sampleRate.isFinite,
           first.sampleRate > 0,
           first.sampleRate <= RateSwitchingPolicy.maxPlausibleSampleRate {
            didFindStat = true
            let sampleRate = Float64(first.sampleRate)
            let currentOutputBitDepth = defaultDevice?.streams(scope: .output)?.first?.physicalFormat
                .map { Int($0.mBitsPerChannel) }
                .flatMap { $0 > 0 ? $0 : nil }
            // This is only a selector hint; the final 24-bit fallback must never count as evidence
            // for changing bit depth when the source did not report one.
            let selectionHintBitDepth = first.bitDepth ?? currentOutputBitDepth ?? previousBitDepth ?? 24
            // Clamp instead of truncating, and clamp before use:
            // Int32(truncatingIfNeeded:) silently turns an absurd depth
            // into a bogus but plausible-looking value
            // (99999999999999 -> 276447231). A garbage depth must not cost
            // us a valid rate, so it is clamped, not rejected.
            let bitDepth = Int32(clamping: min(max(selectionHintBitDepth, 1), RateSwitchingPolicy.maxPlausibleBitDepth))

            // Boundary gating: right after a track change, players
            // transitioning between formats (e.g. Dolby Atmos) report an
            // intermediate rate (44.1 kHz) for several seconds before
            // settling on the real one — via decoder logs AND via the
            // MediaRemote probe itself. A differing rate may only be
            // applied when (a) the post-track-change window has closed
            // AND (b) the same candidate has persisted across evaluations.
            // Both windows count down concurrently from the candidate's first observation.
            // Equal-rate candidates pass through untouched.
            let sinceTrackChange = lastTrackChangeDate.map {
                Date().timeIntervalSince($0)
            } ?? .infinity
            let rateDiffersFromDevice = defaultDevice?.nominalSampleRate != sampleRate
            if rateDiffersFromDevice {
                let alreadyConfirmedForTrack = currentTrack.map { track in
                    trackAndSample[track] == sampleRate
                        || (sinceTrackChange >= policy.boundary && trackDeviceMatch[track]?.sourceSampleRate == sampleRate)
                } ?? false
                if !alreadyConfirmedForTrack {
                    let now = Date()
                    let candidate = RateGateDecisionPolicy.updateCandidate(
                        current: pendingCandidate,
                        rate: sampleRate,
                        generation: generation,
                        now: now
                    )
                    pendingCandidate = candidate

                    let isLocked = currentTrack.map { isTrackLockedOnDevice($0, device: defaultDevice) } ?? false
                    let requiredPersistence = RateGateDecisionPolicy.requiredPersistence(
                        isLocked: isLocked,
                        policy: policy
                    )
                    let boundarySatisfied = RateGateDecisionPolicy.isBoundarySatisfied(
                        sinceTrackChange: sinceTrackChange,
                        policy: policy
                    )
                    let stabilitySatisfied = RateGateDecisionPolicy.isStabilitySatisfied(
                        candidateFirstSeen: candidate.firstSeen,
                        now: now,
                        requiredPersistence: requiredPersistence
                    )
                    let confirmed = boundarySatisfied && stabilitySatisfied

                    if !confirmed {
                        let persistenceElapsed = now.timeIntervalSince(candidate.firstSeen)
                        if !boundarySatisfied && !stabilitySatisfied {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz inside boundary (\(String(format: "%.1f", sinceTrackChange), privacy: .public)/\(String(format: "%.1f", policy.boundary), privacy: .public)s) and awaiting stability (\(String(format: "%.1f", persistenceElapsed), privacy: .public)/\(String(format: "%.1f", requiredPersistence), privacy: .public)s), re-evaluating in 0.5s")
                        } else if !boundarySatisfied {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) != device \(defaultDevice?.nominalSampleRate ?? -1, privacy: .public) Hz inside boundary window (\(String(format: "%.1f", sinceTrackChange), privacy: .public)/\(String(format: "%.1f", policy.boundary), privacy: .public)s), re-evaluating in 0.5s")
                        } else {
                            RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz awaiting stability (\(String(format: "%.1f", persistenceElapsed), privacy: .public)/\(String(format: "%.1f", requiredPersistence), privacy: .public)s), re-evaluating in 0.5s")
                        }
                        processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self,
                                  self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                            self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
                        }
                        return
                    }
                    RateSyncLog.switching.info("[Gate] candidate \(sampleRate, privacy: .public) Hz confirmed stable, applying")
                }
            }
            pendingCandidate = nil

            guard let defaultDevice = defaultDevice,
                  let formats = self.getFormats(device: defaultDevice) else { return }

            let availableDepthsAtTargetRate = formats
                .filter { $0.mSampleRate == sampleRate }
                .map { Int($0.mBitsPerChannel) }
                .sorted()
            let availableDepthsDescription = availableDepthsAtTargetRate.isEmpty
                ? "none"
                : availableDepthsAtTargetRate.map { "\($0)bit" }.joined(separator: ", ")

            RateSyncLog.switching.info(
                "[FormatSelector] source=\(source, privacy: .public) sourceRate=\(sampleRate, privacy: .public) Hz sourceDepth=\(first.bitDepth.map { "\($0)bit" } ?? "nil", privacy: .public) deviceDepth=\(currentOutputBitDepth.map { "\($0)bit" } ?? "nil", privacy: .public) hintDepth=\(bitDepth, privacy: .public) bit availableAtRate=[\(availableDepthsDescription, privacy: .public)]"
            )

            let suitableFormat = AudioFormatSelector.nearestFormat(
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                supportedSampleRates: supported,
                formats: formats,
                preferSampleRateMultiples: Defaults.shared.userPreferSampleRateMultiples
            )
            RateSyncLog.switching.info("NEAREST FORMAT \(suitableFormat.map { "\($0.mSampleRate)Hz/\($0.mBitsPerChannel)bit" } ?? "none", privacy: .public)")

            if let suitableFormat {
                // Same-track lock: once a sample rate has been applied for the current
                // track, never switch again within the same song unless the output
                // device itself changed (e.g. the user switched device), the parsed
                // sample rate actually differs from the applied one (e.g. the stream
                // switched to another version mid-song), or, in bit depth mode, the
                // applicable bit depth actually changed within the track. Multiple decoder
                // log entries (e.g. Dolby Atmos streams) can jitter between sample
                // rates, which would otherwise cause repeated switching.
                if let currentTrack = currentTrack,
                   let cachedSampleRate = trackAndSample[currentTrack],
                   isTrackLockedOnDevice(currentTrack, device: defaultDevice),
                   cachedSampleRate == sampleRate {
                    let bitDepthChanged = RateSwitchingPolicy.shouldApplyBitDepthChange(
                        isEnabled: enableBitDepthDetection,
                        reportedBitDepth: first.bitDepth,
                        currentBitDepth: currentOutputBitDepth ?? trackAndBitDepth[currentTrack],
                        selectedBitDepth: Int(suitableFormat.mBitsPerChannel)
                    )
                    if !bitDepthChanged {
                        self.cacheConfirmedDeviceMatch(
                            currentTrack,
                            deviceUID: defaultDevice.uid,
                            sampleRate: cachedSampleRate,
                            bitDepth: currentOutputBitDepth ?? trackAndBitDepth[currentTrack],
                            sourceSampleRate: sampleRate
                        )
                        if let firstBitDepth = first.bitDepth {
                            self.cacheTrackResult(
                                currentTrack,
                                deviceUID: defaultDevice.uid,
                                sampleRate: cachedSampleRate,
                                bitDepth: currentOutputBitDepth ?? trackAndBitDepth[currentTrack],
                                sourceSampleRate: sampleRate,
                                sourceBitDepth: firstBitDepth
                            )
                        }
                        RateSyncLog.switching.info("same track, sample rate already applied, skip")
                        return
                    }
                    RateSyncLog.switching.info("same track, bit depth changed, re-applying format")
                }
                let currentDeviceSampleRate = defaultDevice.nominalSampleRate ?? previousSampleRate
                let sampleRateChanged = suitableFormat.mSampleRate != currentDeviceSampleRate
                let bitDepthChanged = RateSwitchingPolicy.shouldApplyBitDepthChange(
                    isEnabled: enableBitDepthDetection,
                    reportedBitDepth: first.bitDepth,
                    currentBitDepth: currentOutputBitDepth ?? previousBitDepth,
                    selectedBitDepth: Int(suitableFormat.mBitsPerChannel)
                )
                let formatChanged = sampleRateChanged || bitDepthChanged

                let readBackOutputBitDepth = defaultDevice.streams(scope: .output)?.first?.physicalFormat
                    .map { Int($0.mBitsPerChannel) }
                    .flatMap { $0 > 0 ? $0 : nil }
                let appliedBitDepth = DeviceFormatVerification.resolveAppliedBitDepth(
                    isBitDepthDetectionEnabled: enableBitDepthDetection,
                    sourceReportedBitDepth: first.bitDepth,
                    targetBitDepth: suitableFormat.mBitsPerChannel,
                    readBackBitDepth: readBackOutputBitDepth,
                    currentOutputBitDepth: currentOutputBitDepth,
                    previousBitDepth: previousBitDepth
                )

                // An equal-rate result is a NO-OP (device already correct).
                // Applying-and-caching it in `trackAndSample` would wrongly "settle" the track's
                // switching lock: a genuine rate arriving later would then be forced onto
                // the slow 12 s override tier (observed as ~20 s switching
                // when the first read is stale data from the previous
                // track). Leave `trackAndSample` uncached, and record the confirmed device
                // match separately so steady-state polling stops after the settling window.
                if !formatChanged {
                    if let currentTrack = currentTrack {
                        let matchedRate = currentDeviceSampleRate ?? suitableFormat.mSampleRate
                        self.cacheConfirmedDeviceMatch(
                            currentTrack,
                            deviceUID: defaultDevice.uid,
                            sampleRate: matchedRate,
                            bitDepth: appliedBitDepth,
                            sourceSampleRate: sampleRate
                        )
                        if let bundleID = Self.resolveBundleIdentifier(track: currentTrack) {
                            self.confirmedPlayerFormats[bundleID] = ConfirmedPlayerSourceFormat(
                                track: currentTrack,
                                sampleRate: matchedRate,
                                bitDepth: appliedBitDepth,
                                sourceSampleRate: sampleRate,
                                sourceBitDepth: first.bitDepth,
                                deviceUID: defaultDevice.uid,
                                lastTrackChangeDate: self.lastTrackChangeDatesByPlayer[bundleID] ?? self.lastTrackChangeDate,
                                trackStartedAt: self.trackStartedAtByPlayer[bundleID] ?? self.currentTrackStartedAt,
                                confirmedAt: Date()
                            )
                        }
                    }
                    RateSyncLog.switching.info("already at target format target=\(suitableFormat.mSampleRate, privacy: .public)Hz/\(suitableFormat.mBitsPerChannel, privacy: .public)bit (device at \(currentDeviceSampleRate ?? -1, privacy: .public)Hz/\(appliedBitDepth ?? -1, privacy: .public)bit), nothing to apply (left uncached)")
                    return
                }

                if first.bitDepth != nil {
                    RateSyncLog.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz depth \(suitableFormat.mBitsPerChannel, privacy: .public)")
                } else {
                    RateSyncLog.switching.info("APPLYING rate \(suitableFormat.mSampleRate, privacy: .public) Hz; bit depth unknown, preserving current depth")
                }
                var applySucceeded = true
                if enableBitDepthDetection && first.bitDepth != nil {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                    let appliedPhysicalFormat = defaultDevice.streams(scope: .output)?.first?.physicalFormat
                    applySucceeded = DeviceFormatVerification.isPhysicalFormatApplied(
                        targetRate: suitableFormat.mSampleRate,
                        targetBitDepth: suitableFormat.mBitsPerChannel,
                        streamPhysicalFormat: appliedPhysicalFormat,
                        nominalRate: defaultDevice.nominalSampleRate
                    )
                } else if sampleRateChanged { // Keep the current depth when the source did not report one.
                    let rateSetOk = defaultDevice.setNominalSampleRate(suitableFormat.mSampleRate)
                    let confirmedNominal = defaultDevice.nominalSampleRate
                    applySucceeded = DeviceFormatVerification.isSampleRateApplied(
                        targetRate: suitableFormat.mSampleRate,
                        nominalRate: confirmedNominal,
                        rateSetOk: rateSetOk
                    )
                }

                if !applySucceeded {
                    if let currentTrack = currentTrack {
                        self.trackDeviceMatch.removeValue(forKey: currentTrack)
                        self.trackAndSample.removeValue(forKey: currentTrack)
                        self.trackAndBitDepth.removeValue(forKey: currentTrack)
                        self.trackLockedDeviceUID.removeValue(forKey: currentTrack)
                    }
                    let streams = defaultDevice.streams(scope: .output)
                    let currentStreamFormat = streams?.first?.physicalFormat
                    let fallback = DeviceFormatVerification.fallbackStateOnFailure(
                        nominalRate: defaultDevice.nominalSampleRate,
                        streamPhysicalFormat: currentStreamFormat,
                        currentOutputBitDepth: currentOutputBitDepth,
                        previousSampleRate: previousSampleRate,
                        previousBitDepth: previousBitDepth
                    )
                    RateSyncLog.switching.error("Device '\(defaultDevice.name, privacy: .public)' rejected format target=(\(suitableFormat.mSampleRate, privacy: .public) Hz, \(suitableFormat.mBitsPerChannel, privacy: .public) bit) nominal=(\(defaultDevice.nominalSampleRate ?? -1, privacy: .public) Hz)")
                    if let fallbackRate = fallback.sampleRate {
                        self.updateSampleRate(
                            fallbackRate,
                            bitDepth: fallback.bitDepth,
                            runUserScript: false,
                            preserveCandidate: true
                        )
                    } else {
                        self.previousSampleRate = nil
                        self.previousBitDepth = fallback.bitDepth
                    }
                    self.pendingCandidate = RateGateDecisionPolicy.CandidateTracking(
                        rate: suitableFormat.mSampleRate,
                        generation: generation,
                        firstSeen: Date()
                    )
                    return
                }

                let postApplyReadBackBitDepth = defaultDevice.streams(scope: .output)?.first?.physicalFormat
                    .map { Int($0.mBitsPerChannel) }
                    .flatMap { $0 > 0 ? $0 : nil }
                let finalAppliedBitDepth = DeviceFormatVerification.resolveAppliedBitDepth(
                    isBitDepthDetectionEnabled: enableBitDepthDetection,
                    sourceReportedBitDepth: first.bitDepth,
                    targetBitDepth: suitableFormat.mBitsPerChannel,
                    readBackBitDepth: postApplyReadBackBitDepth,
                    currentOutputBitDepth: currentOutputBitDepth,
                    previousBitDepth: previousBitDepth
                )
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: finalAppliedBitDepth, runUserScript: formatChanged)
                if let currentTrack = currentTrack {
                    self.cacheTrackResult(
                        currentTrack,
                        deviceUID: defaultDevice.uid,
                        sampleRate: suitableFormat.mSampleRate,
                        bitDepth: finalAppliedBitDepth,
                        sourceSampleRate: sampleRate,
                        sourceBitDepth: first.bitDepth
                    )
                }
            }
        }

        // Console logs may not contain the new track's format yet right after a track change.
        // Retry once shortly instead of waiting for the slower fallback timer.
        if !didFindStat && !recursion {
            processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      self.isExpectedTrackCurrent(expectedTrack, generation: generation) else { return }
                self.switchLatestSampleRate(for: expectedTrack, recursion: true, generation: generation)
            }
        }
    }


    /// Records the format applied for a track, under a hard size cap.
    /// Only `currentTrack` is ever read back, but entries survive until the
    /// next track change, so an unbounded table would retain one entry per
    /// distinct track ever played in a long-running menu bar process.
    func cacheTrackResult(
        _ track: MediaTrack,
        deviceUID: String? = nil,
        sampleRate: Float64,
        bitDepth: Int?,
        sourceSampleRate: Float64? = nil,
        sourceBitDepth: Int? = nil
    ) {
        self.trackAndSample[track] = sampleRate
        self.trackAndBitDepth[track] = bitDepth
        self.trackLockedDeviceUID[track] = deviceUID
        self.cacheConfirmedDeviceMatch(
            track,
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sourceSampleRate: sourceSampleRate ?? sampleRate
        )
        if let bundleID = Self.resolveBundleIdentifier(track: track) {
            self.confirmedPlayerFormats[bundleID] = ConfirmedPlayerSourceFormat(
                track: track,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                sourceSampleRate: sourceSampleRate ?? sampleRate,
                sourceBitDepth: sourceBitDepth,
                deviceUID: deviceUID,
                lastTrackChangeDate: self.lastTrackChangeDatesByPlayer[bundleID] ?? self.lastTrackChangeDate,
                trackStartedAt: self.trackStartedAtByPlayer[bundleID] ?? self.currentTrackStartedAt,
                confirmedAt: Date()
            )
        }
        // Dictionary ordering is unspecified, so this trims arbitrary
        // victims rather than a true LRU - the cap is the safety net, and
        // trackDidChange already removes entries as tracks move on.
        while self.trackAndSample.count > Self.maxCachedTracks {
            guard let victim = self.trackAndSample.keys.first(where: { $0 != self.currentTrack })
                    ?? self.trackAndSample.keys.first else { break }
            self.trackAndSample.removeValue(forKey: victim)
            self.trackAndBitDepth.removeValue(forKey: victim)
            self.trackLockedDeviceUID.removeValue(forKey: victim)
            self.trackDeviceMatch.removeValue(forKey: victim)
        }
    }

    func cacheConfirmedDeviceMatch(
        _ track: MediaTrack,
        deviceUID: String?,
        sampleRate: Float64,
        bitDepth: Int?,
        sourceSampleRate: Float64?
    ) {
        self.trackDeviceMatch[track] = SteadyStatePollingPolicy.ConfirmedDeviceMatch(
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sourceSampleRate: sourceSampleRate
        )
        while self.trackDeviceMatch.count > Self.maxCachedTracks {
            guard let victim = self.trackDeviceMatch.keys.first(where: { $0 != self.currentTrack })
                    ?? self.trackDeviceMatch.keys.first else { break }
            self.trackDeviceMatch.removeValue(forKey: victim)
        }
    }

}
