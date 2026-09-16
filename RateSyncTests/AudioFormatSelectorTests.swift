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

    func testUsesReportedMediaRemoteBitDepth() {
        let bitDepth = RateSwitchingPolicy.bitDepth(
            reportedByMediaRemote: 32,
            fallback: 24
        )

        XCTAssertEqual(bitDepth, 32)
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

    private func format(sampleRate: Float64, bitDepth: UInt32) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = sampleRate
        format.mBitsPerChannel = bitDepth
        return format
    }
}
