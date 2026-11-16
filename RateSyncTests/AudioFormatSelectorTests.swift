import CoreAudio
import CoreAudioTypes
import XCTest

final class AudioFormatSelectorTests: XCTestCase {
    func testUsesAvailableBitDepthAtSelectedSampleRate() {
        let selectedFormat = AudioFormatSelector.nearestFormat(
            sampleRate: 44_100,
            bitDepth: 24,
            supportedSampleRates: [44_100, 96_000],
            formats: [format(sampleRate: 44_100, bitDepth: 16), format(sampleRate: 96_000, bitDepth: 24)],
            preferSampleRateMultiples: false
        )

        XCTAssertEqual(selectedFormat?.mSampleRate, 44_100)
        XCTAssertEqual(selectedFormat?.mBitsPerChannel, 16)
    }

    func testPrefersHalfRateMultipleWhenEnabled() {
        let selectedFormat = AudioFormatSelector.nearestFormat(
            sampleRate: 88_200,
            bitDepth: 24,
            supportedSampleRates: [44_100, 48_000],
            formats: [format(sampleRate: 44_100, bitDepth: 24), format(sampleRate: 48_000, bitDepth: 24)],
            preferSampleRateMultiples: true
        )

        XCTAssertEqual(selectedFormat?.mSampleRate, 44_100)
        XCTAssertEqual(selectedFormat?.mBitsPerChannel, 24)
    }

    func testReturnsNilWhenNoDeviceFormatsExist() {
        let selectedFormat = AudioFormatSelector.nearestFormat(
            sampleRate: 44_100,
            bitDepth: 16,
            supportedSampleRates: [],
            formats: [],
            preferSampleRateMultiples: false
        )

        XCTAssertNil(selectedFormat)
    }

    func testDoesNotPrioritizeAppleMusicForExplicitMonitoringSource() {
        let shouldPrioritize = AppleMusicPriorityPolicy.shouldPrioritize(
            monitoredBundleIdentifier: "com.spotify.client",
            sourceBundleIdentifier: "com.spotify.client"
        )

        XCTAssertFalse(shouldPrioritize)
    }

    func testPrioritizesAppleMusicWhenMonitoringAllApps() {
        let shouldPrioritize = AppleMusicPriorityPolicy.shouldPrioritize(
            monitoredBundleIdentifier: nil,
            sourceBundleIdentifier: "com.spotify.client"
        )

        XCTAssertTrue(shouldPrioritize)
    }

    func testDoesNotPrioritizeAppleMusicWhileTemporarySourceIsLocked() {
        let shouldPrioritize = AppleMusicPriorityPolicy.shouldPrioritize(
            monitoredBundleIdentifier: nil,
            sourceBundleIdentifier: PlayerProfile.spotify.bundleIdentifier,
            temporarySourceLockBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier
        )

        XCTAssertFalse(shouldPrioritize)
    }

    func testSelectBestBitDepthPrefersSmallestAccommodatingDepth() {
        // Target is 24-bit:
        // Has exact match 24-bit -> picks 24
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [16, 24, 32], targetDepth: 24), 24)
        // Only 16-bit and 32-bit available -> picks 32 (lossless container) instead of truncating to 16
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [16, 32], targetDepth: 24), 32)

        // Target is 16-bit:
        // Has 16-bit -> picks 16
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [16, 24, 32], targetDepth: 16), 16)
        // Device only has 24/32 -> picks smallest accommodating (24)
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [24, 32], targetDepth: 16), 24)
    }

    func testSelectBestBitDepthPicksHighestWhenAllDepthsInsufficient() {
        // Target 24-bit, device only supports 16-bit -> picks highest available (16)
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [16], targetDepth: 24), 16)
        // Target 32-bit, device supports 16/24-bit -> picks highest available (24)
        XCTAssertEqual(AudioFormatSelector.selectBestBitDepth(from: [16, 24], targetDepth: 32), 24)
        // No formats available -> returns nil
        XCTAssertNil(AudioFormatSelector.selectBestBitDepth(from: [], targetDepth: 24))
    }

    func testNearestFormatSelects32BitWhenDeviceOnlyOffers16And32At48kHzFor24BitTrack() {
        let selectedFormat = AudioFormatSelector.nearestFormat(
            sampleRate: 48_000,
            bitDepth: 24,
            supportedSampleRates: [44_100, 48_000, 96_000],
            formats: [
                format(sampleRate: 48_000, bitDepth: 16),
                format(sampleRate: 48_000, bitDepth: 32)
            ],
            preferSampleRateMultiples: false
        )

        XCTAssertEqual(selectedFormat?.mSampleRate, 48_000)
        XCTAssertEqual(selectedFormat?.mBitsPerChannel, 32, "24-bit track on 16/32-bit device must select 32-bit lossless container.")
    }

    func testExpandRangedFormatsExpandsContinuousSampleRateRangeAcrossSupportedRates() {
        var ranged = AudioStreamRangedDescription()
        ranged.mFormat = format(sampleRate: 44_100, bitDepth: 24)
        ranged.mSampleRateRange = AudioValueRange(mMinimum: 44_100, mMaximum: 96_000)

        let supportedRates: [Float64] = [44_100, 48_000, 88_200, 96_000, 192_000]
        let expanded = AudioFormatSelector.expandRangedFormats([ranged], supportedSampleRates: supportedRates)

        // Rates within 44.1 - 96 kHz must all be generated with 24-bit depth.
        let generatedRates = Set(expanded.map(\.mSampleRate))
        XCTAssertTrue(generatedRates.contains(44_100))
        XCTAssertTrue(generatedRates.contains(48_000))
        XCTAssertTrue(generatedRates.contains(88_200))
        XCTAssertTrue(generatedRates.contains(96_000))
        XCTAssertFalse(generatedRates.contains(192_000), "192 kHz exceeds the maximum range and must not be generated.")

        // AudioFormatSelector.nearestFormat requesting 48 kHz succeeds in selecting 48 kHz / 24 bit.
        let selected = AudioFormatSelector.nearestFormat(
            sampleRate: 48_000,
            bitDepth: 24,
            supportedSampleRates: supportedRates,
            formats: expanded,
            preferSampleRateMultiples: false
        )
        XCTAssertEqual(selected?.mSampleRate, 48_000)
        XCTAssertEqual(selected?.mBitsPerChannel, 24)
    }

    func testResolveAppliedBitDepthPreservesDeviceReadBackWhenBitDepthDetectionDisabled() {
        // Disabled: device physically at 32 bit, source reports 24 bit, target depth was 24 bit
        // Reported applied depth must remain 32 bit (the actual hardware state).
        let depthWhenDisabled = DeviceFormatVerification.resolveAppliedBitDepth(
            isBitDepthDetectionEnabled: false,
            sourceReportedBitDepth: 24,
            targetBitDepth: 24,
            readBackBitDepth: 32,
            currentOutputBitDepth: 32,
            previousBitDepth: 32
        )
        XCTAssertEqual(depthWhenDisabled, 32)

        // Enabled: device physically set to 24 bit, reads back 24 bit
        let depthWhenEnabled = DeviceFormatVerification.resolveAppliedBitDepth(
            isBitDepthDetectionEnabled: true,
            sourceReportedBitDepth: 24,
            targetBitDepth: 24,
            readBackBitDepth: 24,
            currentOutputBitDepth: 32,
            previousBitDepth: 32
        )
        XCTAssertEqual(depthWhenEnabled, 24)
    }

    private func format(sampleRate: Float64, bitDepth: UInt32) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = sampleRate
        format.mBitsPerChannel = bitDepth
        return format
    }
}
