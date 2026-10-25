import AppIntents

@available(iOS 17.0, *)
struct PlayerControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Control music playback"
    static var openAppWhenRun = false

    @Parameter(title: "Action") var action: String

    init() { action = "toggle" }
    init(_ action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        #if !PLAYER_WIDGET_EXTENSION
        _ = await PlayerWidgetBridge.shared.perform(action)
        #endif
        return .result()
    }
}
