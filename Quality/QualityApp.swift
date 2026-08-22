//
//  QualityApp.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI

@main
struct QualityApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var controller = MenuBarController.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller.outputDevices)
                .environmentObject(Defaults.shared)
        } label: {
            StatusBarLabelView()
                .environmentObject(controller.outputDevices)
        }
        .menuBarExtraStyle(.menu)
    }
}
