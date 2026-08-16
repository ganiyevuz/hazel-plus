import Foundation

struct WallpaperItem: Codable, Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
    var thumbnailPath: String?
    var isLooping: Bool
    var isMuted: Bool
    /// Play forward, then backward, then forward again, instead of jumping back
    /// to the start. Suits clips whose first and last frames don't match.
    var isPingPong: Bool

    init(id: UUID = UUID(), url: URL, title: String, thumbnailPath: String? = nil, isLooping: Bool = true, isMuted: Bool = true, isPingPong: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.thumbnailPath = thumbnailPath
        self.isLooping = isLooping
        self.isMuted = isMuted
        self.isPingPong = isPingPong
    }

    // Explicit so libraries written before ping-pong existed still decode.
    enum CodingKeys: String, CodingKey {
        case id, url, title, thumbnailPath, isLooping, isMuted, isPingPong
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        isLooping = try container.decodeIfPresent(Bool.self, forKey: .isLooping) ?? true
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? true
        isPingPong = try container.decodeIfPresent(Bool.self, forKey: .isPingPong) ?? false
    }

    static func == (lhs: WallpaperItem, rhs: WallpaperItem) -> Bool {
        lhs.id == rhs.id
    }
}
