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
    
    /// Monitor-source options shown in the menu. `bundleIdentifier == nil`
    /// means "every app". Extend this list to support more players.
    private struct MonitorSourceOption: Identifiable {
        let id = UUID()
        let labelKey: String
        let bundleIdentifier: String?
    }
    
    private let monitorSourceOptions: [MonitorSourceOption] = [
        MonitorSourceOption(labelKey: "Apple Music", bundleIdentifier: Defaults.appleMusicBundleIdentifier),
        MonitorSourceOption(labelKey: "Spotify", bundleIdentifier: Defaults.spotifyBundleIdentifier),
        MonitorSourceOption(labelKey: "NetEase Music", bundleIdentifier: Defaults.neteaseMusicBundleIdentifier),
        MonitorSourceOption(labelKey: "All Apps", bundleIdentifier: nil),
    ]
    
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
            } label: {
                HStack {
                    Text("Bit Depth Switching")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("Prefer Closest Sample Rate Multiple")
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.autoEQEnabled.toggle()
            } label: {
                HStack {
                    Text("Auto EQ by Genre (Apple Music)")
                    if defaults.autoEQEnabled {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("Default Device")
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
                Text("Selected Device")
            }
            
            Menu {
                ForEach(monitorSourceOptions) { option in
                    Button {
                        defaults.monitoredBundleIdentifier = option.bundleIdentifier
                        // Something may already be playing: re-evaluate it
                        // against the new source right away instead of
                        // waiting for the next MediaRemote event.
                        outputDevices.reevaluateNowPlaying()
                    } label: {
                        if defaults.monitoredBundleIdentifier == option.bundleIdentifier {
                            Image(systemName: "checkmark")
                        }
                        Text(LocalizedStringKey(option.labelKey))
                    }
                }
            } label: {
                Text("Monitor Source")
            }
            
            Menu {
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
                Button("检查更新...") {
                    UpdateChecker.shared.checkForUpdates(showUpToDate: true)
                }
            } label: {
                Text("About")
            }
            
            Menu {
                Button("Select Script...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select a script that should be invoked when sample rate changes."
                    
                    panel.begin { response in
                        let path = panel.url?.path
                        DispatchQueue.main.async { [weak defaults] in
                            defaults?.shellScriptPath = path
                        }
                    }
                }
                
                Button("Clear Selection") {
                    defaults.shellScriptPath = nil
                }
                
                Text(defaults.shellScriptPath ?? "No selection")
                
            } label: {
                Text("Scripting")
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit RateSync")
            }
        }
    }
}
