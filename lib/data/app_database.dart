import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens the single SQLite database. Desktop platforms use sqflite_common_ffi.
class AppDatabase {
  static bool _ffiReady = false;

  static void _ensureFactory() {
    if (_ffiReady) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ffiReady = true;
  }

  /// [path] may be [inMemoryDatabasePath] for tests.
  static Future<Database> open(String path) async {
    _ensureFactory();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: false,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onUpgrade: (db, from, to) async {
          if (from < 2) await _createAttachments(db);
        },
        onCreate: (db, v) async {
          await db.execute('''
CREATE TABLE messages(
  id TEXT PRIMARY KEY,
  origin_device TEXT NOT NULL,
  origin_name TEXT NOT NULL,
  origin_seq INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  UNIQUE(origin_device, origin_seq)
)''');
          await db.execute(
              'CREATE INDEX idx_messages_time ON messages(created_at, origin_device, origin_seq)');
          await db.execute('''
CREATE TABLE peers(
  device_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  public_key BLOB NOT NULL,
  paired_at INTEGER NOT NULL,
  last_host TEXT,
  last_port INTEGER,
  last_seen INTEGER
)''');
          await _createAttachments(db);
          // What each paired peer has confirmed to hold, per origin device.
          await db.execute('''
CREATE TABLE peer_vectors(
  peer_id TEXT NOT NULL,
  origin_device TEXT NOT NULL,
  max_seq INTEGER NOT NULL,
  PRIMARY KEY(peer_id, origin_device)
)''');
        },
      ),
    );
  }

  /// Locally held files. A message with kind 'file' and no row here means
  /// "metadata synced, file not downloaded on this device".
  static Future<void> _createAttachments(DatabaseExecutor db) => db.execute(
      'CREATE TABLE attachments(message_id TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, stored_at INTEGER NOT NULL)');
}
