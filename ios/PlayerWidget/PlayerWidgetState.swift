import Foundation

struct PlayerWidgetState: Codable {
    var id = ""
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    var canPlay = false
    var canPrevious = false
    var canNext = false
    var background: UInt32 = 0xff292433
    var artworkKey = ""
    var artworkName = ""

    static let kind = "MornyePlayer"
    static var container: URL? {
        let group = Bundle.main.object(forInfoDictionaryKey: "PlayerWidgetAppGroup") as? String
            ?? "group.com.zarz.mornye"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func read() -> PlayerWidgetState {
        guard let url = container?.appendingPathComponent("player.json"),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    var artworkURL: URL? {
        guard !artworkName.isEmpty, !artworkName.contains("/") else { return nil }
        return Self.container?.appendingPathComponent(artworkName)
    }

    static var preview: PlayerWidgetState {
        var value = Self()
        value.title = "Your favorite music"
        value.artist = "Mornye"
        value.album = "Now Playing"
        value.canPlay = true
        value.canPrevious = true
        value.canNext = true
        return value
    }
}
