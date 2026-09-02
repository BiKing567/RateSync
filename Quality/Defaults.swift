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
    static let qqMusicBundleIdentifier = "com.tencent.QQMusicMac"
    private let kUserPreferIconStatusBarItem = "com.biking.RateSync-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.biking.RateSync-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.biking.RateSync-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kMonitoredBundleIdentifier = "com.biking.RateSync-Key-MonitoredBundleIdentifier"
    private let kAutoEQEnabled = "com.biking.RateSync-Key-AutoEQEnabled"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kMonitoredBundleIdentifier : Defaults.appleMusicBundleIdentifier,
            kAutoEQEnabled : false
        ])

        if let path = UserDefaults.standard.string(forKey: kShellScriptPath),
           !Self.isValidScriptPathAtLaunch(path) {
            UserDefaults.standard.removeObject(forKey: kShellScriptPath)
            self.shellScriptPath = nil
        } else {
            self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        }
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
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

    static func isValidScriptPathAtLaunch(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        guard fm.isExecutableFile(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path)
        if let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), rv.isSymbolicLink == true { return false }
        let resolved = url.resolvingSymlinksInPath().path
        let standardized = url.standardized.path
        if resolved != standardized { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let owner = attrs[.ownerAccountName] as? String else { return false }
        return owner == NSUserName()
    }
}
