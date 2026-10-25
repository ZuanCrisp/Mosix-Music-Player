/// Stable filter choices, independent of the currently loaded library page.
/// Aliases match both indexed formats/codecs and filename extensions.
const libraryFormatFilterAliases = <String, List<String>>{
  'flac': ['flac'],
  'mp3': ['mp3'],
  'm4a': ['m4a', 'mp4'],
  'aac': ['aac', 'mp4a'],
  'alac': ['alac'],
  'opus': ['opus'],
  'ogg': ['ogg', 'vorbis'],
  'wav': ['wav', 'wave'],
  'aiff': ['aiff', 'aif', 'aifc'],
  'ape': ['ape'],
  'wv': ['wv', 'wavpack'],
  'dsf': ['dsf'],
  'dff': ['dff'],
  'mpc': ['mpc', 'musepack'],
  'eac3': ['eac3', 'ec_3'],
  'ac3': ['ac3', 'ac_3'],
  'ac4': ['ac4', 'ac_4'],
};
