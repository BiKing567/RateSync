import Foundation
import AppKit
import SwiftUI
import WidgetKit

private enum RateSyncWidgetStyle {
    static let readoutSpacing: CGFloat = 4
    static let signalBarWidth: CGFloat = 12
    static let signalBarHeight: CGFloat = 3
    static let signalBarRadius: CGFloat = 1.5
    static let artworkSize: CGFloat = 52
    static let artworkCornerRadius: CGFloat = 10
    static let metadataSpacing: CGFloat = 10
    static let titleArtistSpacing: CGFloat = 2
    static let metadataBottomPadding: CGFloat = 16
    static let titleFontSize: CGFloat = 20
    static let artistFontSize: CGFloat = 14
    static let sampleRateFontSize: CGFloat = 36
    static let bitDepthFontSize: CGFloat = 17
    static let mediumArtworkSize: CGFloat = 128
    static let mediumArtworkCornerRadius: CGFloat = 22
    static let mediumMetadataSpacing: CGFloat = 14
    static let mediumTitleArtistSpacing: CGFloat = 2
    static let mediumSectionSpacing: CGFloat = 8
    static let mediumTitleFontSize: CGFloat = 24
    static let mediumArtistFontSize: CGFloat = 16
    static let mediumSampleRateFontSize: CGFloat = 27
    static let mediumBitDepthFontSize: CGFloat = 14
    static let mediumReadoutSpacing: CGFloat = 2
    static var titleFont: Font {
        .system(size: titleFontSize, weight: .semibold, design: .rounded)
    }
    static var artistFont: Font {
        .system(size: artistFontSize, weight: .medium, design: .rounded)
    }
    static var sampleRateFont: Font {
        .system(size: sampleRateFontSize, weight: .semibold, design: .rounded)
    }
    static var bitDepthFont: Font {
        .system(size: bitDepthFontSize, weight: .medium, design: .rounded)
    }
    static var mediumTitleFont: Font {
        .system(size: mediumTitleFontSize, weight: .semibold, design: .rounded)
    }
    static var mediumArtistFont: Font {
        .system(size: mediumArtistFontSize, weight: .medium, design: .rounded)
    }
    static var mediumSampleRateFont: Font {
        .system(size: mediumSampleRateFontSize, weight: .semibold, design: .rounded)
    }
    static var mediumBitDepthFont: Font {
        .system(size: mediumBitDepthFontSize, weight: .medium, design: .rounded)
    }
    static let widgetSurface = Color.primary.opacity(0.045)
    static let accentGlow = Color.accentColor.opacity(0.16)
    static let sampleRateMinimumScaleFactor: CGFloat = 0.68
    static let bitDepthMinimumScaleFactor: CGFloat = 0.8
}

private enum RateSyncWidgetLayout {
    case small
    case medium

    var artworkSize: CGFloat {
        switch self {
        case .small:
            RateSyncWidgetStyle.artworkSize
        case .medium:
            RateSyncWidgetStyle.mediumArtworkSize
        }
    }

    var artworkCornerRadius: CGFloat {
        switch self {
        case .small:
            RateSyncWidgetStyle.artworkCornerRadius
        case .medium:
            RateSyncWidgetStyle.mediumArtworkCornerRadius
        }
    }

    var metadataSpacing: CGFloat {
        switch self {
        case .small:
            RateSyncWidgetStyle.metadataSpacing
        case .medium:
            RateSyncWidgetStyle.mediumMetadataSpacing
        }
    }

    var titleArtistSpacing: CGFloat {
        switch self {
        case .small:
            RateSyncWidgetStyle.titleArtistSpacing
        case .medium:
            RateSyncWidgetStyle.mediumTitleArtistSpacing
        }
    }

    var titleFont: Font {
        switch self {
        case .small:
            RateSyncWidgetStyle.titleFont
        case .medium:
            RateSyncWidgetStyle.mediumTitleFont
        }
    }

    var artistFont: Font {
        switch self {
        case .small:
            RateSyncWidgetStyle.artistFont
        case .medium:
            RateSyncWidgetStyle.mediumArtistFont
        }
    }

    var sampleRateFont: Font {
        switch self {
        case .small:
            RateSyncWidgetStyle.sampleRateFont
        case .medium:
            RateSyncWidgetStyle.mediumSampleRateFont
        }
    }

    var bitDepthFont: Font {
        switch self {
        case .small:
            RateSyncWidgetStyle.bitDepthFont
        case .medium:
            RateSyncWidgetStyle.mediumBitDepthFont
        }
    }

    var readoutSpacing: CGFloat {
        switch self {
        case .small:
            RateSyncWidgetStyle.readoutSpacing
        case .medium:
            RateSyncWidgetStyle.mediumReadoutSpacing
        }
    }

    var titleLineLimit: Int {
        switch self {
        case .small:
            1
        case .medium:
            2
        }
    }

    var formatAlignment: Alignment {
        switch self {
        case .small:
            .leading
        case .medium:
            .leading
        }
    }

    var formatHorizontalAlignment: HorizontalAlignment {
        switch self {
        case .small:
            .leading
        case .medium:
            .leading
        }
    }
}

struct RateSyncWidgetEntry: TimelineEntry {
    let date: Date
    let audioFormat: SharedAudioFormat?
    let nowPlayingTrack: SharedNowPlayingTrack?
}

struct RateSyncWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RateSyncWidgetEntry {
        RateSyncWidgetEntry(
            date: Date(),
            audioFormat: SharedAudioFormat(sampleRate: 96_000, bitDepth: 24, updatedAt: Date()),
            nowPlayingTrack: SharedNowPlayingTrack(
                title: "Song Title",
                artist: "Artist Name",
                artworkDataBase64: nil,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RateSyncWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RateSyncWidgetEntry>) -> Void) {
        let entry = currentEntry()
        completion(
            Timeline(
                entries: [entry],
                policy: .after(RateSyncWidgetConfiguration.nextRefreshDate(after: entry.date))
            )
        )
    }

    private func currentEntry() -> RateSyncWidgetEntry {
        let persistedAudioFormat = RateSyncWidgetConfiguration.loadAudioFormat()
        return RateSyncWidgetEntry(
            date: Date(),
            audioFormat: RateSyncWidgetConfiguration.widgetAudioFormat(persisted: persistedAudioFormat),
            nowPlayingTrack: RateSyncWidgetConfiguration.loadNowPlayingTrack()
        )
    }
}

private struct AlbumArtworkView: View {
    let artworkDataBase64: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        artwork
            .frame(
                width: size,
                height: size
            )
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = decodedArtwork {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.original)
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.9),
                        Color.accentColor.opacity(0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    private var decodedArtwork: NSImage? {
        guard let artworkDataBase64,
              artworkDataBase64.utf8.count <= RateSyncWidgetConfiguration.maxArtworkBase64Length,
              let data = Data(base64Encoded: artworkDataBase64) else {
            return nil
        }
        guard data.count <= RateSyncWidgetConfiguration.maxArtworkDataBytes,
              let image = NSImage(data: data),
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }
}

private struct NowPlayingMetadataView: View {
    let track: SharedNowPlayingTrack?
    let layout: RateSyncWidgetLayout

    var body: some View {
        HStack(alignment: .center, spacing: layout.metadataSpacing) {
            AlbumArtworkView(
                artworkDataBase64: track?.artworkDataBase64,
                size: layout.artworkSize,
                cornerRadius: layout.artworkCornerRadius
            )

            TrackMetadataTextView(track: track, layout: layout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TrackMetadataTextView: View {
    let track: SharedNowPlayingTrack?
    let layout: RateSyncWidgetLayout

    private var title: String {
        track?.titleText ?? NSLocalizedString("Not Playing", comment: "Widget placeholder when no track is playing")
    }

    private var artist: String {
        track?.artistText ?? NSLocalizedString("No Artist", comment: "Widget placeholder when artist is unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.titleArtistSpacing) {
            Text(title)
                .font(layout.titleFont)
                .foregroundStyle(.primary)
                .lineLimit(layout.titleLineLimit)
                .truncationMode(.tail)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: layout.titleLineLimit > 1)

            Text(artist)
                .font(layout.artistFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(artist)")
    }
}

private struct AudioFormatReadoutView: View {
    let audioFormat: SharedAudioFormat?
    let layout: RateSyncWidgetLayout

    var body: some View {
        VStack(alignment: layout.formatHorizontalAlignment, spacing: layout.readoutSpacing) {
            Text(audioFormat?.sampleRateText ?? "— kHz")
                .font(layout.sampleRateFont)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(RateSyncWidgetStyle.sampleRateMinimumScaleFactor)
                .frame(maxWidth: .infinity, alignment: layout.formatAlignment)

            HStack(alignment: .center, spacing: layout.readoutSpacing) {
                RoundedRectangle(cornerRadius: RateSyncWidgetStyle.signalBarRadius)
                    .fill(Color.accentColor)
                    .frame(
                        width: RateSyncWidgetStyle.signalBarWidth,
                        height: RateSyncWidgetStyle.signalBarHeight
                    )
                    .accessibilityHidden(true)

                Text(audioFormat?.bitDepthText ?? "— bit")
                    .font(layout.bitDepthFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(RateSyncWidgetStyle.bitDepthMinimumScaleFactor)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: layout.formatAlignment)
        }
        .frame(maxWidth: .infinity, alignment: layout.formatAlignment)
    }
}

struct RateSyncWidgetView: View {
    let entry: RateSyncWidgetEntry
    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerBackground(for: .widget) {
            ZStack(alignment: .topTrailing) {
                RateSyncWidgetStyle.widgetSurface
                RadialGradient(
                    colors: [RateSyncWidgetStyle.accentGlow, .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 120
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if widgetFamily == .systemMedium {
            HStack(alignment: .center, spacing: RateSyncWidgetStyle.mediumMetadataSpacing) {
                AlbumArtworkView(
                    artworkDataBase64: entry.nowPlayingTrack?.artworkDataBase64,
                    size: RateSyncWidgetStyle.mediumArtworkSize,
                    cornerRadius: RateSyncWidgetStyle.mediumArtworkCornerRadius
                )

                VStack(alignment: .leading, spacing: 0) {
                    TrackMetadataTextView(
                        track: entry.nowPlayingTrack,
                        layout: .medium
                    )

                    Spacer(minLength: RateSyncWidgetStyle.mediumSectionSpacing)

                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(height: 0.5)
                        .accessibilityHidden(true)

                    Spacer(minLength: RateSyncWidgetStyle.mediumSectionSpacing)

                    AudioFormatReadoutView(
                        audioFormat: entry.audioFormat,
                        layout: .medium
                    )
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                NowPlayingMetadataView(
                    track: entry.nowPlayingTrack,
                    layout: .small
                )
                .padding(.bottom, RateSyncWidgetStyle.metadataBottomPadding)

                AudioFormatReadoutView(
                    audioFormat: entry.audioFormat,
                    layout: .small
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct RateSyncWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RateSyncWidgetConfiguration.widgetKind, provider: RateSyncWidgetProvider()) { entry in
            RateSyncWidgetView(entry: entry)
        }
        .configurationDisplayName(
            LocalizedStringResource("widget.configurationDisplayName", bundle: .main)
        )
        .description(
            LocalizedStringResource("widget.configurationDescription", bundle: .main)
        )
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
