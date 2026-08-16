import SwiftUI
import AppKit

/// Shared card geometry. 16:9 thumbnails so video stills are never letterboxed.
private enum CardMetrics {
    static let width: CGFloat = 168
    static let thumbnailHeight: CGFloat = 94
    static let cornerRadius: CGFloat = 10
    static let thumbnailCornerRadius: CGFloat = 8
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
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            caption
        }
        .padding(8)
        .frame(width: CardMetrics.width)
        .background(
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(isHovered ? 0.6 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        // Lifts on hover the way native macOS grids do, rather than only tinting.
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button(item.isLooping ? "Disable Loop" : "Enable Loop", systemImage: "repeat", action: onToggleLoop)
            Button(item.isPingPong ? "Normal Loop" : "Reverse Loop",
                   systemImage: item.isPingPong ? "arrow.right" : "arrow.left.arrow.right",
                   action: onTogglePingPong)
                // Ping-pong drives the rate by hand, which needs looping on.
                .disabled(!item.isLooping)
            Button(item.isMuted ? "Unmute" : "Mute", systemImage: item.isMuted ? "speaker.slash" : "speaker.wave.2", action: onToggleMute)
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

    private var thumbnail: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(height: CardMetrics.thumbnailHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.thumbnailCornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
            }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow
            // Resolution and size together answer "is this worth compressing?"
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // Only surface the non-default states, so the row stays quiet.
            if !item.isLooping {
                Image(systemName: "repeat.1").font(.caption2).foregroundStyle(.secondary)
            }
            if item.isPingPong {
                Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.secondary)
            }
            if !item.isMuted {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: CardMetrics.thumbnailCornerRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                .frame(height: CardMetrics.thumbnailHeight)
                .frame(maxWidth: .infinity)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                )

            Text("Add Wallpaper")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: CardMetrics.width)
        .background(
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(isHovered ? 0.5 : 0.25))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}
