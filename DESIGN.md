# RateSync Widget Design System

## 0. Research Log

- Concrete reference: the user-provided macOS Widget screenshot; the requested direction is a compact now-playing identity above a two-level audio-format readout.
- Media reference: the familiar glanceable music-card pattern; artwork identifies the track first, while title and artist stay readable at a glance.
- WidgetKit constraint: the widget is a passive snapshot surface. Track and output changes trigger timeline reloads; the design intentionally has no continuous waveform animation.
- Skipped image-generation research: this is a native macOS Widget refinement, and the system Widget material is the source of truth.

## 1. Atmosphere & Identity

RateSync should feel like a quiet utility: one glance, one answer. The signature is a small album-art identity block followed by a restrained numeric hierarchy and a soft accent glow that gives the surface character without competing with the current audio format.

## 2. Color

| Role | Token | Native value | Usage |
|---|---|---|---|
| Surface | `surface.widget` | `Color.primary.opacity(0.045)` | Widget container base |
| Primary text | `text.primary` | `.primary` | Track title and sample rate |
| Secondary text | `text.secondary` | `.secondary` | Artist, bit depth, and unavailable state |
| Signal accent | `accent.signal` | `Color.accentColor` | Artwork fallback, format bar, and restrained glow |
| Divider | `line.widgetDivider` | `Color.primary.opacity(0.48)` | Medium metadata/readout separation; stays in the primary group in accented/glass mode |

Use system semantic colors so the widget follows macOS light/dark appearance and the user's accent color automatically. The glow is a low-opacity radial layer, not a separate palette.

## 3. Typography

| Level | Size | Weight | Treatment | Usage |
|---|---:|---|---|---|
| Track title | 20 pt | Semibold rounded | One-line tail truncation | Current song title (`RateSyncWidgetStyle.titleFont`) |
| Artist | 14 pt | Medium rounded | One-line tail truncation, secondary color | Current artist (`RateSyncWidgetStyle.artistFont`) |
| Readout | 36 pt | Semibold rounded | Monospaced digits | Sample rate (`RateSyncWidgetStyle.sampleRateFont`) |
| Detail | 17 pt | Medium rounded | Monospaced digits, secondary color | Bit depth (`RateSyncWidgetStyle.bitDepthFont`) |

### Medium family overrides

The 4×2 medium family uses the same hierarchy with more horizontal breathing room:

| Level | Size | Weight | Treatment | Usage |
|---|---:|---|---|---|
| Track title | 24 pt | Semibold rounded | Up to two lines, tail truncation | Current song title (`RateSyncWidgetStyle.mediumTitleFont`) |
| Artist | 16 pt | Medium rounded | One-line tail truncation, secondary color | Current artist (`RateSyncWidgetStyle.mediumArtistFont`) |
| Readout | 27 pt | Semibold rounded | Monospaced digits, leading aligned | Sample rate (`RateSyncWidgetStyle.mediumSampleRateFont`) |
| Detail | 14 pt | Medium rounded | Monospaced digits, leading aligned | Bit depth (`RateSyncWidgetStyle.mediumBitDepthFont`) |

## 4. Spacing & Layout

- Base unit: 4 pt (`RateSyncWidgetStyle.readoutSpacing`).
- Artwork: 52 × 52 pt with a 10 pt corner radius.
- Metadata gap: 10 pt between artwork and the title/artist stack; 2 pt between title and artist.
- Metadata-to-readout separation: 16 pt.
- Readout detail gap: 4 pt.
- Signal bar: 12 × 3 pt with a 1.5 pt radius.
- Widget content is a leading-aligned vertical stack, filling the available widget bounds.
- Keep the layout to one content column: metadata header first, format readout second, with no divider or footer row.

### Medium family

- Use a centered horizontal two-zone layout: now-playing identity on the left, audio format on the right.
- Artwork: 128 × 128 pt with a 22 pt corner radius, balancing the medium surface without crowding the right-hand hierarchy.
- Metadata gap: 14 pt between artwork and the right-hand content stack; 2 pt between title lines and artist.
- Medium content is a separated right-hand stack: larger track identity is anchored above, while the audio format sits below with 8 pt of breathing room on either side of a 1 pt semantic divider (`line.widgetDivider`).
- The divider spans exactly the right-hand content column, so its leading edge aligns with the song text and its trailing edge keeps the same safe-area inset as the artwork's leading edge.
- The medium format readout is leading-aligned within that stack, so the sample rate and bit depth share the song information's left edge instead of floating in a separate right rail.
- The medium title may occupy up to two lines; the artist remains one line.

## 5. Components

### Now Playing Metadata

- **Structure**: album artwork on the left, title above artist on the right.
- **Variants**: populated artwork, populated metadata without artwork, and unavailable (`Not Playing` / `No Artist`).
- **Artwork fallback**: accent gradient tile with a music-note symbol, so missing artwork never produces an empty block.
- **Text behavior**: the small family keeps both title and artist to one line; the medium family allows the title up to two lines while keeping the artist to one line.
- **Data boundary**: MediaRemote supplies title, artist, and artwork data; the app persists the lightweight shared state in the App Group for the widget extension.
- **Accessibility**: artwork is decorative; the title and artist combine into one spoken metadata label.

### Audio Format Readout

- **Structure**: large sample-rate text followed by a smaller bit-depth row with a short accent bar.
- **Variants**: populated (`96.0 kHz` / `24 bit`) and unavailable (`— kHz` / `— bit`).
- **Layout**: the readout sits below the now-playing block so the track identity and audio format read as two clear information tiers.
- **Accessibility**: preserve full unit labels and readable contrast through semantic colors.

## 6. Motion & Interaction

The Widget is a passive readout. There is no continuous animation: WidgetKit refreshes the snapshot after track changes, output-format changes, or the existing 10-second fallback interval. No layout properties animate.

## 7. Depth & Surface

Use layered tonal shift only: a low-contrast semantic surface plus a radial accent glow supplies depth. The medium widget's single 1 pt semantic divider is the exception to the no-border rule; keep it in WidgetKit's primary group so it remains visible in both full-color and accented/glass appearances. Do not add other custom borders or shadows.

## 8. Accessibility Constraints & Accepted Debt

- Keep the sample rate as the largest visual element in the format tier.
- Keep the title visually stronger than the artist; the medium title may use two lines, while the artist remains one line.
- Keep the bit depth secondary but never below a readable 17 pt size.
- Use semantic foreground styles for light/dark mode contrast.
- Accepted debt: raw sample-level PCM amplitude is intentionally deferred because WidgetKit is not a continuously running audio visualization surface; the large Widget family remains out of scope for this iteration.
