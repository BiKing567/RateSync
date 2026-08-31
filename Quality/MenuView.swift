//
//  MenuView.swift
//  RateSync
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct MenuView: View {

    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults

    var body: some View {
        VStack {
            ContentView()

            Divider()

            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }

            Button {
                defaults.userPreferBitDepthDetection.toggle()
                outputDevices.bitDepthPreferenceDidChange()
            } label: {
                HStack {
                    Text("Bit Depth Switching", comment: "Menu toggle: switch bit depth along with sample rate")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("Prefer Closest Sample Rate Multiple", comment: "Menu toggle: fall back to a sample rate multiple the device supports")
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Menu {
                Button {
                    defaults.autoEQEnabled.toggle()
                    // Apply immediately to the current track, without waiting
                    // for the next track change.
                    if defaults.autoEQEnabled {
                        outputDevices.applyAppleMusicEQIfNeeded()
                    }
                } label: {
                    HStack {
                        Text("Auto EQ by Genre (Apple Music)", comment: "Menu toggle: auto-switch Apple Music EQ preset by genre")
                        if defaults.autoEQEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("Experimental Features", comment: "Submenu title for experimental toggles")
            }

            Menu {
                Button {
                    defaults.monitoredBundleIdentifier = Defaults.appleMusicBundleIdentifier
                    outputDevices.reevaluateNowPlaying()
                } label: {
                    if defaults.monitoredBundleIdentifier == Defaults.appleMusicBundleIdentifier {
                        Image(systemName: "checkmark")
                    }
                    Text("Apple Music", comment: "Monitoring source option: Apple Music app")
                }

                Button {
                    defaults.monitoredBundleIdentifier = Defaults.spotifyBundleIdentifier
                    outputDevices.reevaluateNowPlaying()
                } label: {
                    if defaults.monitoredBundleIdentifier == Defaults.spotifyBundleIdentifier {
                        Image(systemName: "checkmark")
                    }
                    Text("Spotify", comment: "Monitoring source option: Spotify app")
                }

                Button {
                    defaults.monitoredBundleIdentifier = Defaults.neteaseMusicBundleIdentifier
                    outputDevices.reevaluateNowPlaying()
                } label: {
                    if defaults.monitoredBundleIdentifier == Defaults.neteaseMusicBundleIdentifier {
                        Image(systemName: "checkmark")
                    }
                    Text("NetEase Music", comment: "Monitoring source option: NetEase CloudMusic app")
                }

                Button {
                    defaults.monitoredBundleIdentifier = Defaults.qqMusicBundleIdentifier
                    outputDevices.reevaluateNowPlaying()
                } label: {
                    if defaults.monitoredBundleIdentifier == Defaults.qqMusicBundleIdentifier {
                        Image(systemName: "checkmark")
                    }
                    Text("QQ Music", comment: "Monitoring source option: QQ Music app")
                }

                Button {
                    defaults.monitoredBundleIdentifier = nil
                    outputDevices.reevaluateNowPlaying()
                } label: {
                    if defaults.monitoredBundleIdentifier == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All Apps", comment: "Monitoring source option: monitor every app")
                }
            } label: {
                Text("Monitor Source", comment: "Submenu title for choosing which app to monitor")
            }

            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("Default Device", comment: "Device selection option: use the system default output device")
                }

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Button {
                        outputDevices.selectedOutputDevice = device
                        defaults.selectedDeviceUID = device.uid
                    } label: {
                        Text(device.name)
                        if outputDevices.selectedOutputDevice?.uid == device.uid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("Selected Device", comment: "Submenu title for choosing the output device")
            }

            Menu {
                Text("Version - \(currentVersion)", comment: "About menu: app version, %@ is the version string")
                Text("Build - \(currentBuild)", comment: "About menu: build number, %@ is the build string")
                Button {
                    // User-initiated check; button actions run on the main thread.
                    MenuBarController.shared.updaterController.updater.checkForUpdates()
                } label: {
                    Text("Check for Updates...", comment: "About menu: Sparkle update check button")
                }
            } label: {
                Text("About", comment: "Submenu title for version and update info")
            }

            Menu {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = NSLocalizedString("Select a script that should be invoked when sample rate changes.", comment: "Script selection panel message")

                    panel.begin { response in
                        let path = panel.url?.path
                        DispatchQueue.main.async { [weak defaults] in
                            defaults?.shellScriptPath = path
                        }
                    }
                } label: {
                    Text("Select Script...", comment: "Scripting menu: choose a shell script to run")
                }

                Button {
                    defaults.shellScriptPath = nil
                } label: {
                    Text("Clear Selection", comment: "Scripting menu: clear the chosen script")
                }

                Text(defaults.shellScriptPath ?? NSLocalizedString("No selection", comment: "Scripting menu: no script chosen yet"))

            } label: {
                Text("Scripting", comment: "Submenu title for the user script feature")
            }

            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit RateSync", comment: "Menu item: quit the app")
            }
        }
    }
}
