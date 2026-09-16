//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

struct PlayerSourceLock: Equatable {
    let bundleIdentifier: String
    let expiresAt: Date?

    var isActive: Bool {
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }
}

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.biking.RateSync-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.biking.RateSync-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.biking.RateSync-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kMonitoredBundleIdentifier = "com.biking.RateSync-Key-MonitoredBundleIdentifier"
    private let kPlayerPriorityBundleIdentifiers = "com.biking.RateSync-Key-PlayerPriorityBundleIdentifiers"
    private let kTemporarySourceLockBundleIdentifier = "com.biking.RateSync-Key-TemporarySourceLockBundleIdentifier"
    private let kTemporarySourceLockExpiresAt = "com.biking.RateSync-Key-TemporarySourceLockExpiresAt"
    private let kAutoEQEnabled = "com.biking.RateSync-Key-AutoEQEnabled"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kMonitoredBundleIdentifier : PlayerProfile.appleMusic.bundleIdentifier,
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
        let storedPriority = UserDefaults.standard.array(forKey: kPlayerPriorityBundleIdentifiers) as? [String] ?? []
        self.playerPriorityBundleIdentifiers = PlayerProfile.normalizedPriority(storedPriority)
        let storedLockBundleIdentifier = UserDefaults.standard.string(forKey: kTemporarySourceLockBundleIdentifier)
        let storedLockExpiresAt = UserDefaults.standard.object(forKey: kTemporarySourceLockExpiresAt) as? Date
        if storedLockBundleIdentifier != nil,
           let storedLockExpiresAt,
           storedLockExpiresAt <= Date() {
            UserDefaults.standard.removeObject(forKey: kTemporarySourceLockBundleIdentifier)
            UserDefaults.standard.removeObject(forKey: kTemporarySourceLockExpiresAt)
            self.temporarySourceLock = nil
        } else if let storedLockBundleIdentifier {
            self.temporarySourceLock = PlayerSourceLock(
                bundleIdentifier: storedLockBundleIdentifier,
                expiresAt: storedLockExpiresAt
            )
        } else {
            self.temporarySourceLock = nil
        }
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

    /// Player order used when `monitoredBundleIdentifier` is nil.
    /// The first player wins when multiple sources report activity.
    @Published var playerPriorityBundleIdentifiers: [String] {
        willSet {
            UserDefaults.standard.set(
                PlayerProfile.normalizedPriority(newValue),
                forKey: kPlayerPriorityBundleIdentifiers
            )
        }
    }

    /// A temporary source lock overrides both the regular monitor source and
    /// the automatic priority order until it expires or is cleared.
    @Published var temporarySourceLock: PlayerSourceLock? {
        willSet {
            if let newValue {
                UserDefaults.standard.set(newValue.bundleIdentifier, forKey: kTemporarySourceLockBundleIdentifier)
                if let expiresAt = newValue.expiresAt {
                    UserDefaults.standard.set(expiresAt, forKey: kTemporarySourceLockExpiresAt)
                } else {
                    UserDefaults.standard.removeObject(forKey: kTemporarySourceLockExpiresAt)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: kTemporarySourceLockBundleIdentifier)
                UserDefaults.standard.removeObject(forKey: kTemporarySourceLockExpiresAt)
            }
        }
    }

    var activeTemporarySourceLock: PlayerSourceLock? {
        guard let temporarySourceLock, temporarySourceLock.isActive else { return nil }
        return temporarySourceLock
    }

    func lockSource(_ bundleIdentifier: String, duration: TimeInterval?) {
        let expiresAt = duration.map { Date().addingTimeInterval($0) }
        temporarySourceLock = PlayerSourceLock(bundleIdentifier: bundleIdentifier, expiresAt: expiresAt)
    }

    func clearTemporarySourceLock() {
        temporarySourceLock = nil
    }

    func movePlayerUp(_ bundleIdentifier: String) {
        var priority = PlayerProfile.normalizedPriority(playerPriorityBundleIdentifiers)
        guard let index = priority.firstIndex(of: bundleIdentifier), index > 0 else { return }
        priority.swapAt(index, index - 1)
        playerPriorityBundleIdentifiers = priority
    }

    func movePlayerDown(_ bundleIdentifier: String) {
        var priority = PlayerProfile.normalizedPriority(playerPriorityBundleIdentifiers)
        guard let index = priority.firstIndex(of: bundleIdentifier), index + 1 < priority.count else { return }
        priority.swapAt(index, index + 1)
        playerPriorityBundleIdentifiers = priority
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
        UserScriptValidator.isValid(at: path)
    }
}
