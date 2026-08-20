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
    
    init(outputDevices: OutputDevices) {
        
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            guard let trackInfo, self.isMonitored(trackInfo) else { return }
            Logger.switching.info("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            let eventDate = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo, eventDate: eventDate)
            }
        }
        
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
