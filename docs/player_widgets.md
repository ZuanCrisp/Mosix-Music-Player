# Home screen player widgets

SpotiFLAC 5.0.1 includes a native home screen player for Android and iOS,
inspired by Apple Music. Widgets share the existing playback queue and audio
handler. They display the current artwork, track, artist, and playback state.

## Adding and customizing

- **Android:** open the launcher's widget picker and add **SpotiFLAC Player**.
  Resize it for a compact, horizontal, or large artwork layout. Open the widget's
  configuration to choose artwork colors, light, or dark, and toggle the artist
  name. Reconfiguration availability depends on the launcher.
- **iOS 17 or later:** add **SpotiFLAC Player** from the home screen widget
  gallery. Small includes play/pause; medium and large also include previous
  and next. Long-press and choose **Edit Widget** for appearance and artist name.
- Choose a track in the app first. Tap the widget's artwork or text to open
  the full player. An empty widget opens the app with transport disabled.

Artwork is a static thumbnail. Updates follow track and transport changes;
there is no continuous timer or animated artwork in the home screen widget.
The operating system controls when widget updates appear.

## Native integration

`PlayerWidgetService` publishes presentation data through
`com.zarz.spotiflac/player_widget`. Artwork loading discards stale results when
tracks change. Commands are serialized and publish the latest state before
acknowledging completion. A restored session starts paused and uses the same
audio handler as the app.

Android uses `RemoteViews` and per-widget preferences. Controls call the active
Flutter engine. If the process has been killed, a control opens the activity to
restore the saved queue and execute the command.

iOS uses WidgetKit with `AudioPlaybackIntent`, shared between Runner and the
widget extension. Runner starts one headless-capable Flutter engine at process
launch; UIScene attaches the player interface to that same engine. This keeps
widget commands available before a foreground scene exists.
`player.json` and thumbnail images live in the App Group
`group.com.zarz.spotiflac`; the widget does not receive audio files.
The extension target is embedded by Runner and inherits the app's build version.

For physical iOS builds, both Runner and PlayerWidget signing profiles must
include `group.com.zarz.spotiflac`. If using another bundle identifier, update
`PLAYER_WIDGET_APP_GROUP` in all Runner configurations and
`ios/PlayerWidget/PlayerWidget.xcconfig`, together with the extension bundle ID.

## Verification

- `flutter test test/player_widget_service_test.dart`
- `flutter analyze lib/services/player_widget_service.dart lib/main.dart`
- Build Runner for an iOS simulator and verify `PlayerWidget.appex` is embedded.
- Build Android and run `PlayerWidgetTest` on an emulator to apply real
  `RemoteViews` for all layout sizes and themes.
- On devices, add widgets and check play/pause, skip, opening the player,
  cold launch, resizing, appearance, and cover changes while backgrounded.
