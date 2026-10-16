import Foundation
import GlintCore
import GlintSearch

/// Formatting shared by rows, the inspector and accessibility labels.
public enum Formatting {
    /// "12:04" or "1:02:09".
    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "12 minutes, 4 seconds" for VoiceOver.
    public static func spokenDuration(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.rounded(.down))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    public static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    public static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// The folder shown under a result title, with the home folder abbreviated to "~".
    public static func folder(of path: String) -> String {
        if PhotosLibraryPath.isAsset(path) { return String(localized: "Photos Library") }
        if let service = RemotePath.service(of: path) {
            let folder = RemotePath.folder(of: path)
            return folder.isEmpty ? service.displayName : service.displayName + " · " + folder
        }
        let folder = (path as NSString).deletingLastPathComponent
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    /// "Page 4", "12:04", or `nil` when the match is the whole file.
    public static func location(of locator: ChunkLocator) -> String? {
        switch locator {
        case .page(let index): String(localized: "Page \(index + 1)", comment: "PDF page number in a result")
        case .time(let start, _): timecode(start)
        case .whole, .text: nil
        }
    }
}

extension SourceInfo {
    /// Symbol for a source row: Photos library, network share, external drive or folder.
    public var symbolName: String {
        if isPhotosLibrary { return "photo.on.rectangle.angled" }
        if remote != nil { return "cloud" }
        if isNetworkVolume { return "server.rack" }
        return isExternalVolume ? "externaldrive" : "folder"
    }
}

extension MediaKind {
    /// Localized singular name ("Photo", "Video").
    public var displayName: String {
        switch self {
        case .image: String(localized: "Photo", comment: "Media kind")
        case .video: String(localized: "Video", comment: "Media kind")
        case .audio: String(localized: "Audio", comment: "Media kind")
        case .pdf: String(localized: "PDF", comment: "Media kind")
        case .document: String(localized: "Document", comment: "Media kind")
        }
    }

    /// Localized section title ("Photos", "Video moments").
    public var sectionTitle: String {
        switch self {
        case .image: String(localized: "Photos", comment: "Result section")
        case .video: String(localized: "Video Moments", comment: "Result section")
        case .audio: String(localized: "Audio", comment: "Result section")
        case .pdf: String(localized: "PDF Pages", comment: "Result section")
        case .document: String(localized: "Documents", comment: "Result section")
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        }
    }
}

/// VoiceOver labels, e.g. "Video, Beach trip, moment at 12 minutes, 4 seconds".
public enum AccessibilityText {
    public static func label(for result: SearchResult) -> String {
        let title = (result.file.name as NSString).deletingPathExtension
        var parts = [result.file.kind.displayName, title]
        switch result.match.locator {
        case .time(let start, _):
            parts.append(String(localized: "moment at \(Formatting.spokenDuration(start))", comment: "VoiceOver: time of a matched moment"))
        case .page(let index):
            parts.append(String(localized: "page \(index + 1)", comment: "VoiceOver: matched PDF page"))
        case .whole, .text:
            break
        }
        if !result.file.isIndexed {
            parts.append(String(localized: "not indexed yet", comment: "VoiceOver: result matched by name only"))
        }
        return parts.joined(separator: ", ")
    }
}
