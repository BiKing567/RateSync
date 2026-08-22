//
//  StatusBarLabelView.swift
//  RateSync
//

import SwiftUI

/// Self-contained MenuBarExtra label. Observes Defaults directly so the
/// icon/text style toggle applies immediately. (Historic "vanishing" was the
/// MacBook notch hiding longer text — not a rendering bug.)
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
