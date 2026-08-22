//
//  StatusBarLabelView.swift
//  RateSync
//

import SwiftUI

/// Self-contained MenuBarExtra label. Observes exactly what it renders so
/// unrelated settings toggles never rebuild the status item (macOS can drop
/// a recreated NSStatusItem silently).
struct StatusBarLabelView: View {
    @ObservedObject private var defaults = Defaults.shared

    var body: some View {
        if defaults.userPreferIconStatusBarItem {
            Image(systemName: "music.note")
                .padding(.horizontal, 8)
        } else {
            SampleRateLabel()
        }
    }
}
