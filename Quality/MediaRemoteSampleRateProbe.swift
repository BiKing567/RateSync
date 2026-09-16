//
//  MediaRemoteSampleRateProbe.swift
//  RateSync
//
//  Created by BiKing567 on 16/8/26.
//
//  Reads the current sample rate / bit depth straight from the private
//  MediaRemote framework. Apps that report audio format info in their
//  Now Playing payload (Apple Music does; third-party apps may not)
//  provide these keys without needing OSLog access or admin privileges.

import Foundation
import AppKit
import OSLog
import MediaRemoteAdapter

enum MediaRemoteSampleRateProbe {
    
    private typealias MRGetNowPlayingInfoCompletion = @convention(block) (CFDictionary?) -> Void
    
    private static let mrHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    }()
    
    private static let getNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping MRGetNowPlayingInfoCompletion) -> Void)? = {
        guard let handle = mrHandle,
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            Logger.switching.info("[MRProbe] MediaRemote symbols unavailable")
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping MRGetNowPlayingInfoCompletion) -> Void).self)
    }()
    
    private typealias MRGetNowPlayingApplicationPIDCompletion = @convention(block) (Int32) -> Void
    
    private static let getNowPlayingApplicationPID: (@convention(c) (DispatchQueue, @escaping MRGetNowPlayingApplicationPIDCompletion) -> Void)? = {
        guard let handle = mrHandle,
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping MRGetNowPlayingApplicationPIDCompletion) -> Void).self)
    }()

    /// Returns the process that MediaRemote currently considers the active
    /// Now Playing source. This is deliberately a lightweight query used
    /// only when two sources compete for control.
    static func fetchActivePlayerPID(completion: @escaping (pid_t?) -> Void) {
        guard let getNowPlayingApplicationPID else {
            completion(nil)
            return
        }

        let completeOnce = OneShotCompletion<pid_t?> {
            completion($0)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            completeOnce.complete(nil)
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        getNowPlayingApplicationPID(queue) { pid in
            completeOnce.complete(pid > 0 ? pid : nil)
        }
    }
    
    // Private framework headers are not part of the SDK; the keys are
    // plain string constants known from the private MediaRemote API.
    private static let kSampleRate = "kMRMediaRemoteNowPlayingInfoSampleRate"
    private static let kBitDepth = "kMRMediaRemoteNowPlayingInfoBitDepth"
    
    /// Fetches the playing app's reported sample rate (Hz) and bit depth.
    /// Both are nil when the app does not report audio format info, or
    /// when the probe is unavailable. Completion is called on an arbitrary
    /// queue; the caller must hop back to its own serial queue if needed.
    /// A timeout guard ensures the completion always fires, so the
    /// log-based fallback chain can never be blocked by a silent probe.
    ///
    /// - Parameter expectedPID: PID of the app whose track event triggered
    ///   this probe. When another app is the currently active player (e.g.
    ///   two players running at once), the Now Playing dict belongs to that
    ///   other app, so the result is discarded to avoid cross-app data.
    static func fetchAudioFormat(expectedPID: pid_t?, completion: @escaping (Double?, Int?) -> Void) {
        guard let getNowPlayingInfo else {
            completion(nil, nil)
            return
        }
        let completeOnce = OneShotCompletion<(Double?, Int?)> {
            completion($0.0, $0.1)
        }
        // Timeout guard (1.0 s): treat a silent private-API callback as
        // "no data" so the caller's fallback chain keeps running.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            completeOnce.complete((nil, nil))
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        getNowPlayingInfo(queue) { dict in
            guard let dict = dict as? [String: Any] else {
                completeOnce.complete((nil, nil))
                return
            }
            // When we know which app triggered the event, verify it is still
            // the active player before trusting its audio format keys.
            guard let getNowPlayingApplicationPID else {
                guard RateSwitchingPolicy.shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: expectedPID) else {
                    Logger.switching.info("[MRProbe] active player PID API unavailable, ignoring unverified format")
                    completeOnce.complete((nil, nil))
                    return
                }
                completeOnce.complete(((dict[kSampleRate] as? NSNumber)?.doubleValue, (dict[kBitDepth] as? NSNumber)?.intValue))
                return
            }
            getNowPlayingApplicationPID(queue) { activePID in
                if let expectedPID, activePID != expectedPID {
                    Logger.switching.info("[MRProbe] active player PID \(activePID) != event PID \(expectedPID), ignoring")
                    completeOnce.complete((nil, nil))
                    return
                }
                let sampleRate = (dict[kSampleRate] as? NSNumber)?.doubleValue
                let bitDepth = (dict[kBitDepth] as? NSNumber)?.intValue
                if sampleRate != nil || bitDepth != nil {
                    Logger.switching.info("[MRProbe] sampleRate=\(sampleRate ?? -1) bitDepth=\(bitDepth ?? -1)")
                }
                completeOnce.complete((sampleRate, bitDepth))
            }
        }
    }

    // Now Playing dict keys used to rebuild a TrackInfo snapshot.
    private static let kTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    private static let kArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    private static let kAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
    private static let kArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private static let kArtworkMimeType = "kMRMediaRemoteNowPlayingInfoArtworkMIMEType"
    private static let kIsPlaying = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    /// Fetches a TrackInfo snapshot of whatever is currently playing,
    /// built from the Now Playing dict plus the active player's PID and
    /// bundle identifier. Used to re-evaluate switching right after the
    /// user changes the monitoring source, without waiting for the next
    /// MediaRemote event. Returns nil when nothing is playing or the
    /// probe is unavailable. Completion is called on an arbitrary queue.
    static func fetchNowPlayingInfo(completion: @escaping (TrackInfo?) -> Void) {
        guard let getNowPlayingInfo else {
            completion(nil)
            return
        }
        let completeOnce = OneShotCompletion<TrackInfo?>(completion)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
            completeOnce.complete(nil)
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        getNowPlayingInfo(queue) { dict in
            guard let dict = dict as? [String: Any] else {
                completeOnce.complete(nil)
                return
            }
            guard let getNowPlayingApplicationPID else {
                completeOnce.complete(nil)
                return
            }
            getNowPlayingApplicationPID(queue) { pid in
                guard pid > 0 else {
                    completeOnce.complete(nil)
                    return
                }
                let app = NSRunningApplication(processIdentifier: pid)
                let artworkDataBase64: String?
                if let artworkData = dict[kArtworkData] as? NSData,
                   artworkData.length <= RateSyncWidgetConfiguration.maxArtworkDataBytes {
                    artworkDataBase64 = artworkData.base64EncodedString(options: [])
                } else {
                    artworkDataBase64 = nil
                }
                let payload = TrackInfo.Payload(
                    title: dict[kTitle] as? String,
                    artist: dict[kArtist] as? String,
                    album: dict[kAlbum] as? String,
                    bundleIdentifier: app?.bundleIdentifier,
                    artworkDataBase64: artworkDataBase64,
                    artworkMimeType: dict[kArtworkMimeType] as? String,
                    PID: pid
                )
                completeOnce.complete(TrackInfo(payload: payload))
            }
        }
    }
}
