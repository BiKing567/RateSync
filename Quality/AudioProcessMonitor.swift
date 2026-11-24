//
//  AudioProcessMonitor.swift
//  RateSync
//
//  Created by Vincent Neo on 1/5/22.
//

import AppKit
import CoreAudio
import Foundation
import MediaRemoteAdapter
import OSLog

protocol AudioProcessMonitoring: AnyObject {
    var onProcessActivityChanged: (() -> Void)? { get set }
    func currentAudioProcesses() -> [AudioProcessSnapshot]
    func startMonitoring()
    func stopMonitoring()
}

final class CoreAudioProcessMonitor: AudioProcessMonitoring {

    var onProcessActivityChanged: (() -> Void)?

    private let monitorQueue = DispatchQueue(label: "com.biking.RateSync.audioProcessMonitor", qos: .userInitiated)
    private var isMonitoring = false
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var observedProcessListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]

    init() {}

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        monitorQueue.async { [weak self] in
            guard let self, !self.isMonitoring else { return }
            self.isMonitoring = true
            self.registerProcessListListener()
            self.updateProcessListeners()
        }
    }

    func stopMonitoring() {
        monitorQueue.sync { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.isMonitoring = false
            self.unregisterAllListeners()
        }
    }

    func currentAudioProcesses() -> [AudioProcessSnapshot] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObj, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObj, &address, 0, nil, &size, &processIDs) == noErr else {
            return []
        }

        var snapshots: [AudioProcessSnapshot] = []
        for pidObj in processIDs {
            if let snapshot = readProcessSnapshot(pidObj) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    private func readProcessSnapshot(_ pidObj: AudioObjectID) -> AudioProcessSnapshot? {
        var pidVal: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(pidObj, &pidAddr, 0, nil, &pidSize, &pidVal) == noErr else {
            return nil
        }

        var bundleRef: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundleAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleIdentifier: String?
        if AudioObjectGetPropertyData(pidObj, &bundleAddr, 0, nil, &bundleSize, &bundleRef) == noErr,
           let ref = bundleRef {
            bundleIdentifier = ref.takeRetainedValue() as String
        }
        if bundleIdentifier == nil || bundleIdentifier?.isEmpty == true {
            bundleIdentifier = NSRunningApplication(processIdentifier: pidVal)?.bundleIdentifier
        }

        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var isRunningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(pidObj, &isRunningAddr, 0, nil, &isRunningSize, &isRunning)

        var devices: [AudioObjectID] = []
        var devSize: UInt32 = 0
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(pidObj, &devAddr, 0, nil, &devSize) == noErr && devSize > 0 {
            let devCount = Int(devSize) / MemoryLayout<AudioObjectID>.size
            devices = [AudioObjectID](repeating: 0, count: devCount)
            _ = AudioObjectGetPropertyData(pidObj, &devAddr, 0, nil, &devSize, &devices)
        } else {
            // Fall back to global scope if output scope returned no devices
            var globalDevAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(pidObj, &globalDevAddr, 0, nil, &devSize) == noErr && devSize > 0 {
                let devCount = Int(devSize) / MemoryLayout<AudioObjectID>.size
                devices = [AudioObjectID](repeating: 0, count: devCount)
                _ = AudioObjectGetPropertyData(pidObj, &globalDevAddr, 0, nil, &devSize, &devices)
            }
        }

        return AudioProcessSnapshot(
            pid: pidVal,
            bundleIdentifier: bundleIdentifier,
            isRunningOutput: isRunning > 0,
            outputDeviceIDs: devices
        )
    }

    private func registerProcessListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.monitorQueue.async {
                guard let self, self.isMonitoring else { return }
                self.updateProcessListeners()
                self.onProcessActivityChanged?()
            }
        }
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(systemObj, &address, monitorQueue, block) == noErr {
            self.processListListenerBlock = block
        }
    }

    private func updateProcessListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObj, &address, 0, nil, &size) == noErr, size > 0 else {
            return
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var currentPIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObj, &address, 0, nil, &size, &currentPIDs) == noErr else {
            return
        }

        let currentSet = Set(currentPIDs)
        // Remove dead listeners
        for (pidObj, listeners) in observedProcessListeners where !currentSet.contains(pidObj) {
            for (var addr, blk) in listeners {
                AudioObjectRemovePropertyListenerBlock(pidObj, &addr, monitorQueue, blk)
            }
            observedProcessListeners.removeValue(forKey: pidObj)
        }

        // Add listeners for registered players
        for pidObj in currentPIDs where observedProcessListeners[pidObj] == nil {
            guard let snapshot = readProcessSnapshot(pidObj),
                  let bundleID = snapshot.bundleIdentifier,
                  MultiPlayerArbitrationPolicy.registeredBundleIdentifiers.contains(bundleID) else {
                continue
            }

            var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
            let notifyBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.monitorQueue.async {
                    guard let self, self.isMonitoring else { return }
                    self.onProcessActivityChanged?()
                }
            }

            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(pidObj, &runningAddr, monitorQueue, notifyBlock) == noErr {
                listeners.append((runningAddr, notifyBlock))
            }

            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(pidObj, &devAddr, monitorQueue, notifyBlock) == noErr {
                listeners.append((devAddr, notifyBlock))
            }

            if !listeners.isEmpty {
                observedProcessListeners[pidObj] = listeners
            }
        }
    }

    private func unregisterAllListeners() {
        if let block = processListListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, monitorQueue, block)
            processListListenerBlock = nil
        }
        for (pidObj, listeners) in observedProcessListeners {
            for (var addr, blk) in listeners {
                AudioObjectRemovePropertyListenerBlock(pidObj, &addr, monitorQueue, blk)
            }
        }
        observedProcessListeners.removeAll()
    }
}

// MARK: - Playback Status Resolver

struct PlayerTrackRecord {
    let trackInfo: TrackInfo
    let bundleIdentifier: String
    let processID: pid_t?
    let recordedAt: Date
}

final class PlayerPlaybackStatusResolver {

    static let defaultMaxCacheAge: TimeInterval = 15.0

    private let appleMusic: AppleMusicService
    private let statusQueue = DispatchQueue(label: "com.biking.RateSync.playerPlaybackStatusResolver", qos: .userInitiated)

    init(appleMusic: AppleMusicService) {
        self.appleMusic = appleMusic
    }

    func resolvePlaybackStatus(
        for bundleIdentifier: String,
        activeProcessIDs: Set<pid_t>,
        latestRecord: PlayerTrackRecord?,
        maxFreshness: TimeInterval = defaultMaxCacheAge,
        completion: @escaping (PlayerPlaybackStatus) -> Void
    ) {
        statusQueue.async { [weak self] in
            guard let self else {
                completion(.unknown)
                return
            }

            // If the app is not running in NSWorkspace, it is stopped.
            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                completion(.stopped)
                return
            }

            let isValidAndFreshRecord: Bool = {
                guard let record = latestRecord else { return false }
                let effectivePID = record.processID ?? record.trackInfo.payload.PID
                return PlayerPlaybackRecordValidator.isValid(
                    recordPID: effectivePID,
                    recordTimestamp: record.recordedAt,
                    activeProcessPIDs: activeProcessIDs,
                    appProcessID: runningApp.processIdentifier,
                    appLaunchDate: runningApp.launchDate,
                    maxFreshness: maxFreshness
                )
            }()

            switch bundleIdentifier {
            case PlayerProfile.appleMusic.bundleIdentifier:
                self.appleMusic.fetchPlaybackState { state in
                    if let state {
                        completion(state.isPlaying ? .playing : .paused)
                    } else if isValidAndFreshRecord, let isPlaying = latestRecord?.trackInfo.payload.isPlaying {
                        completion(isPlaying ? .playing : .paused)
                    } else {
                        completion(.unknown)
                    }
                }

            case PlayerProfile.spotify.bundleIdentifier:
                let spotifyState = self.querySpotifyPlayerState()
                if let spotifyState {
                    switch spotifyState.lowercased() {
                    case "playing":
                        completion(.playing)
                    case "paused":
                        completion(.paused)
                    case "stopped":
                        completion(.stopped)
                    default:
                        completion(.unknown)
                    }
                } else if isValidAndFreshRecord, let isPlaying = latestRecord?.trackInfo.payload.isPlaying {
                    completion(isPlaying ? .playing : .paused)
                } else {
                    completion(.unknown)
                }

            case PlayerProfile.neteaseMusic.bundleIdentifier, PlayerProfile.qqMusic.bundleIdentifier:
                if isValidAndFreshRecord, let isPlaying = latestRecord?.trackInfo.payload.isPlaying {
                    completion(isPlaying ? .playing : .paused)
                } else if let record = latestRecord,
                          record.trackInfo.payload.isPlaying == true,
                          let effectivePID = record.processID ?? record.trackInfo.payload.PID,
                          activeProcessIDs.contains(effectivePID),
                          (effectivePID == runningApp.processIdentifier || activeProcessIDs.contains(effectivePID)),
                          (runningApp.launchDate.map { record.recordedAt >= $0 } ?? true) {
                    // Continuous playback with active audio output does not expire after 15 seconds during long tracks.
                    completion(.playing)
                } else {
                    completion(.unknown)
                }

            default:
                completion(.unknown)
            }
        }
    }

    private func querySpotifyPlayerState() -> String? {
        let script = """
        tell application "Spotify"
            if player state is playing then
                return "playing"
            else
                return "paused"
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
