import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import '../models/session.dart';
import '../models/message.dart';

class LocalDb {
  Database? _db;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'nanoclaw_chat.db');
    return openDatabase(
      path,
      version: 6,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('DROP TABLE IF EXISTS sessions');
        }
        if (oldVersion < 3) {
          // v3: add latest_assistant and msg_count columns
          await db.execute('DROP TABLE IF EXISTS sessions');
        }
        if (oldVersion < 4) {
          // v4: add meta column to messages for tool call persistence
          await db.execute('ALTER TABLE messages ADD COLUMN meta TEXT');
        }
        if (oldVersion < 5) {
          // v5: add pinned column to sessions
          await db.execute('ALTER TABLE sessions ADD COLUMN pinned INTEGER DEFAULT 0');
        }
        if (oldVersion < 6) {
          // v6: add parent_id column
          await db.execute('ALTER TABLE sessions ADD COLUMN parent_id TEXT');
        }
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            parent_id TEXT,
            title TEXT,
            last_message TEXT,
            latest_assistant TEXT,
            msg_count INTEGER DEFAULT 0,
            last_active TEXT,
            created_at TEXT NOT NULL,
            pinned INTEGER DEFAULT 0
          )
        ''');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            parent_id TEXT,
            title TEXT,
            last_message TEXT,
            latest_assistant TEXT,
            msg_count INTEGER DEFAULT 0,
            last_active TEXT,
            created_at TEXT NOT NULL,
            pinned INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            seq INTEGER,
            meta TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_session ON messages(session_id)',
        );
      },
    );
  }

  Future<void> upsertSession(SessionModel session) async {
    final db = await database;
    await db.insert(
      'sessions',
      session.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<SessionModel>> getSessions(String userId) async {
    final db = await database;
    final rows = await db.query(
      'sessions',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'pinned DESC, created_at DESC',
    );
    return rows.map((r) => SessionModel.fromJson(r)).toList();
  }

  Future<void> updateSessionMeta(
    String sessionId, {
    String? title,
    String? lastMessage,
    String? latestAssistant,
    int? msgCount,
  }) async {
    final db = await database;
    final values = <String, dynamic>{};
    if (title != null) values['title'] = title;
    if (lastMessage != null) values['last_message'] = lastMessage;
    if (latestAssistant != null) values['latest_assistant'] = latestAssistant;
    if (msgCount != null) values['msg_count'] = msgCount;
    if (values.isNotEmpty) {
      await db.update(
        'sessions',
        values,
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    }
  }

  Future<void> insertMessage(MessageModel msg) async {
    final db = await database;
    await db.insert(
      'messages',
      msg.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> insertMessages(List<MessageModel> msgs) async {
    final db = await database;
    final batch = db.batch();
    for (final msg in msgs) {
      batch.insert(
        'messages',
        msg.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<MessageModel>> getMessages(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return rows
        .map((r) => MessageModel.fromJson(r, sessionId))
        .toList();
  }

  Future<void> clear() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('sessions');
  }

  Future<void> clearSessionMessages(String sessionId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Deletes a session and all its messages from the local DB.
  Future<void> deleteSession(String sessionId) async {
    final db = await database;
    await db.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }
}
