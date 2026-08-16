import SwiftUI
import AppKit

/// Shared card geometry. 16:9 so video stills fill the frame without bars.
private enum CardMetrics {
    static let width: CGFloat = 208
    static let height: CGFloat = 117
    static let cornerRadius: CGFloat = 12
}

struct WallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let onTap: () -> Void
    let onRemove: () -> Void
    let onToggleLoop: () -> Void
    let onToggleMute: () -> Void
    let onTogglePingPong: () -> Void
    let onCompress: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var detail: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            scrim
            caption
            badges
            selectionRing
        }
        .frame(width: CardMetrics.width, height: CardMetrics.height)
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous))
        // The card itself lifts rather than tinting — closer to how native media
        // grids respond, and it reads on top of a bright thumbnail.
        .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12),
                radius: isHovered ? 10 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering }
        }
        .contextMenu {
            Button(item.isLooping ? "Disable Loop" : "Enable Loop", systemImage: "repeat", action: onToggleLoop)
            Button(item.isPingPong ? "Normal Loop" : "Reverse Loop",
                   systemImage: item.isPingPong ? "arrow.right" : "arrow.left.arrow.right",
                   action: onTogglePingPong)
                .disabled(!item.isLooping)
            Button(item.isMuted ? "Unmute" : "Mute",
                   systemImage: item.isMuted ? "speaker.slash" : "speaker.wave.2",
                   action: onToggleMute)
            Divider()
            Button("Compress for This Mac…", systemImage: "arrow.down.circle", action: onCompress)
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .help(item.title)
        .onAppear(perform: loadThumbnail)
        // Keyed on the file's identity so a compress or ping-pong render
        // refreshes the numbers instead of showing the pre-change size.
        .task(id: item.url) { await loadDetail() }
    }

    private var artwork: some View {
        Group {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: CardMetrics.width, height: CardMetrics.height)
        .clipped()
    }

    /// Keeps the caption legible over a bright or busy still.
    private var scrim: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.15), .black.opacity(0.7)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .shadow(radius: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// Only non-default states appear, so a plain wallpaper shows no clutter.
    private var badges: some View {
        VStack {
            HStack(spacing: 4) {
                if item.isPingPong { badge("arrow.left.arrow.right") }
                if !item.isLooping { badge("repeat.1") }
                if !item.isMuted { badge("speaker.wave.2.fill") }
                Spacer(minLength: 0)
            }
            .padding(8)
            Spacer(minLength: 0)
        }
    }

    private func badge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
    }

    private var selectionRing: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(8)
            }
        }
    }

    /// "3840×2160 · 49 MB", or just the size if the dimensions can't be read.
    private func loadDetail() async {
        let url = item.url
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value
        let size = await VideoCompressor.videoSize(of: url)

        var parts: [String] = []
        if let size, size.width > 0 {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let bytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let thumbnailPath = item.thumbnailPath,
                  FileManager.default.fileExists(atPath: thumbnailPath),
                  let image = NSImage(contentsOfFile: thumbnailPath) else { return }
            DispatchQueue.main.async { thumbnailImage = image }
        }
    }
}

struct AddCard: View {
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
            .fill(.quaternary.opacity(isHovered ? 0.55 : 0.3))
            .overlay(
                RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor : Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                    Text("Add Wallpaper")
                        .font(.system(size: 11))
                }
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            )
            .frame(width: CardMetrics.width, height: CardMetrics.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering }
            }
    }
}
