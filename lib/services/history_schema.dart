import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('HistoryDatabase');

/// Schema lifecycle for history.db, independent of row reads and writes.
abstract final class HistorySchema {
  /// Creates the schema and returns whether the optional FTS index is
  /// available.
  static Future<bool> create(Database db, int version) async {
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
    final searchFtsAvailable = await createSearchFts(db);

    _log.i('Database schema created with indexes');
    return searchFtsAvailable;
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
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

  static Future<bool> createSearchFts(DatabaseExecutor db) {
    return sqlite.createTrigramFtsIndex(
      db,
      ftsTable: HistoryDatabase.searchFtsTable,
      contentTable: 'history',
      triggerPrefix: 'history_search_fts',
    );
  }

  static Future<void> _createNormalizedIndexes(DatabaseExecutor db) async {
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

  static Future<void> _createQueueIndexes(DatabaseExecutor db) async {
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

  static Future<void> _backfillNormalizedColumns(Database db) async {
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
        HistoryRowMapper.normalizedColumns(
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

  static Future<void> _backfillQueueSortColumns(Database db) async {
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
        HistoryRowMapper.queueSortColumns(
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

  static Future<void> _createPathKeyTable(DatabaseExecutor db) =>
      sqlite.createPathKeyTable(db, 'history_path_keys');
}
