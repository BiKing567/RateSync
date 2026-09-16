//
//  MediaRemoteController.swift
//  RateSync
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
import Combine
import OSLog
import MediaRemoteAdapter

class MediaRemoteController {
    
    private let controller: MediaController
    private let stateQueue = DispatchQueue(label: "MediaRemoteController.state")
    // MediaRemote emits 2-5x duplicate bursts per track change; suppress
    // those so delivery is immediate without re-triggering the pipeline.
    private var lastDeliveredTrack: TrackInfo?
    private var lastDeliveredAt: Date?
    private var currentSource: SourceIdentity?
    private var sourceLastSeen: [String: Date] = [:]
    private var eventGeneration = 0
    private var defaultsCancellables = Set<AnyCancellable>()
    private var lockExpiryWorkItem: DispatchWorkItem?

    private struct SourceIdentity: Equatable {
        let key: String
        let bundleIdentifier: String?
        let processID: pid_t?
    }
    
    init(outputDevices: OutputDevices) {
        
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        observeDefaults(outputDevices: outputDevices)
        controller.onTrackInfoReceived = { [weak self, weak outputDevices] trackInfo in
            self?.handle(trackInfo, outputDevices: outputDevices)
        }

    }

    private func handle(_ trackInfo: TrackInfo?, outputDevices: OutputDevices?) {
        stateQueue.async { [weak self, weak outputDevices] in
            guard let self else { return }
            self.eventGeneration += 1
            let generation = self.eventGeneration

            guard let trackInfo else {
                self.resetStateOnQueue()
                outputDevices?.reevaluateNowPlaying()
                return
            }

            let preferredSourceBundleIdentifier = Defaults.shared.activeTemporarySourceLock?.bundleIdentifier
                ?? Defaults.shared.monitoredBundleIdentifier
            let source = Self.sourceIdentity(
                for: trackInfo,
                preferredBundleIdentifier: preferredSourceBundleIdentifier
            )
            if let lock = Defaults.shared.activeTemporarySourceLock {
                guard source.bundleIdentifier == lock.bundleIdentifier else {
                    self.resetStateOnQueue()
                    outputDevices?.clearNowPlayingTrack()
                    Logger.switching.info("[Takeover] cleared \(source.bundleIdentifier ?? "unknown", privacy: .public): source lock is active")
                    return
                }
                self.deliver(trackInfo, source: source, receivedAt: Date(), outputDevices: outputDevices)
                return
            }

            if let monitored = Defaults.shared.monitoredBundleIdentifier {
                switch MonitoredSourceDecision.decide(
                    monitoredBundleIdentifier: monitored,
                    incomingBundleIdentifier: source.bundleIdentifier
                ) {
                case .deliver:
                    self.deliver(trackInfo, source: source, receivedAt: Date(), outputDevices: outputDevices)
                    return
                case .ignore:
                    self.resetStateOnQueue()
                    Logger.switching.info("[Takeover] ignored \(source.bundleIdentifier ?? "unknown", privacy: .public): not monitored source")
                    return
                }
            }

            let receivedAt = Date()
            self.sourceLastSeen[source.key] = receivedAt
            self.pruneInactiveSources(now: receivedAt)

            guard let currentSource = self.currentSource,
                  currentSource.key != source.key else {
                self.deliver(trackInfo, source: source, receivedAt: receivedAt, outputDevices: outputDevices)
                return
            }

            let priority = PlayerProfile.normalizedPriority(Defaults.shared.playerPriorityBundleIdentifiers)
            let currentLastSeenAt = self.sourceLastSeen[currentSource.key]
            let higherPriority = PlayerTakeoverPolicy.priorityIndex(
                for: source.bundleIdentifier,
                priority: priority
            ) < PlayerTakeoverPolicy.priorityIndex(
                for: currentSource.bundleIdentifier,
                priority: priority
            )
            if higherPriority {
                self.deliver(trackInfo, source: source, receivedAt: receivedAt, outputDevices: outputDevices)
                return
            }

            MediaRemoteSampleRateProbe.fetchActivePlayerPID { [weak self, weak outputDevices] activePID in
                self?.stateQueue.async {
                    guard let self, self.eventGeneration == generation else { return }
                    let activePlayerRelation: PlayerTakeoverPolicy.ActivePlayerRelation
                    if let activePID, activePID > 0 {
                        if self.sourceMatches(activePID: activePID, source: source) {
                            activePlayerRelation = .candidate
                        } else if self.sourceMatches(activePID: activePID, source: currentSource) {
                            activePlayerRelation = .current
                        } else {
                            activePlayerRelation = .unknown
                        }
                    } else {
                        activePlayerRelation = .unknown
                    }
                    let shouldAccept = self.shouldAcceptAfterActivePlayerCheck(
                        activePlayerRelation: activePlayerRelation,
                        candidate: source,
                        current: currentSource,
                        currentLastSeenAt: currentLastSeenAt,
                        now: receivedAt,
                        priority: priority
                    )
                    guard shouldAccept else {
                        Logger.switching.info("[Takeover] ignored \(source.bundleIdentifier ?? "unknown", privacy: .public): lower priority source is still active")
                        return
                    }
                    self.deliver(trackInfo, source: source, receivedAt: receivedAt, outputDevices: outputDevices)
                }
            }
        }
    }

    private func deliver(
        _ trackInfo: TrackInfo,
        source: SourceIdentity,
        receivedAt: Date,
        outputDevices: OutputDevices?
    ) {
        guard !Self.shouldSuppressDuplicate(
            previous: lastDeliveredTrack,
            current: trackInfo,
            lastDeliveredAt: lastDeliveredAt,
            now: receivedAt
        ) else { return }
        lastDeliveredTrack = trackInfo
        lastDeliveredAt = receivedAt
        currentSource = source
        Logger.switching.info("[Takeover] accepted \(trackInfo.payload.uniqueIdentifier) from \(source.bundleIdentifier ?? "unknown", privacy: .public)")
        outputDevices?.trackDidChange(trackInfo, eventDate: receivedAt)
    }

    private func shouldAcceptAfterActivePlayerCheck(
        activePlayerRelation: PlayerTakeoverPolicy.ActivePlayerRelation,
        candidate: SourceIdentity,
        current: SourceIdentity,
        currentLastSeenAt: Date?,
        now: Date,
        priority: [String]
    ) -> Bool {
        PlayerTakeoverPolicy.shouldAcceptAfterActivePlayerCheck(
            activePlayerRelation: activePlayerRelation,
            candidateBundleIdentifier: candidate.bundleIdentifier,
            currentBundleIdentifier: current.bundleIdentifier,
            currentLastSeenAt: currentLastSeenAt,
            now: now,
            priority: priority
        )
    }

    private func sourceMatches(activePID: pid_t, source: SourceIdentity) -> Bool {
        if let processID = source.processID, processID == activePID {
            return true
        }
        guard let bundleIdentifier = source.bundleIdentifier else { return false }
        return NSRunningApplication(processIdentifier: activePID)?.bundleIdentifier == bundleIdentifier
    }

    private func pruneInactiveSources(now: Date) {
        sourceLastSeen = sourceLastSeen.filter {
            now.timeIntervalSince($0.value) <= PlayerTakeoverPolicy.defaultActivityWindow
        }
    }

    private func resetStateOnQueue() {
        lastDeliveredTrack = nil
        lastDeliveredAt = nil
        currentSource = nil
        sourceLastSeen.removeAll()
    }

    private func resetTakeoverState() {
        stateQueue.async { [weak self] in
            self?.eventGeneration += 1
            self?.resetStateOnQueue()
        }
    }

    private func observeDefaults(outputDevices: OutputDevices) {
        let defaults = Defaults.shared
        defaults.$monitoredBundleIdentifier
            .sink { [weak self] _ in self?.resetTakeoverState() }
            .store(in: &defaultsCancellables)
        defaults.$playerPriorityBundleIdentifiers
            .sink { [weak self] _ in self?.resetTakeoverState() }
            .store(in: &defaultsCancellables)
        defaults.$temporarySourceLock
            .sink { [weak self, weak outputDevices] lock in
                guard let self else { return }
                self.resetTakeoverState()
                self.scheduleLockExpiry(lock, outputDevices: outputDevices)
            }
            .store(in: &defaultsCancellables)
    }

    private func scheduleLockExpiry(_ lock: PlayerSourceLock?, outputDevices: OutputDevices?) {
        lockExpiryWorkItem?.cancel()
        guard let expiresAt = lock?.expiresAt,
              expiresAt > Date() else { return }
        let workItem = DispatchWorkItem { [weak self, weak outputDevices] in
            guard let self,
                  Defaults.shared.temporarySourceLock?.expiresAt == expiresAt else { return }
            Defaults.shared.clearTemporarySourceLock()
            self.resetTakeoverState()
            outputDevices?.reevaluateNowPlaying()
        }
        lockExpiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.05, expiresAt.timeIntervalSinceNow),
            execute: workItem
        )
    }

    /// `TrackInfo` is not `Equatable`; compare the identity fields and the
    /// MediaRemote snapshot timestamp. The timestamp distinguishes a replay
    /// of the same metadata from a burst of the same callback payload.
    static func shouldSuppressDuplicate(
        previous: TrackInfo?,
        current: TrackInfo,
        lastDeliveredAt: Date?,
        now: Date
    ) -> Bool {
        TrackEventIdentity.shouldSuppressDuplicate(
            previous: previous.map(Self.eventIdentity),
            current: Self.eventIdentity(current),
            lastDeliveredAt: lastDeliveredAt,
            now: now
        )
    }

    private static func eventIdentity(_ trackInfo: TrackInfo) -> TrackEventIdentity {
        let payload = trackInfo.payload
        return TrackEventIdentity(
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            artworkDataBase64: payload.artworkDataBase64,
            bundleIdentifier: payload.bundleIdentifier,
            processID: payload.PID.map(Int.init),
            timestampEpochMicros: payload.timestampEpochMicros
        )
    }

    private static func sourceIdentity(
        for trackInfo: TrackInfo,
        preferredBundleIdentifier: String?
    ) -> SourceIdentity {
        let processID = trackInfo.payload.PID
        let resolvedBundleIdentifier: String?
        if let processID, processID > 0 {
            resolvedBundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        } else {
            resolvedBundleIdentifier = nil
        }
        let bundleIdentifier = SourceIdentityPolicy.effectiveBundleIdentifier(
            reportedBundleIdentifier: trackInfo.payload.bundleIdentifier,
            resolvedBundleIdentifier: resolvedBundleIdentifier,
            preferredBundleIdentifier: preferredBundleIdentifier
        )
        let key = bundleIdentifier
            ?? processID.map { "pid:\($0)" }
            ?? "unknown"
        return SourceIdentity(key: key, bundleIdentifier: bundleIdentifier, processID: processID)
    }
    
    deinit {
        lockExpiryWorkItem?.cancel()
        defaultsCancellables.removeAll()
        controller.stopListening()
    }
    
}
