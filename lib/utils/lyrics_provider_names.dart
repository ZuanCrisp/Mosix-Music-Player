/// Display names for the built-in lyrics providers, by backend id.
const builtInLyricsProviderNames = <String, String>{
  'lrclib': 'LRCLIB',
  'netease': 'Netease',
  'musixmatch': 'Musixmatch',
  'apple_music': 'Apple Music',
  'mornye_lyrics': 'Zarz-LRC',
  'qqmusic': 'QQ Music',
  'spotify': 'Spotify',
  'deezer': 'Deezer',
  'youtube': 'YouTube',
  'kugou': 'Kugou',
  'genius': 'Genius',
  'lyricsplus': 'LyricsPlus',
  'lrcred': 'lrc.red',
  'betterlyrics': 'BetterLyrics',
};

/// A lyrics provider's name for display. [extensionNames] maps
/// `extension:<id>` to the installed extension's display name.
String lyricsProviderDisplayName(
  String provider,
  Map<String, String> extensionNames,
) =>
    builtInLyricsProviderNames[provider] ??
    extensionNames[provider] ??
    (provider.startsWith('extension:')
        ? provider.substring('extension:'.length)
        : provider);
