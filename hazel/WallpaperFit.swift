import AVFoundation

enum WallpaperFit: String, CaseIterable, Codable {
    case fill = "Fill"
    case fit = "Fit"
    case center = "Center"
    case stretch = "Stretch"

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .center: return .resizeAspect
        case .stretch: return .resize
        }
    }
}
