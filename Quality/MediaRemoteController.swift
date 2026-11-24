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
    // Store only the compact TrackEventIdentity (which hashes artwork instead
    // of retaining the full Base64 string) so multi-megabyte artwork is freed immediately.
    private var lastDeliveredIdentity: TrackEventIdentity?
    private var lastDeliveredAt: Date?
    private var currentSource: SourceIdentity?
    private var sourceLastSeen: [String: Date] = [:]
    private var eventGeneration = 0
    private var defaultsCancellables = Set<AnyCancellable>()
    private var lockExpiryWorkItem: DispatchWorkItem?
    private weak var outputDevices: OutputDevices?

    private struct IncomingEvent {
        let trackInfo: TrackInfo?
        let source: SourceIdentity?
    }
    private let pendingEventCoalescer = PendingTrackEventCoalescer<IncomingEvent>()
    private let pendingCoalescersLock = NSLock()
    private var pendingCoalescersByBundleID: [String: PendingTrackEventCoalescer<IncomingEvent>] = [:]

    private struct SourceIdentity: Equatable {
        let key: String
        let bundleIdentifier: String?
        let processID: pid_t?
    }
    
    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak self, weak outputDevices] trackInfo in
            self?.handle(trackInfo, outputDevices: outputDevices)
        }
    }

    func handleIncomingTrackInfoForTesting(_ trackInfo: TrackInfo?, outputDevices: OutputDevices? = nil) {
        handle(trackInfo, outputDevices: outputDevices)
    }

    private func handle(_ trackInfo: TrackInfo?, outputDevices: OutputDevices? = nil) {
        if let target = outputDevices {
            self.outputDevices = target
        }
        guard let trackInfo else {
            self.outputDevices?.clearNowPlayingTrack()
            self.outputDevices?.evaluateMultiPlayerActivity()
            return
        }
        let source = Self.sourceIdentity(for: trackInfo, preferredBundleIdentifier: nil)
        guard let bundleID = source.bundleIdentifier,
              PlayerProfile.registeredBundleIdentifiers.contains(bundleID) else {
            return
        }

        let incoming = IncomingEvent(trackInfo: trackInfo, source: source)
        let coalescer: PendingTrackEventCoalescer<IncomingEvent> = {
            pendingCoalescersLock.lock()
            defer { pendingCoalescersLock.unlock() }
            if let existing = pendingCoalescersByBundleID[bundleID] {
                return existing
            }
            let c = PendingTrackEventCoalescer<IncomingEvent>()
            pendingCoalescersByBundleID[bundleID] = c
            return c
        }()

        guard coalescer.enqueue(incoming, shouldOverwrite: { _, _ in true }) else {
            return
        }
        stateQueue.async { [weak self] in
            self?.drainPendingEvents()
        }
    }

    private func shouldAcceptTrackInfoBeforeEnqueue(_ trackInfo: TrackInfo?, source: SourceIdentity?) -> Bool {
        guard let source, let bundleIdentifier = source.bundleIdentifier else { return false }
        return PlayerProfile.registeredBundleIdentifiers.contains(bundleIdentifier)
    }

    private func drainPendingEvents() {
        while let action = pendingEventCoalescer.takeNextAction() {
            autoreleasepool {
                switch action {
                case .clear:
                    self.eventGeneration += 1
                    self.resetStateOnQueue()
                    self.outputDevices?.clearNowPlayingTrack()
                case .clearThenEvent(let incoming):
                    self.eventGeneration += 1
                    self.resetStateOnQueue()
                    self.outputDevices?.clearNowPlayingTrack()
                    self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                case .resetArbitration:
                    self.eventGeneration += 1
                    self.resetStateOnQueue()
                case .resetArbitrationThenEvent(let incoming):
                    self.eventGeneration += 1
                    self.resetStateOnQueue()
                    self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                case .event(let incoming):
                    self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                }
            }
        }

        let playerCoalescers: [PendingTrackEventCoalescer<IncomingEvent>] = {
            pendingCoalescersLock.lock()
            defer { pendingCoalescersLock.unlock() }
            return Array(pendingCoalescersByBundleID.values)
        }()

        for coalescer in playerCoalescers {
            while let action = coalescer.takeNextAction() {
                autoreleasepool {
                    switch action {
                    case .clear:
                        self.eventGeneration += 1
                        self.resetStateOnQueue()
                        self.outputDevices?.clearNowPlayingTrack()
                    case .clearThenEvent(let incoming):
                        self.eventGeneration += 1
                        self.resetStateOnQueue()
                        self.outputDevices?.clearNowPlayingTrack()
                        self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                    case .resetArbitration:
                        self.eventGeneration += 1
                        self.resetStateOnQueue()
                    case .resetArbitrationThenEvent(let incoming):
                        self.eventGeneration += 1
                        self.resetStateOnQueue()
                        self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                    case .event(let incoming):
                        self.processTrackInfoOnQueue(incoming.trackInfo, outputDevices: self.outputDevices)
                    }
                }
            }
        }
    }

    private func processTrackInfoOnQueue(_ trackInfo: TrackInfo?, outputDevices: OutputDevices?) {
        self.eventGeneration += 1

        guard let trackInfo else {
            self.resetStateOnQueue()
            outputDevices?.reevaluateNowPlaying()
            return
        }

        let source = Self.sourceIdentity(
            for: trackInfo,
            preferredBundleIdentifier: nil
        )
        guard let bundleID = source.bundleIdentifier,
              PlayerProfile.registeredBundleIdentifiers.contains(bundleID) else {
            return
        }

        let receivedAt = Date()
        self.sourceLastSeen[source.key] = receivedAt
        self.deliver(trackInfo, source: source, receivedAt: receivedAt, outputDevices: outputDevices)
    }

    private func deliver(
        _ trackInfo: TrackInfo,
        source: SourceIdentity,
        receivedAt: Date,
        outputDevices: OutputDevices?
    ) {
        let currentIdentity = Self.eventIdentity(trackInfo)
        guard !TrackEventIdentity.shouldSuppressDuplicate(
            previous: lastDeliveredIdentity,
            current: currentIdentity,
            lastDeliveredAt: lastDeliveredAt,
            now: receivedAt
        ) else { return }
        lastDeliveredIdentity = currentIdentity
        lastDeliveredAt = receivedAt
        currentSource = source
        RateSyncLog.switching.info("[Takeover] accepted \(trackInfo.payload.uniqueIdentifier) from \(source.bundleIdentifier ?? "unknown", privacy: .public)")
        outputDevices?.playerTrackInfoDidChange(trackInfo, bundleIdentifier: source.bundleIdentifier, eventDate: receivedAt)
    }

    private func pruneInactiveSources(now: Date) {
        sourceLastSeen = sourceLastSeen.filter {
            now.timeIntervalSince($0.value) <= PlayerTakeoverPolicy.defaultActivityWindow
        }
    }

    private func resetStateOnQueue() {
        lastDeliveredIdentity = nil
        lastDeliveredAt = nil
        currentSource = nil
        sourceLastSeen.removeAll()
    }

    private func resetArbitrationState() {
        guard pendingEventCoalescer.enqueueResetArbitration() else {
            return
        }
        stateQueue.async { [weak self] in
            self?.drainPendingEvents()
        }
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
            timestampEpochMicros: payload.timestampEpochMicros,
            isPlaying: payload.isPlaying
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
