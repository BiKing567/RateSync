//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa
import OSLog

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // https://stackoverflow.com/a/66160164
    static private(set) var instance: AppDelegate! = nil
    var outputDevices: OutputDevices!
    
    func checkPermissions() {
        do {
            if try !User.current.isAdmin() {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Requires Privileges", comment: "Alert title")
                alert.informativeText = NSLocalizedString("RateSync requires Administrator privileges in order to detect each song's lossless sample rate in the Music app.", comment: "Alert message when admin privileges are required")
                alert.alertStyle = .critical
                alert.runModal()
                NSApp.terminate(self)
            }
        }
        catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Requires Privileges", comment: "Alert title")
            alert.informativeText = NSLocalizedString("RateSync could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work.", comment: "Alert message when admin check fails")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        outputDevices = MenuBarController.shared.outputDevices
        
        checkPermissions()
    }
}
