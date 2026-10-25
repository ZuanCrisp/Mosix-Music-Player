import AppIntents
import SwiftUI
import WidgetKit

enum PlayerWidgetAppearance: String, AppEnum {
    case artwork, light, dark
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .artwork: "Artwork colors", .light: "Light", .dark: "Dark",
    ]
}

struct PlayerWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Player appearance"
    static var description = IntentDescription("Choose the colors and details shown in your music widget.")
    @Parameter(title: "Appearance", default: .artwork) var appearance: PlayerWidgetAppearance
    @Parameter(title: "Show artist name", default: true) var showArtist: Bool
}

struct PlayerEntry: TimelineEntry {
    let date: Date
    let state: PlayerWidgetState
    let configuration: PlayerWidgetConfiguration
}

struct PlayerTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlayerEntry {
        PlayerEntry(date: .now, state: .preview, configuration: PlayerWidgetConfiguration())
    }

    func snapshot(for configuration: PlayerWidgetConfiguration, in context: Context) async -> PlayerEntry {
        PlayerEntry(date: .now, state: context.isPreview ? .preview : .read(), configuration: configuration)
    }

    func timeline(for configuration: PlayerWidgetConfiguration, in context: Context) async -> Timeline<PlayerEntry> {
        Timeline(entries: [PlayerEntry(date: .now, state: .read(), configuration: configuration)], policy: .never)
    }
}

struct PlayerWidgetView: View {
    let entry: PlayerEntry
    @Environment(\.widgetFamily) private var family

    private var isLight: Bool { entry.configuration.appearance == .light }
    private var foreground: Color { isLight ? Color(red: 0.10, green: 0.09, blue: 0.12) : .white }
    private var background: Color {
        switch entry.configuration.appearance {
        case .light: return Color(red: 0.96, green: 0.95, blue: 0.97)
        case .dark: return Color(red: 0.11, green: 0.10, blue: 0.13)
        case .artwork:
            let value = entry.state.background
            return Color(red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255,
                         blue: Double(value & 255) / 255)
        }
    }

    var body: some View {
        GeometryReader { bounds in
            if family == .systemMedium {
                HStack(spacing: 16) {
                    artwork.frame(width: min(116, bounds.size.height), height: min(116, bounds.size.height))
                    VStack(alignment: .leading, spacing: 8) {
                        metadata
                        Spacer(minLength: 0)
                        controls
                    }
                }
            } else if family == .systemLarge {
                VStack(alignment: .leading, spacing: 12) {
                    artwork.frame(maxWidth: .infinity, maxHeight: .infinity)
                    metadata
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        artwork.frame(width: max(44, bounds.size.height - 76), height: max(44, bounds.size.height - 76))
                        Spacer(minLength: 4)
                        Image(systemName: "music.note").font(.system(size: 19, weight: .semibold)).opacity(0.8)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 6) {
                        metadata
                        Spacer(minLength: 0)
                        control(entry.state.playing ? "pause" : "play", symbol: entry.state.playing ? "pause.fill" : "play.fill", prominent: true, enabled: entry.state.canPlay)
                    }
                }
            }
        }
        .foregroundStyle(foreground)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [background.opacity(0.88), background], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: "mornye://player"))
    }

    private var artwork: some View {
        Group {
            if let url = entry.state.artworkURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(foreground.opacity(0.08))
                    .overlay(Image(systemName: "music.note").font(.system(size: 32, weight: .medium)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.state.title.isEmpty ? "Mornye Player" : entry.state.title)
                .font(.system(size: family == .systemSmall ? 14 : 17, weight: .semibold))
                .lineLimit(family == .systemMedium ? 2 : 1)
                .minimumScaleFactor(0.85)
            if entry.configuration.showArtist {
                Text(entry.state.canPlay ? entry.state.artist : "Choose music in the app")
                    .font(.system(size: family == .systemSmall ? 12 : 14))
                    .foregroundStyle(foreground.opacity(0.7)).lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack {
            control("previous", symbol: "backward.fill", enabled: entry.state.canPlay && entry.state.canPrevious)
            Spacer(minLength: 4)
            control(entry.state.playing ? "pause" : "play", symbol: entry.state.playing ? "pause.fill" : "play.fill", prominent: true, enabled: entry.state.canPlay)
            Spacer(minLength: 4)
            control("next", symbol: "forward.fill", enabled: entry.state.canPlay && entry.state.canNext)
        }
    }

    private func control(_ action: String, symbol: String, prominent: Bool = false, enabled: Bool) -> some View {
        Button(intent: PlayerControlIntent(action == "play" || action == "pause" ? "toggle" : action)) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 19 : 20, weight: .semibold))
                .frame(width: family == .systemSmall ? 36 : 44, height: family == .systemSmall ? 36 : 44)
                .foregroundStyle(prominent ? background : foreground)
                .background(prominent ? foreground : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(action == "previous" ? "Previous track" : action == "next" ? "Next track" : action == "pause" ? "Pause" : "Play")
    }
}

@main
struct MornyePlayerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: PlayerWidgetState.kind, intent: PlayerWidgetConfiguration.self, provider: PlayerTimelineProvider()) { entry in
            PlayerWidgetView(entry: entry)
        }
        .configurationDisplayName("Mornye Player")
        .description("Your music, artwork, and playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
