//
//  MediaRemoteController.swift
//  RateSync
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
import OSLog
import MediaRemoteAdapter

class MediaRemoteController {
    
    private let controller: MediaController
    // MediaRemote emits 2-5x duplicate bursts per track change; suppress
    // those so delivery is immediate without re-triggering the pipeline.
    private var lastDeliveredTrack: TrackInfo?
    
    init(outputDevices: OutputDevices) {
        
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            guard let trackInfo, self.isMonitored(trackInfo) else { return }
            Logger.switching.info("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            guard !self.isDuplicate(of: trackInfo) else { return }
            self.lastDeliveredTrack = trackInfo
            DispatchQueue.main.async {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo, eventDate: Date())
            }
        }
        
    }

    /// `TrackInfo` is not `Equatable`; compare the identity fields instead.
    private func isDuplicate(of trackInfo: TrackInfo) -> Bool {
        guard let last = lastDeliveredTrack else { return false }
        return last.payload.title == trackInfo.payload.title
            && last.payload.artist == trackInfo.payload.artist
            && last.payload.album == trackInfo.payload.album
            && last.payload.bundleIdentifier == trackInfo.payload.bundleIdentifier
            && last.payload.PID == trackInfo.payload.PID
    }

    /// Filters Now Playing events by the user-selected monitoring source.
    /// `monitoredBundleIdentifier == nil` means monitor every app.
    /// Falls back to resolving the bundle id from the event's PID when the
    /// adapter did not include one (its PID lookup can race).
    private func isMonitored(_ trackInfo: TrackInfo) -> Bool {
        guard let monitored = Defaults.shared.monitoredBundleIdentifier else { return true }
        if trackInfo.payload.bundleIdentifier == monitored {
            return true
        }
        guard let pid = trackInfo.payload.PID, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return app.bundleIdentifier == monitored
    }
    
    deinit {
        controller.stopListening()
    }
    
}
