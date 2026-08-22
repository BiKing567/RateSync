//
//  StatusBarLabelView.swift
//  RateSync
//

import SwiftUI

/// Self-contained MenuBarExtra label.
///
/// The icon/text preference is captured ONCE at view creation (@State) — the
/// label must never re-render from Defaults changes, because updating a
/// MenuBarExtra label in the fragile post-install window can silently drop
/// the NSStatusItem. Live rate text still updates through SampleRateLabel's
/// outputDevices observation (proven stable). Changing the icon style
/// therefore takes effect on next app launch.
struct StatusBarLabelView: View {
    @State private var showsIconOnly = Defaults.shared.userPreferIconStatusBarItem

    var body: some View {
        if showsIconOnly {
            Image(systemName: "music.note")
                .padding(.horizontal, 8)
        } else {
            SampleRateLabel()
        }
    }
}
