//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

class Defaults: ObservableObject {
    static let shared = Defaults()
    static let appleMusicBundleIdentifier = "com.apple.Music"
    static let spotifyBundleIdentifier = "com.spotify.client"
    static let neteaseMusicBundleIdentifier = "com.netease.163music"
    private let kUserPreferIconStatusBarItem = "com.biking.RateSync-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.biking.RateSync-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.biking.RateSync-Key-BitDepthDetection"
    private let kUserPreferBitDepthDisplay = "com.biking.RateSync-Key-BitDepthDisplay"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kMonitoredBundleIdentifier = "com.biking.RateSync-Key-MonitoredBundleIdentifier"
    private let kAutoEQEnabled = "com.biking.RateSync-Key-AutoEQEnabled"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferBitDepthDisplay : true,
            kUserPreferSampleRateMultiples : false,
            kMonitoredBundleIdentifier : Defaults.appleMusicBundleIdentifier,
            kAutoEQEnabled : false
        ])
        
        self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferBitDepthDisplay = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDisplay)
        self.userPreferSampleRateMultiples = UserDefaults.standard.bool(forKey: kUserPreferSampleRateMultiples)
        self.monitoredBundleIdentifier = UserDefaults.standard.string(forKey: kMonitoredBundleIdentifier)
        self.autoEQEnabled = UserDefaults.standard.bool(forKey: kAutoEQEnabled)
    }
    
    @Published var userPreferSampleRateMultiples: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferSampleRateMultiples)
        }
    }
    
    @Published var userPreferIconStatusBarItem: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferIconStatusBarItem)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }
    
    @Published var shellScriptPath: String? {
        willSet {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        }
    }

    @Published var userPreferBitDepthDisplay: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDisplay)
        }
    }

    /// Which app's playback triggers sample rate switching.
    /// `nil` means monitor every app that reports Now Playing info.
    @Published var monitoredBundleIdentifier: String? {
        willSet {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: kMonitoredBundleIdentifier)
            } else {
                UserDefaults.standard.removeObject(forKey: kMonitoredBundleIdentifier)
            }
        }
    }

    /// Auto-switch Apple Music's built-in EQ preset to match the genre of
    /// the currently playing track (Apple Music only; needs Accessibility
    /// permission for UI automation).
    @Published var autoEQEnabled: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kAutoEQEnabled)
        }
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? NSLocalizedString("Show Sample Rate", comment: "Status bar item toggle") : NSLocalizedString("Show Icon", comment: "Status bar item toggle")
        return title
    }
}
