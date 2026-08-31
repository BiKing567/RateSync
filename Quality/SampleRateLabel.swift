//
//  SampleRateLabel.swift
//  RateSync
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    var body: some View {
        if let text = outputDevices.formattedSampleRate {
            Text(text)
        } else {
            Text("Unknown", comment: "Placeholder shown when the current sample rate is not known")
        }
    }
}
