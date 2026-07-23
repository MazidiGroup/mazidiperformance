import SwiftUI
import AVKit
import MazidiFoundations

/// Poster-first exercise media (asset-cdn-integration.md / 7i):
/// - The poster always loads first (soft skeleton while decoding, never a black box).
/// - The clip streams on demand as a **muted loop**; only the opened exercise animates.
/// - Under **Reduce Motion** nothing autoplays — the poster stays with a manual Play control.
/// - Missing media falls back to a name + icon card (the un-cached-clip production state).
struct ExerciseMediaView: View {
    let slug: ExerciseSlug
    let displayName: String
    let media: any MediaResolving
    /// True when this is the exercise currently on screen (drives autoplay eligibility).
    var isOpen: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFullScreen = false

    var body: some View {
        ZStack {
            if let poster = media.posterURL(for: slug) {
                PosterImage(url: poster, displayName: displayName)
            } else {
                MediaFallback(displayName: displayName)
            }

            if let clip = media.clipURL(for: slug) {
                ClipOverlay(
                    url: clip,
                    displayName: displayName,
                    autoplay: isOpen && !reduceMotion,
                    onExpand: { showFullScreen = true }
                )
            }
        }
        .aspectRatio(720.0 / 402.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
                .strokeBorder(MazidiColor.hairline, lineWidth: 1)
        )
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenClip(url: media.clipURL(for: slug), displayName: displayName)
        }
    }
}

/// Small square poster thumbnail (lists, swap rows). Poster-first with the same name+icon
/// fallback when media isn't available.
struct ExercisePosterThumbnail: View {
    let slug: ExerciseSlug
    let displayName: String
    let media: any MediaResolving
    var side: CGFloat = 52

    var body: some View {
        Group {
            if let poster = media.posterURL(for: slug) {
                PosterImage(url: poster, displayName: displayName)
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(MazidiColor.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MazidiColor.surfaceAlt)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Poster (WebP decoded off the main thread)

private struct PosterImage: View {
    let url: URL
    let displayName: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("\(displayName) demonstration poster")
            } else if failed {
                MediaFallback(displayName: displayName)
            } else {
                SkeletonBlock(height: 180)
                    .accessibilityLabel("Loading \(displayName) poster")
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Fallback (name + icon)

private struct MediaFallback: View {
    let displayName: String
    var body: some View {
        ZStack {
            MazidiColor.surfaceAlt
            VStack(spacing: MazidiMetric.tightSpacing) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 30))
                    .foregroundStyle(MazidiColor.textSecondary)
                Text(displayName)
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MazidiMetric.cardPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName). Demonstration clip not downloaded.")
    }
}

// MARK: - Clip overlay (muted loop, manual under Reduce Motion)

private struct ClipOverlay: View {
    let url: URL
    let displayName: String
    let autoplay: Bool
    let onExpand: () -> Void

    @State private var isPlaying = false

    var body: some View {
        ZStack {
            if isPlaying {
                LoopingPlayer(url: url)
                    .accessibilityLabel("\(displayName) demonstration, playing muted")
                    .accessibilityAddTraits(.startsMediaSession)
                    .onTapGesture(perform: onExpand)
            } else {
                // Play control over the poster.
                Button(action: { isPlaying = true }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .frame(width: MazidiMetric.minTarget, height: MazidiMetric.minTarget)
                }
                .accessibilityLabel("Play \(displayName) demonstration")
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                            .frame(width: MazidiMetric.minTarget, height: MazidiMetric.minTarget)
                    }
                    .accessibilityLabel("View \(displayName) full screen")
                }
                Spacer()
            }
            .padding(6)
        }
        .onAppear { if autoplay { isPlaying = true } }
        .onChange(of: autoplay) { _, newValue in isPlaying = newValue }
    }
}

/// Muted, looping AVPlayer wrapper — no controls, poster-first, streams on demand.
private struct LoopingPlayer: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .disabled(true) // gestures handled by the overlay, not system controls
            .onAppear {
                let item = AVPlayerItem(url: url)
                looper = AVPlayerLooper(player: player, templateItem: item)
                player.isMuted = true
                player.play()
            }
            .onDisappear { player.pause() }
    }
}

// MARK: - Full-screen player (7l)

private struct FullScreenClip: View {
    let url: URL?
    let displayName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                if reduceMotion {
                    // Honour Reduce Motion even full-screen: manual, single playback.
                    VideoPlayer(player: AVPlayer(url: url))
                } else {
                    LoopingPlayer(url: url)
                }
            } else {
                MediaFallback(displayName: displayName)
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.mazidiSecondary)
                        .fixedSize()
                        .padding()
                }
                Spacer()
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}
