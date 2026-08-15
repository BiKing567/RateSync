//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    private var lastTrackChangeDate: Date?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.timerCalls += 1
                if self.timerCalls >= 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    self.processQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }

        if allStats.isEmpty, let sampleRate = getSampleRateFromAppleScript() {
            let stat = CMPlayerStats(sampleRate: sampleRate, bitDepth: 24, date: Date(), priority: 1)
            allStats.append(stat)
            print("[getAllStats] AppleScript fallback: \(stat)")
        }
        
        return allStats
    }
    
    func switchLatestSampleRate(for expectedTrack: MediaTrack? = nil, recursion: Bool = false) {
        // P1: stale-task guard. The switch task is queued on the serial processQueue
        // with a snapshot of the track it was scheduled for. If the track changed
        // before the task ran, discard it - otherwise its parsed sample rate (from
        // the newer track's log entries) could be applied to the older track.
        if let expectedTrack = expectedTrack, currentTrack != expectedTrack {
            print("stale switch task for previous track, skip")
            return
        }
        var allStats = self.getAllStats()
        // Ignore logs from before the current track started playing,
        // as stale logs from the previous track cause wrong switches.
        if let lastTrackChangeDate = lastTrackChangeDate {
            // P2: recursive retries widen the tolerance window. Decoder logs can be
            // written more than 0.5s before the MediaRemote event (e.g. delayed UI
            // state updates); a strict filter would permanently discard them and,
            // if the AppleScript fallback also fails, the switch would be lost.
            let threshold = recursion ? lastTrackChangeDate.addingTimeInterval(-1.5) : lastTrackChangeDate
            allStats = allStats.filter { $0.date >= threshold }
            // If every log entry was filtered out, it may mean the new track's
            // logs are not in the window yet. Fall back to AppleScript on the
            // initial attempt so switching is not lost.
            if allStats.isEmpty, !recursion, let sampleRate = getSampleRateFromAppleScript() {
                allStats = [CMPlayerStats(sampleRate: sampleRate, bitDepth: 24, date: Date(), priority: 1)]
                print("[switchLatestSampleRate] AppleScript fallback after filtering: \(sampleRate)")
            }
        }
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice

        var didFindStat = false

        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            didFindStat = true
            let sampleRate = Float64(first.sampleRate)
            let bitDepth = Int32(first.bitDepth)

            // Same-track lock: once a sample rate has been applied for the current
            // track, never switch again within the same song unless the output
            // device itself changed (e.g. the user switched device) or, in bit
            // depth mode, the parsed bit depth actually changed within the track.
            // Multiple decoder log entries (e.g. Dolby Atmos streams) can jitter
            // between sample rates, which would otherwise cause repeated switching.
            if let currentTrack = currentTrack,
               let cachedSampleRate = trackAndSample[currentTrack],
               defaultDevice?.nominalSampleRate == cachedSampleRate {
                let bitDepthChanged = enableBitDepthDetection
                    && trackAndBitDepth[currentTrack] != Int(bitDepth)
                if !bitDepthChanged {
                    print("same track, sample rate already applied, skip")
                    return
                }
                print("same track, bit depth changed, re-applying format")
            }

            guard let defaultDevice = defaultDevice,
                  let formats = self.getFormats(device: defaultDevice) else { return }

            // https://stackoverflow.com/a/65060134
            var nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })

            let nearestBitDepth = formats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })

            if Defaults.shared.userPreferSampleRateMultiples,
               let nearestSampleRate = nearest,
               nearestSampleRate != sampleRate, supported.contains(sampleRate / 2) {
                nearest = sampleRate / 2
            }

            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })

            print("NEAREST FORMAT \(nearestFormat)")

            if let suitableFormat = nearestFormat.first {
                let sampleRateChanged = suitableFormat.mSampleRate != previousSampleRate
                let bitDepthChanged = enableBitDepthDetection && Int(suitableFormat.mBitsPerChannel) != previousBitDepth
                let formatChanged = sampleRateChanged || bitDepthChanged

                if enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                }
                else if sampleRateChanged { // bit depth disabled
                    defaultDevice.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel), runUserScript: formatChanged)
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                    self.trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
                }
            }
        }

        // Console logs may not contain the new track's format yet right after a track change.
        // Retry once shortly instead of waiting for the slower fallback timer.
        if !didFindStat && !recursion {
            processQueue.asyncAfter(deadline: .now() + 0.5) {
                self.switchLatestSampleRate(for: expectedTrack, recursion: true)
            }
        }
    }


    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?, runUserScript: Bool = true) {
        self.previousSampleRate = sampleRate
        self.previousBitDepth = bitDepth
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
        }
        if runUserScript {
            self.runUserScript(sampleRate, bitDepth: bitDepth)
        }
    }
    
    /// Shared formatted text for the menu bar label and the menu content view.
    var formattedSampleRate: String? {
        guard let currentSampleRate = currentSampleRate else { return nil }
        if enableBitDepthDetection {
            if let bitDepth = currentBitDepth {
                return String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth)
            } else {
                return String(format: "%.1f kHz / ? bit", currentSampleRate)
            }
        } else {
            return String(format: "%.1f kHz", currentSampleRate)
        }
    }

    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        // Add bit depth as second argument if available
        if let bitDepth = bitDepth {
            arguments.append(String(bitDepth))
        }
        
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
    
    func trackDidChange(_ newTrack: TrackInfo, eventDate: Date? = nil) {
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        if self.previousTrack != self.currentTrack {
            // Unlock the new track so its sample rate can be applied. The lock is
            // per-track and must not leak across replays of the same song.
            if let currentTrack = currentTrack {
                self.trackAndSample.removeValue(forKey: currentTrack)
                self.trackAndBitDepth.removeValue(forKey: currentTrack)
            }
            // Decoder log entries are timestamped when the new track starts decoding,
            // which can be slightly before the MediaRemote event arrives. Use the event
            // time minus a small tolerance, so the new track's logs pass the filter
            // while stale logs from the previous track are discarded.
            self.lastTrackChangeDate = (eventDate ?? Date()).addingTimeInterval(-0.5)
            self.renewTimer()
        }
        // Snapshot the track this task was scheduled for, so the stale-task guard
        // in switchLatestSampleRate can discard it if the track changes first.
        let trackSnapshot = MediaTrack(trackInfo: newTrack)
        processQueue.async { [unowned self] in
            self.switchLatestSampleRate(for: trackSnapshot)
        }
    }
}
