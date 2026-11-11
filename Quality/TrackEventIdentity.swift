import CryptoKit
import Foundation

struct TrackEventIdentity: Equatable {
    struct ArtworkDigest: Equatable {
        let utf8Count: Int
        let sha256: SHA256.Digest

        init(_ base64: String) {
            let data = Data(base64.utf8)
            self.utf8Count = data.count
            self.sha256 = SHA256.hash(data: data)
        }
    }

    let title: String?
    let artist: String?
    let album: String?
    let artworkDigest: ArtworkDigest?
    let bundleIdentifier: String?
    let processID: Int?
    let timestampEpochMicros: Double?
    let isPlaying: Bool?

    private static let duplicateWindow: TimeInterval = 0.5

    init(
        title: String?,
        artist: String?,
        album: String?,
        artworkDataBase64: String?,
        bundleIdentifier: String?,
        processID: Int?,
        timestampEpochMicros: Double?,
        isPlaying: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkDigest = artworkDataBase64.map(ArtworkDigest.init)
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.timestampEpochMicros = timestampEpochMicros
        self.isPlaying = isPlaying
    }

    static func shouldSuppressDuplicate(
        previous: TrackEventIdentity?,
        current: TrackEventIdentity,
        lastDeliveredAt: Date?,
        now: Date
    ) -> Bool {
        guard let previous,
              previous.title == current.title,
              previous.artist == current.artist,
              previous.album == current.album,
              previous.artworkDigest == current.artworkDigest,
              previous.bundleIdentifier == current.bundleIdentifier,
              previous.processID == current.processID,
              previous.isPlaying == current.isPlaying else {
            return false
        }

        if let previousTimestamp = previous.timestampEpochMicros,
           let currentTimestamp = current.timestampEpochMicros {
            return previousTimestamp == currentTimestamp
        }

        guard let lastDeliveredAt else { return true }
        return now.timeIntervalSince(lastDeliveredAt) <= duplicateWindow
    }
}
