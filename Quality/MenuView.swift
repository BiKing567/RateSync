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

            if outputDevices.isMultiPlayerConflictActive {
                Text("Multiple players active, output 48 kHz", comment: "Status shown when multiple players are outputting audio simultaneously")
            }

            Divider()

            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }

            Toggle(isOn: $defaults.userPreferBitDepthDetection) {
                Text("Bit Depth Switching", comment: "Menu toggle: switch bit depth along with sample rate")
            }
            .onChange(of: defaults.userPreferBitDepthDetection) { _, _ in
                outputDevices.bitDepthPreferenceDidChange()
            }

            Toggle(isOn: $defaults.userPreferSampleRateMultiples) {
                Text("Prefer Closest Sample Rate Multiple", comment: "Menu toggle: fall back to a sample rate multiple the device supports")
            }

            Menu {
                Toggle(isOn: $defaults.autoEQEnabled) {
                    Text("Auto EQ by Genre (Apple Music)", comment: "Menu toggle: auto-switch Apple Music EQ preset by genre")
                }
                .onChange(of: defaults.autoEQEnabled) { _, isEnabled in
                    // Apply immediately to the current track, without waiting
                    // for the next track change.
                    if isEnabled {
                        outputDevices.applyAppleMusicEQIfNeeded()
                    }
                }
            } label: {
                Text("Experimental Features", comment: "Submenu title for experimental toggles")
            }

            Menu {
                Toggle(isOn: selectedDeviceBinding(for: nil)) {
                    Text("Default Device", comment: "Device selection option: use the system default output device")
                }

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Toggle(isOn: selectedDeviceBinding(for: device.uid)) {
                        Text(device.name)
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
                        guard response == .OK, let path = panel.url?.path else { return }
                        let isValid = UserScriptValidator.isValid(at: path)
                        DispatchQueue.main.async { [weak defaults] in
                            if isValid {
                                defaults?.shellScriptPath = path
                            } else {
                                let alert = NSAlert()
                                alert.messageText = NSLocalizedString("Invalid Script", comment: "Alert title for invalid script")
                                alert.informativeText = NSLocalizedString("The selected file is not executable, is a symlink, or is not owned by you. Please select a valid executable script.", comment: "Alert message for invalid script")
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
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

    private func selectedDeviceBinding(for uid: String?) -> Binding<Bool> {
        Binding(
            get: {
                MenuSelectionState.isSelected(
                    selectedIdentifier: outputDevices.selectedOutputDevice?.uid,
                    optionIdentifier: uid
                )
            },
            set: { isSelected in
                guard isSelected || MenuSelectionState.isSelected(
                    selectedIdentifier: outputDevices.selectedOutputDevice?.uid,
                    optionIdentifier: uid
                ) else { return }

                guard isSelected, let uid else {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                    return
                }

                guard let device = outputDevices.outputDevices.first(where: { $0.uid == uid }) else { return }
                outputDevices.selectedOutputDevice = device
                defaults.selectedDeviceUID = uid
            }
        )
    }
}
