//
//  MenuBarController.swift
//  RateSync
//
//  Created by Vincent Neo on 18/6/25.
//

import Observation
import SwiftUI

@Observable
class MenuBarController {
    static let shared = MenuBarController()
    
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
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
        
        // Automatically check for updates shortly after launch.
        // Only prompts when a newer release is available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkForUpdates()
        }
    }
}
