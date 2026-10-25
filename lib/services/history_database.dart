import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/services/sqlite_helpers.dart' as sqlite;
import 'package:mosix/services/history_maintenance.dart';
import 'package:mosix/utils/isrc_utils.dart' as isrc;
import 'package:mosix/utils/ios_container_paths.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/utils/path_match_keys.dart';
import 'package:mosix/utils/audio_format_utils.dart';

final _log = AppLogger('HistoryDatabase');
final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

String? _currentContainerPath;

class HistoryLookupRequest {
  final String spotifyId;
  final String? isrc;
  final String trackName;
  final String artistName;

  const HistoryLookupRequest({
    required this.spotifyId,
    this.isrc,
    required this.trackName,
    required this.artistName,
  });

  String get lookupKey =>
      '${spotifyId.trim()}|${HistoryDatabase.normalizeIsrc(isrc)}|'
      '${HistoryDatabase.matchKeyFor(trackName, artistName)}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryLookupRequest &&
          spotifyId == other.spotifyId &&
          isrc == other.isrc &&
          trackName == other.trackName &&
          artistName == other.artistName;

  @override
  int get hashCode => Object.hash(spotifyId, isrc, trackName, artistName);
}

class HistoryBatchLookupRequest {
  final List<HistoryLookupRequest> tracks;

  const HistoryBatchLookupRequest(this.tracks);

  /// An immutable request whose hash is computed only once. Use for lists
  /// retained across widget builds; the legacy constructor remains available.
  factory HistoryBatchLookupRequest.snapshot(
    Iterable<HistoryLookupRequest> tracks,
  ) = _HistoryBatchLookupSnapshot;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HistoryBatchLookupRequest ||
        other.tracks.length != tracks.length) {
      return false;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] != other.tracks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tracks);
}

class _HistoryBatchLookupSnapshot extends HistoryBatchLookupRequest {
  _HistoryBatchLookupSnapshot(Iterable<HistoryLookupRequest> tracks)
    : super(List.unmodifiable(tracks));

  late final int _hash = Object.hashAll(tracks);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryBatchLookupRequest &&
          hashCode == other.hashCode &&
          super == other;

  @override
  int get hashCode => _hash;
}

class HistoryDatabase {
  // The FTS table is a derived, optional index and is initialized lazily after
  // the existing schema migration. The background native writer shares
  // history.db and must accept the same schema contract and
  // user_version without depending on FTS5.
  static const int schemaVersion = 15;
  static const String searchFtsTable = 'history_search_fts';
  static final HistoryDatabase instance = HistoryDatabase._init();
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();
  // null means this database connection has not attempted FTS setup yet.
  // false is a completed capability/setup result and must not be retried.
  bool? _searchFtsAvailable;

  HistoryDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(() async {
      final db = await sqlite.openAppDatabase(
        'history.db',
        version: schemaVersion,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      );
      // onCreate normally initializes this derived index. Retry once after
      // opening an existing database in case an earlier setup was
      // interrupted; unsupported SQLite builds remain on the LIKE fallback.
      _searchFtsAvailable ??= await _createSearchFts(db);
      return db;
    });
  }

  bool get searchFtsAvailable => _searchFtsAvailable ?? false;

  Future<void> _createDB(Database db, int version) async {
    _log.i('Creating database schema v$version');

    await db.execute('''
      CREATE TABLE history (
        id TEXT PRIMARY KEY,
        track_name TEXT NOT NULL,
        artist_name TEXT NOT NULL,
        album_name TEXT NOT NULL,
        album_artist TEXT,
        cover_url TEXT,
        file_path TEXT NOT NULL,
        storage_mode TEXT,
        download_tree_uri TEXT,
        saf_relative_dir TEXT,
        saf_file_name TEXT,
        saf_repaired INTEGER,
        service TEXT NOT NULL,
        downloaded_at TEXT NOT NULL,
        isrc TEXT,
        spotify_id TEXT,
        track_number INTEGER,
        total_tracks INTEGER,
        disc_number INTEGER,
        total_discs INTEGER,
        duration INTEGER,
        release_date TEXT,
        quality TEXT,
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        format TEXT,
        genre TEXT,
        composer TEXT,
        label TEXT,
        copyright TEXT,
        explicit INTEGER NOT NULL DEFAULT 0,
        has_lyrics INTEGER NOT NULL DEFAULT 0,
        lyrics_metadata_scan_version INTEGER NOT NULL DEFAULT 0,
        has_replaygain INTEGER NOT NULL DEFAULT 0,
        replaygain_metadata_scan_version INTEGER NOT NULL DEFAULT 0,
        spotify_id_norm TEXT,
        isrc_norm TEXT,
        match_key TEXT,
        album_key TEXT,
        search_text TEXT,
        sort_track TEXT,
        sort_artist TEXT,
        sort_album TEXT,
        sort_album_artist TEXT,
        sort_genre TEXT,
        sort_release TEXT,
        sort_added INTEGER
      )
    ''');

    await db.execute('CREATE INDEX idx_spotify_id ON history(spotify_id)');
    await db.execute('CREATE INDEX idx_isrc ON history(isrc)');
    await db.execute(
      'CREATE INDEX idx_downloaded_at ON history(downloaded_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_album ON history(album_name, album_artist)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_track_artist ON history(track_name, artist_name)',
    );
    await _createNormalizedIndexes(db);
    await _createQueueIndexes(db);
    await _createPathKeyTable(db);
    _searchFtsAvailable = await _createSearchFts(db);

    _log.i('Database schema created with indexes');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading database from v$oldVersion to v$newVersion');
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE history ADD COLUMN storage_mode TEXT');
      await db.execute('ALTER TABLE history ADD COLUMN download_tree_uri TEXT');
      await db.execute('ALTER TABLE history ADD COLUMN saf_relative_dir TEXT');
      await db.execute('ALTER TABLE history ADD COLUMN saf_file_name TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE history ADD COLUMN saf_repaired INTEGER');
    }
    if (oldVersion < 4) {
      final columns = await db.rawQuery('PRAGMA table_info(history)');
      final hasComposer = columns.any(
        (row) => (row['name']?.toString().toLowerCase() ?? '') == 'composer',
      );
      if (!hasComposer) {
        await db.execute('ALTER TABLE history ADD COLUMN composer TEXT');
      }
    }
    if (oldVersion < 5) {
      final columns = await db.rawQuery('PRAGMA table_info(history)');
      final hasTotalTracks = columns.any(
        (row) =>
            (row['name']?.toString().toLowerCase() ?? '') == 'total_tracks',
      );
      final hasTotalDiscs = columns.any(
        (row) => (row['name']?.toString().toLowerCase() ?? '') == 'total_discs',
      );
      if (!hasTotalTracks) {
        await db.execute('ALTER TABLE history ADD COLUMN total_tracks INTEGER');
      }
      if (!hasTotalDiscs) {
        await db.execute('ALTER TABLE history ADD COLUMN total_discs INTEGER');
      }
    }
    if (oldVersion < 6) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_history_track_artist ON history(track_name, artist_name)',
      );
    }
    if (oldVersion < 7) {
      await _createPathKeyTable(db);
    }
    if (oldVersion < 8) {
      await sqlite.addColumnIfMissing(db, 'history', 'spotify_id_norm', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'isrc_norm', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'match_key', 'TEXT');
    }
    if (oldVersion < 9) {
      await sqlite.addColumnIfMissing(db, 'history', 'bitrate', 'INTEGER');
      await sqlite.addColumnIfMissing(db, 'history', 'format', 'TEXT');
    }
    if (oldVersion < 10) {
      await sqlite.addColumnIfMissing(db, 'history', 'album_key', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'search_text', 'TEXT');
      await _backfillNormalizedColumns(db);
      await _createNormalizedIndexes(db);
    }
    if (oldVersion < 11) {
      await sqlite.addColumnIfMissing(db, 'history', 'sort_track', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'sort_artist', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'sort_album', 'TEXT');
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'sort_album_artist',
        'TEXT',
      );
      await sqlite.addColumnIfMissing(db, 'history', 'sort_genre', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'sort_release', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'history', 'sort_added', 'INTEGER');
      await _backfillQueueSortColumns(db);
      await _createQueueIndexes(db);
      _log.i('Added persisted queue sort columns');
    }
    if (oldVersion < 12) {
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'explicit',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added explicit-content metadata');
    }
    if (oldVersion < 13) {
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'has_lyrics',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'lyrics_metadata_scan_version',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added indexed lyrics availability metadata');
    }
    if (oldVersion < 14) {
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'has_replaygain',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await sqlite.addColumnIfMissing(
        db,
        'history',
        'replaygain_metadata_scan_version',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added indexed ReplayGain availability metadata');
    }
    if (oldVersion < 15) {
      await sqlite.backfillPathKeys(db, 'history', 'history_path_keys');
      _log.i('Updated history path keys with provider document identities');
    }
  }

  Future<bool> _createSearchFts(DatabaseExecutor db) {
    return sqlite.createTrigramFtsIndex(
      db,
      ftsTable: searchFtsTable,
      contentTable: 'history',
      triggerPrefix: 'history_search_fts',
    );
  }

  static String normalizeLookupText(String? value) =>
      sqlite.normalizeLookupText(value);

  static String normalizeIsrc(String? value) => isrc.normalizeIsrc(value);

  static String normalizeSpotifyId(String? value) {
    return (value ?? '').trim().toLowerCase();
  }

  static String matchKeyFor(String? trackName, String? artistName) {
    final track = normalizeLookupText(trackName);
    if (track.isEmpty) return '';
    return '$track|${normalizeLookupText(artistName)}';
  }

  static List<String> spotifyLookupCandidates(String? rawId) {
    final trimmed = rawId?.trim() ?? '';
    if (trimmed.isEmpty) return const [];
    final candidates = <String>{trimmed};
    final lowered = trimmed.toLowerCase();
    if (lowered.startsWith('spotify:track:')) {
      final compact = trimmed.split(':').last.trim();
      if (compact.isNotEmpty) candidates.add(compact);
    } else if (!trimmed.contains(':')) {
      candidates.add('spotify:track:$trimmed');
    }
    final uri = Uri.tryParse(trimmed);
    final segments = uri?.pathSegments ?? const <String>[];
    final trackIndex = segments.indexOf('track');
    if (trackIndex >= 0 && trackIndex + 1 < segments.length) {
      final pathId = segments[trackIndex + 1].trim();
      if (pathId.isNotEmpty) {
        candidates.add(pathId);
        candidates.add('spotify:track:$pathId');
      }
    }
    return candidates.toList(growable: false);
  }

  Future<void> _createNormalizedIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_spotify_id_norm ON history(spotify_id_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_isrc_norm ON history(isrc_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_match_key ON history(match_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_album_key ON history(album_key)',
    );
  }

  Future<void> _createQueueIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_added ON history(sort_added DESC, sort_track, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_track ON history(sort_track, sort_artist, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_artist ON history(sort_artist, sort_track, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_album ON history(sort_album, sort_track, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_genre ON history(sort_genre, sort_track, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_queue_release ON history(sort_release, sort_track, id)',
    );
  }

  Future<void> _backfillNormalizedColumns(Database db) async {
    final rows = await db.query(
      'history',
      columns: [
        'id',
        'spotify_id',
        'isrc',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'history',
        _normalizedColumns(
          spotifyId: row['spotify_id'] as String?,
          isrc: row['isrc'] as String?,
          trackName: row['track_name'] as String?,
          artistName: row['artist_name'] as String?,
          albumName: row['album_name'] as String?,
          albumArtist: row['album_artist'] as String?,
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _normalizedColumns({
    required String? spotifyId,
    required String? isrc,
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
  }) {
    final normalizedTrack = normalizeLookupText(trackName);
    final normalizedArtist = normalizeLookupText(artistName);
    final normalizedAlbum = normalizeLookupText(albumName);
    final normalizedAlbumArtist = normalizeLookupText(
      (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
    );
    return {
      'spotify_id_norm': normalizeSpotifyId(spotifyId),
      'isrc_norm': normalizeIsrc(isrc),
      'match_key': matchKeyFor(trackName, artistName),
      'album_key': '$normalizedAlbum|$normalizedAlbumArtist',
      'search_text': [
        normalizedTrack,
        normalizedArtist,
        normalizedAlbum,
        normalizedAlbumArtist,
      ].where((value) => value.isNotEmpty).join(' '),
    };
  }

  Map<String, dynamic> _queueSortColumns({
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
    required String? genre,
    required String? releaseDate,
    required Object? downloadedAt,
  }) {
    final parsedDownloadedAt = downloadedAt is DateTime
        ? downloadedAt
        : DateTime.tryParse(downloadedAt?.toString() ?? '');
    return {
      'sort_track': normalizeLookupText(trackName),
      'sort_artist': normalizeLookupText(artistName),
      'sort_album': normalizeLookupText(albumName),
      'sort_album_artist': normalizeLookupText(
        (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
      ),
      'sort_genre': normalizeLookupText(genre),
      'sort_release': releaseDate?.trim() ?? '',
      'sort_added': parsedDownloadedAt?.millisecondsSinceEpoch ?? 0,
    };
  }

  Future<void> _backfillQueueSortColumns(Database db) async {
    final rows = await db.query(
      'history',
      columns: [
        'id',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
        'genre',
        'release_date',
        'downloaded_at',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'history',
        _queueSortColumns(
          trackName: row['track_name'] as String?,
          artistName: row['artist_name'] as String?,
          albumName: row['album_name'] as String?,
          albumArtist: row['album_artist'] as String?,
          genre: row['genre'] as String?,
          releaseDate: row['release_date'] as String?,
          downloadedAt: row['downloaded_at'],
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _createPathKeyTable(DatabaseExecutor db) =>
      sqlite.createPathKeyTable(db, 'history_path_keys');

  void _putPathKeysInBatch(Batch batch, String id, String? filePath) =>
      sqlite.putPathKeysInBatch(batch, 'history_path_keys', id, filePath);

  Future<void> _initContainerPath() async {
    if (!Platform.isIOS || _currentContainerPath != null) return;

    try {
      final docDir = await getApplicationDocumentsDirectory();
      _currentContainerPath = docDir.parent.path;
      _log.d('iOS container path: $_currentContainerPath');
    } catch (e) {
      _log.w('Failed to get iOS container path: $e');
    }
  }

  String _normalizeIosPath(String? filePath) {
    if (filePath == null || filePath.isEmpty) return filePath ?? '';
    if (!Platform.isIOS || _currentContainerPath == null) return filePath;

    return rebaseIosSandboxPath(filePath, '$_currentContainerPath/Documents');
  }

  Future<bool> migrateIosContainerPaths() async {
    if (!Platform.isIOS) return false;

    await _initContainerPath();
    if (_currentContainerPath == null) return false;

    final prefs = await _prefs;
    final lastContainer = prefs.getString('ios_last_container_path');

    if (lastContainer == _currentContainerPath) {
      _log.d('iOS container path unchanged, skipping migration');
      return false;
    }

    _log.i('iOS container changed: $lastContainer -> $_currentContainerPath');

    try {
      final db = await database;

      final rows = await db.query('history', columns: ['id', 'file_path']);
      int updatedCount = 0;
      final batch = db.batch();

      for (final row in rows) {
        final id = row['id'] as String;
        final oldPath = row['file_path'] as String?;

        if (oldPath != null) {
          final newPath = _normalizeIosPath(oldPath);
          if (newPath != oldPath) {
            batch.update(
              'history',
              {'file_path': newPath},
              where: 'id = ?',
              whereArgs: [id],
            );
            _putPathKeysInBatch(batch, id, newPath);
            updatedCount++;
          }
        }
      }

      if (updatedCount > 0) {
        await batch.commit(noResult: true);
      }

      await prefs.setString('ios_last_container_path', _currentContainerPath!);

      _log.i('iOS path migration complete: $updatedCount paths updated');
      return updatedCount > 0;
    } catch (e, stack) {
      _log.e('iOS path migration failed: $e', e, stack);
      return false;
    }
  }

  Future<bool> migrateFromSharedPreferences() async {
    final prefs = await _prefs;
    final migrationKey = 'history_migrated_to_sqlite';

    if (prefs.getBool(migrationKey) == true) {
      _log.d('Already migrated to SQLite');
      return false;
    }

    final jsonStr = prefs.getString('download_history');
    if (jsonStr == null || jsonStr.isEmpty) {
      _log.d('No SharedPreferences history to migrate');
      await prefs.setBool(migrationKey, true);
      return false;
    }

    try {
      final jsonList = List<dynamic>.from(jsonDecode(jsonStr) as List);
      _log.i(
        'Migrating ${jsonList.length} items from SharedPreferences to SQLite',
      );

      final db = await database;
      final batch = db.batch();

      for (final json in jsonList) {
        final map = Map<String, dynamic>.from(json as Map);
        batch.insert(
          'history',
          _jsonToDbRow(map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          map['id'] as String,
          map['filePath'] as String?,
        );
      }

      await batch.commit(noResult: true);

      await prefs.setBool(migrationKey, true);
      _log.i('Migration complete: ${jsonList.length} items');

      return true;
    } catch (e, stack) {
      _log.e('Migration failed: $e', e, stack);
      return false;
    }
  }

  Map<String, dynamic> _jsonToDbRow(Map<String, dynamic> json) {
    final downloadedAt = json['downloadedAt'];
    final parsedDownloadedAt = downloadedAt is DateTime
        ? downloadedAt
        : DateTime.tryParse(downloadedAt?.toString() ?? '');
    final row = {
      'id': json['id'],
      'track_name': json['trackName'],
      'artist_name': json['artistName'],
      'album_name': json['albumName'],
      'album_artist': json['albumArtist'],
      'cover_url': json['coverUrl'],
      'file_path': json['filePath'],
      'storage_mode': json['storageMode'],
      'download_tree_uri': json['downloadTreeUri'],
      'saf_relative_dir': json['safRelativeDir'],
      'saf_file_name': json['safFileName'],
      'saf_repaired': json['safRepaired'] == true ? 1 : 0,
      'service': json['service'],
      'downloaded_at':
          parsedDownloadedAt?.toUtc().toIso8601String() ??
          downloadedAt?.toString(),
      'isrc': json['isrc'],
      'spotify_id': json['spotifyId'],
      'track_number': json['trackNumber'],
      'total_tracks': json['totalTracks'],
      'disc_number': json['discNumber'],
      'total_discs': json['totalDiscs'],
      'duration': json['duration'],
      'release_date': json['releaseDate'],
      'quality': json['quality'],
      'bit_depth': json['bitDepth'],
      'sample_rate': json['sampleRate'],
      'bitrate': json['bitrate'],
      'format': json['format'],
      'genre': json['genre'],
      'composer': json['composer'],
      'label': json['label'],
      'copyright': json['copyright'],
      'explicit': json['explicit'] == true ? 1 : 0,
      'has_lyrics': json['hasLyrics'] == true ? 1 : 0,
      'lyrics_metadata_scan_version':
          (json['lyricsMetadataScanVersion'] as num?)?.toInt() ??
          (json.containsKey('hasLyrics') ? 1 : 0),
      'has_replaygain': metadataHasReplayGain(json) ? 1 : 0,
      'replaygain_metadata_scan_version':
          (json['replayGainMetadataScanVersion'] as num?)?.toInt() ?? 0,
    };
    row.addAll(
      _queueSortColumns(
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        releaseDate: json['releaseDate'] as String?,
        downloadedAt: parsedDownloadedAt,
      ),
    );
    row.addAll(
      _normalizedColumns(
        spotifyId: json['spotifyId'] as String?,
        isrc: json['isrc'] as String?,
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
      ),
    );
    return row;
  }

  Map<String, dynamic> _dbRowToJson(Map<String, dynamic> row) {
    return {
      'id': row['id'],
      'trackName': row['track_name'],
      'artistName': row['artist_name'],
      'albumName': row['album_name'],
      'albumArtist': row['album_artist'],
      'coverUrl': row['cover_url'],
      'filePath': _normalizeIosPath(row['file_path'] as String?),
      'storageMode': row['storage_mode'],
      'downloadTreeUri': row['download_tree_uri'],
      'safRelativeDir': row['saf_relative_dir'],
      'safFileName': row['saf_file_name'],
      'safRepaired': row['saf_repaired'] == 1 || row['saf_repaired'] == true,
      'service': row['service'],
      'downloadedAt': row['downloaded_at'],
      'isrc': row['isrc'],
      'spotifyId': row['spotify_id'],
      'trackNumber': row['track_number'],
      'totalTracks': row['total_tracks'],
      'discNumber': row['disc_number'],
      'totalDiscs': row['total_discs'],
      'duration': row['duration'],
      'releaseDate': row['release_date'],
      'quality': row['quality'],
      'bitDepth': row['bit_depth'],
      'sampleRate': row['sample_rate'],
      'bitrate': row['bitrate'],
      'format': row['format'],
      'genre': row['genre'],
      'composer': row['composer'],
      'label': row['label'],
      'copyright': row['copyright'],
      'explicit': row['explicit'] == 1 || row['explicit'] == true,
      'hasLyrics': row['has_lyrics'] == 1 || row['has_lyrics'] == true,
      'lyricsMetadataScanVersion': row['lyrics_metadata_scan_version'] ?? 0,
      'hasReplayGain':
          row['has_replaygain'] == 1 || row['has_replaygain'] == true,
      'replayGainMetadataScanVersion':
          row['replaygain_metadata_scan_version'] ?? 0,
    };
  }

  Future<void> upsert(Map<String, dynamic> json) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'history',
        _jsonToDbRow(json),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        json['id'] as String,
        json['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertBatch(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'history',
          _jsonToDbRow(json),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> replaceAll(Stream<Map<String, dynamic>> items) async =>
      replaceHistoryRows(await database, items.map(_jsonToDbRow));

  Future<Set<String>> updateExistingBatch(
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) return const {};
    final db = await database;
    return db.transaction(
      (txn) => updateExistingHistoryRows(txn, items.map(_jsonToDbRow)),
    );
  }

  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      'history',
      orderBy: 'sort_added DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_dbRowToJson).toList();
  }

  Future<List<Map<String, dynamic>>> getAlbumTracks(
    String albumName,
    String artistName,
  ) async {
    final db = await database;
    final albumKey =
        '${normalizeLookupText(albumName)}|${normalizeLookupText(artistName)}';
    final rows = await db.query(
      'history',
      where: 'album_key = ?',
      whereArgs: [albumKey],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<Map<String, dynamic>?> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final key = matchKeyFor(trackName, artistName);
    if (key.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'history',
      where: 'match_key = ?',
      whereArgs: [key],
      orderBy: 'sort_added DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      'history',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> findByFilePath(String filePath) async {
    final pathKeys = buildPathMatchKeys(filePath).toList(growable: false);
    if (pathKeys.isEmpty) return null;

    final db = await database;
    final placeholders = List.filled(pathKeys.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT h.*
      FROM history h
      JOIN history_path_keys hpk ON hpk.item_id = h.id
      WHERE hpk.path_key IN ($placeholders)
      ORDER BY h.sort_added DESC, h.id DESC
      LIMIT 1
      ''', pathKeys);
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<List<String>> getPhysicalFileIds(Iterable<String> filePaths) async =>
      sqlite.findPhysicalFileRowIds(await database, 'history', filePaths);

  Future<Map<String, dynamic>?> getBySpotifyId(String spotifyId) async {
    final db = await database;
    final rows = await db.query(
      'history',
      where: 'spotify_id = ?',
      whereArgs: [spotifyId],
      orderBy: 'sort_added DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> getByIsrc(String isrc) async {
    final db = await database;
    final rows = await db.query(
      'history',
      where: 'isrc = ?',
      whereArgs: [isrc],
      orderBy: 'sort_added DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> findExistingTrack(
    HistoryLookupRequest request, {
    List<String>? columns,
  }) async {
    final db = await database;
    final spotifyCandidates = spotifyLookupCandidates(request.spotifyId);
    if (spotifyCandidates.isNotEmpty) {
      final placeholders = List.filled(spotifyCandidates.length, '?').join(',');
      final normalized = spotifyCandidates.map(normalizeSpotifyId).toList();
      final rows = await db.query(
        'history',
        columns: columns,
        where:
            'spotify_id IN ($placeholders) OR spotify_id_norm IN ($placeholders)',
        whereArgs: [...spotifyCandidates, ...normalized],
        orderBy: 'sort_added DESC, id DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) return _dbRowToJson(rows.first);
    }

    final isrcNorm = normalizeIsrc(request.isrc);
    if (isrcNorm.isNotEmpty) {
      final rows = await db.query(
        'history',
        columns: columns,
        where: 'isrc_norm = ?',
        whereArgs: [isrcNorm],
        orderBy: 'sort_added DESC, id DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) return _dbRowToJson(rows.first);
    }

    final matchKey = matchKeyFor(request.trackName, request.artistName);
    if (matchKey.isNotEmpty) {
      final rows = await db.query(
        'history',
        columns: columns,
        where: 'match_key = ?',
        whereArgs: [matchKey],
        orderBy: 'sort_added DESC, id DESC',
        limit: 1,
      );
      if (rows.isNotEmpty) return _dbRowToJson(rows.first);
    }
    return null;
  }

  /// Batch variant used by playlist playback and bulk existence checks. A
  /// compact candidates CTE resolves all identifiers in one indexed lookup per
  /// bounded chunk, returning only the id/path reference those callers need.
  Future<List<Map<String, dynamic>?>> findExistingTracks(
    List<HistoryLookupRequest> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final db = await database;
    final results = List<Map<String, dynamic>?>.filled(requests.length, null);
    const requestChunkSize = 80;

    for (
      var chunkStart = 0;
      chunkStart < requests.length;
      chunkStart += requestChunkSize
    ) {
      final chunkEnd = (chunkStart + requestChunkSize).clamp(
        0,
        requests.length,
      );
      final chunk = requests.sublist(chunkStart, chunkEnd);
      final candidateRows = <String>[];
      final args = <Object?>[];

      void addCandidate(
        int requestIndex,
        int priority,
        String kind,
        String value,
      ) {
        if (value.isEmpty) return;
        candidateRows.add("($requestIndex, $priority, '$kind', ?)");
        args.add(value);
      }

      for (var requestIndex = 0; requestIndex < chunk.length; requestIndex++) {
        final request = chunk[requestIndex];
        var priority = 0;
        final seen = <String>{};
        for (final candidate in spotifyLookupCandidates(request.spotifyId)) {
          final exactKey = 'spotify_id\u0000$candidate';
          if (candidate.isNotEmpty && seen.add(exactKey)) {
            addCandidate(requestIndex, priority++, 'spotify_id', candidate);
          }
          final normalized = normalizeSpotifyId(candidate);
          final normalizedKey = 'spotify_id_norm\u0000$normalized';
          if (normalized.isNotEmpty && seen.add(normalizedKey)) {
            addCandidate(
              requestIndex,
              priority++,
              'spotify_id_norm',
              normalized,
            );
          }
        }
        addCandidate(
          requestIndex,
          priority++,
          'isrc_norm',
          normalizeIsrc(request.isrc),
        );
        addCandidate(
          requestIndex,
          priority,
          'match_key',
          matchKeyFor(request.trackName, request.artistName),
        );
      }
      if (candidateRows.isEmpty) continue;

      final rows = await db.rawQuery('''
        WITH candidates(request_index, priority, lookup_kind, lookup_value) AS (
          VALUES ${candidateRows.join(', ')}
        ), matches AS (
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.spotify_id = c.lookup_value
          WHERE c.lookup_kind = 'spotify_id'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.spotify_id_norm = c.lookup_value
          WHERE c.lookup_kind = 'spotify_id_norm'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.isrc_norm = c.lookup_value
          WHERE c.lookup_kind = 'isrc_norm'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.match_key = c.lookup_value
          WHERE c.lookup_kind = 'match_key'
        )
        SELECT request_index, id, file_path
        FROM matches
        ORDER BY request_index, priority, sort_added DESC, id DESC
      ''', args);
      for (final row in rows) {
        final localIndex = (row['request_index'] as num).toInt();
        final resultIndex = chunkStart + localIndex;
        results[resultIndex] ??= {
          'id': row['id'],
          'filePath': _normalizeIosPath(row['file_path'] as String?),
        };
      }
    }
    return results;
  }

  Future<void> deleteById(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'history_path_keys',
        where: 'item_id = ?',
        whereArgs: [id],
      );
      await txn.delete('history', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('history_path_keys');
      await txn.delete('history');
    });
    // Return freed pages to the OS (no-op unless the file was created with
    // auto_vacuum enabled).
    try {
      await db.execute('PRAGMA incremental_vacuum');
    } catch (_) {}
    _log.i('Cleared all history');
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Map<String, dynamic>?> findExisting({
    String? spotifyId,
    String? isrc,
  }) async {
    if (spotifyId != null && spotifyId.isNotEmpty) {
      final bySpotify = await getBySpotifyId(spotifyId);
      if (bySpotify != null) return bySpotify;

      if (spotifyId.startsWith('deezer:')) {
        final deezerId = spotifyId.substring(7);
        final db = await database;
        final rows = await db.query(
          'history',
          where: 'spotify_id LIKE ?',
          whereArgs: ['deezer:$deezerId'],
          limit: 1,
        );
        if (rows.isNotEmpty) return _dbRowToJson(rows.first);
      }
    }

    if (isrc != null && isrc.isNotEmpty) {
      return await getByIsrc(isrc);
    }

    return null;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database.reset();
    _searchFtsAvailable = null;
  }

  Future<bool> updateFilePath(
    String id,
    String newFilePath, {
    String? newSafFileName,
    String? newSafRelativeDir,
    String? newQuality,
    int? newBitDepth,
    int? newSampleRate,
    int? newBitrate,
    String? newFormat,
    bool clearAudioSpecs = false,
    String? expectedFilePath,
    String? expectedDownloadedAt,
  }) async {
    final db = await database;
    final values = <String, dynamic>{'file_path': newFilePath};
    if (newSafFileName != null) {
      values['saf_file_name'] = newSafFileName;
    }
    if (newSafRelativeDir != null) {
      values['saf_relative_dir'] = newSafRelativeDir;
    }
    if (newQuality != null) {
      values['quality'] = newQuality;
    }
    if (newFormat != null) {
      values['format'] = newFormat;
    }
    if (newBitrate != null) {
      values['bitrate'] = newBitrate;
    }
    if (clearAudioSpecs) {
      values['bit_depth'] = null;
      values['sample_rate'] = null;
      if (newBitrate == null) {
        values['bitrate'] = null;
      }
    } else {
      if (newBitDepth != null) {
        values['bit_depth'] = newBitDepth;
      }
      if (newSampleRate != null) {
        values['sample_rate'] = newSampleRate;
      }
    }
    return db.transaction((txn) async {
      final changed = await txn.update(
        'history',
        values,
        where:
            'id = ?'
            '${expectedFilePath == null ? '' : ' AND file_path = ?'}'
            '${expectedDownloadedAt == null ? '' : ' AND downloaded_at = ?'}',
        whereArgs: [id, ?expectedFilePath, ?expectedDownloadedAt],
      );
      if (changed == 0) return false;
      final batch = txn.batch();
      _putPathKeysInBatch(batch, id, newFilePath);
      await batch.commit(noResult: true);
      return true;
    });
  }

  Future<void> updateAudioMetadata(
    String id, {
    String? newQuality,
    int? newBitDepth,
    int? newSampleRate,
    bool? hasLyrics,
    int? lyricsMetadataScanVersion,
  }) async {
    final db = await database;
    final values = <String, dynamic>{};
    if (newQuality != null) {
      values['quality'] = newQuality;
    }
    if (newBitDepth != null) {
      values['bit_depth'] = newBitDepth;
    }
    if (newSampleRate != null) {
      values['sample_rate'] = newSampleRate;
    }
    if (hasLyrics != null) {
      values['has_lyrics'] = hasLyrics ? 1 : 0;
    }
    if (lyricsMetadataScanVersion != null) {
      values['lyrics_metadata_scan_version'] = lyricsMetadataScanVersion;
    }
    if (values.isEmpty) {
      return;
    }
    await db.update('history', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<Set<String>> getAllFilePaths() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT file_path FROM history WHERE file_path IS NOT NULL AND file_path != ""',
    );
    return rows.map((r) => r['file_path'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> getEntriesWithPathsPage({
    required int limit,
    int offset = 0,
  }) async {
    final db = await database;
    final rows = await db.query(
      'history',
      columns: [
        'id',
        'file_path',
        'storage_mode',
        'download_tree_uri',
        'saf_relative_dir',
        'saf_file_name',
        'downloaded_at',
      ],
      where: 'file_path IS NOT NULL AND file_path != ""',
      orderBy: 'sort_added DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// A delayed absence check must not delete a replacement downloaded after
  /// the inspected snapshot, even when it reused the same ID and path.
  Future<List<String>> deleteInspectedEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final deletedIds = <String>[];
      for (final entry in entries) {
        final id = entry['id'] as String;
        final downloadedAt = entry['downloaded_at'] as String?;
        final count = await txn.delete(
          'history',
          where:
              'id = ? AND file_path = ?'
              '${downloadedAt == null ? '' : ' AND downloaded_at = ?'}',
          whereArgs: [id, entry['file_path'], ?downloadedAt],
        );
        if (count == 0) continue;
        await txn.delete(
          'history_path_keys',
          where: 'item_id = ?',
          whereArgs: [id],
        );
        deletedIds.add(id);
      }
      return deletedIds;
    });
  }

  Future<int> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;

    final db = await database;
    final totalDeleted = await db.transaction((txn) async {
      var deleted = 0;
      const chunkSize = 500;
      for (var i = 0; i < ids.length; i += chunkSize) {
        final end = (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
        final chunk = ids.sublist(i, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM history_path_keys WHERE item_id IN ($placeholders)',
          chunk,
        );
        deleted += await txn.rawDelete(
          'DELETE FROM history WHERE id IN ($placeholders)',
          chunk,
        );
      }
      return deleted;
    });
    _log.i('Deleted $totalDeleted orphaned entries');
    return totalDeleted;
  }
}
