//
//  MenuBarController.swift
//  RateSync
//
//  Created by Vincent Neo on 18/6/25.
//

import Observation
import Sparkle
import SwiftUI

@Observable
class MenuBarController {
    static let shared = MenuBarController()
    
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
    // Lazy so the updater is only started once the app is fully up
    // (SPUStandardUpdaterController starts SPUUpdater on init).
    @ObservationIgnored
    lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
        
        // Startup catch-up: when a track was already loaded/paused before
        // launch, no trackDidChange event will fire for it. Fetch the current
        // Now Playing track once (after letting the adapters spin up) and run
        // it through the normal track-change path, so switching starts
        // without waiting for the next track change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            outputDevices.reevaluateNowPlaying()
        }
    }
}
