import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../models/message.dart';

/// Web-compatible LocalDb using shared_preferences with in-memory fallback and quota management.
///
/// Data layout in shared_preferences:
///   "nc_sessions_<userId>"  → JSON array of session maps
///   "nc_messages_<sessionId>" → JSON array of message maps
class LocalDb {
  SharedPreferences? _prefs;
  final Map<String, List<Map<String, dynamic>>> _sessionsMem = {};
  final Map<String, List<Map<String, dynamic>>> _messagesMem = {};

  Future<SharedPreferences> get _sp async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> _safeSetString(String key, String val) async {
    try {
      final sp = await _sp;
      await sp.setString(key, val);
    } catch (_) {
      try {
        final sp = await _sp;
        // Evict older message caches from localStorage to reclaim quota
        final msgKeys = sp.getKeys().where((k) => k.startsWith('nc_messages_')).toList();
        for (final k in msgKeys) {
          await sp.remove(k);
        }
        await sp.setString(key, val);
      } catch (_) {
        // Storage is full; in-memory cache preserves data during app session
      }
    }
  }

  // ── Sessions ───────────────────────────────────────────────────────────────

  Future<void> upsertSession(SessionModel session) async {
    final key = 'nc_sessions_${session.userId}';
    final list = await _getRawSessionList(session.userId);

    final idx = list.indexWhere((m) => m['id'] == session.id);
    final map = session.toDbMap();
    if (map['last_message'] is String && (map['last_message'] as String).length > 120) {
      map['last_message'] = (map['last_message'] as String).substring(0, 120);
    }
    if (map['latest_assistant'] is String && (map['latest_assistant'] as String).length > 120) {
      map['latest_assistant'] = (map['latest_assistant'] as String).substring(0, 120);
    }

    if (idx >= 0) {
      list[idx] = map;
    } else {
      list.add(map);
    }
    _sessionsMem[session.userId] = list;
    await _safeSetString(key, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> _getRawSessionList(String userId) async {
    if (_sessionsMem.containsKey(userId)) {
      return _sessionsMem[userId]!;
    }
    try {
      final sp = await _sp;
      final key = 'nc_sessions_$userId';
      final list = _decodeList(sp.getString(key));
      _sessionsMem[userId] = list;
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<List<SessionModel>> getSessions(String userId) async {
    final list = await _getRawSessionList(userId);
    final sessions = list.map((m) => SessionModel.fromJson(m)).toList();
    sessions.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    return sessions;
  }

  Future<void> updateSessionMeta(
    String sessionId, {
    String? title,
    String? lastMessage,
    String? latestAssistant,
    int? msgCount,
  }) async {
    // Update in-memory for all users
    for (final entry in _sessionsMem.entries) {
      final list = entry.value;
      final idx = list.indexWhere((m) => m['id'] == sessionId);
      if (idx >= 0) {
        if (title != null) list[idx]['title'] = title;
        if (lastMessage != null) {
          list[idx]['last_message'] = lastMessage.length > 120 ? lastMessage.substring(0, 120) : lastMessage;
        }
        if (latestAssistant != null) {
          list[idx]['latest_assistant'] = latestAssistant.length > 120 ? latestAssistant.substring(0, 120) : latestAssistant;
        }
        if (msgCount != null) list[idx]['msg_count'] = msgCount;
        await _safeSetString('nc_sessions_${entry.key}', jsonEncode(list));
        return;
      }
    }

    try {
      final sp = await _sp;
      final keys = sp.getKeys().where((k) => k.startsWith('nc_sessions_'));
      for (final key in keys) {
        final list = _decodeList(sp.getString(key));
        final idx = list.indexWhere((m) => m['id'] == sessionId);
        if (idx >= 0) {
          if (title != null) list[idx]['title'] = title;
          if (lastMessage != null) {
            list[idx]['last_message'] = lastMessage.length > 120 ? lastMessage.substring(0, 120) : lastMessage;
          }
          if (latestAssistant != null) {
            list[idx]['latest_assistant'] = latestAssistant.length > 120 ? latestAssistant.substring(0, 120) : latestAssistant;
          }
          if (msgCount != null) list[idx]['msg_count'] = msgCount;
          await _safeSetString(key, jsonEncode(list));
          return;
        }
      }
    } catch (_) {}
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  Future<void> insertMessage(MessageModel msg) async {
    final list = await _getRawMessageList(msg.sessionId);
    if (!list.any((m) => m['id'] == msg.id)) {
      list.add(msg.toDbMap());
    }
    _messagesMem[msg.sessionId] = list;

    // Persist only recent messages to prevent storage quota exhaustion
    final toPersist = list.length > 30 ? list.sublist(list.length - 30) : list;
    await _safeSetString('nc_messages_${msg.sessionId}', jsonEncode(toPersist));
  }

  Future<void> insertMessages(List<MessageModel> msgs) async {
    if (msgs.isEmpty) return;
    final sessionId = msgs.first.sessionId;
    final list = await _getRawMessageList(sessionId);

    for (final msg in msgs) {
      if (!list.any((m) => m['id'] == msg.id)) {
        list.add(msg.toDbMap());
      }
    }
    _messagesMem[sessionId] = list;

    final toPersist = list.length > 30 ? list.sublist(list.length - 30) : list;
    await _safeSetString('nc_messages_$sessionId', jsonEncode(toPersist));
  }

  Future<List<Map<String, dynamic>>> _getRawMessageList(String sessionId) async {
    if (_messagesMem.containsKey(sessionId)) {
      return _messagesMem[sessionId]!;
    }
    try {
      final sp = await _sp;
      final list = _decodeList(sp.getString('nc_messages_$sessionId'));
      _messagesMem[sessionId] = list;
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<List<MessageModel>> getMessages(String sessionId) async {
    final list = await _getRawMessageList(sessionId);
    final messages = list.map((m) => MessageModel.fromJson(m, sessionId)).toList();
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  Future<void> clear() async {
    _sessionsMem.clear();
    _messagesMem.clear();
    try {
      final sp = await _sp;
      final keysToRemove = sp.getKeys().where((k) => k.startsWith('nc_')).toList();
      for (final key in keysToRemove) {
        await sp.remove(key);
      }
    } catch (_) {}
  }

  Future<void> clearSessionMessages(String sessionId) async {
    _messagesMem.remove(sessionId);
    try {
      final sp = await _sp;
      await sp.remove('nc_messages_$sessionId');
    } catch (_) {}
  }

  /// Deletes a session and all its messages from the local DB.
  Future<void> deleteSession(String sessionId) async {
    _messagesMem.remove(sessionId);
    try {
      final sp = await _sp;
      await sp.remove('nc_messages_$sessionId');
    } catch (_) {}

    for (final entry in _sessionsMem.entries) {
      entry.value.removeWhere((m) => m['id'] == sessionId);
      await _safeSetString('nc_sessions_${entry.key}', jsonEncode(entry.value));
    }

    try {
      final sp = await _sp;
      final keys = sp.getKeys().where((k) => k.startsWith('nc_sessions_')).toList();
      for (final key in keys) {
        final list = _decodeList(sp.getString(key));
        final filtered = list.where((m) => m['id'] != sessionId).toList();
        if (filtered.length != list.length) {
          await _safeSetString(key, jsonEncode(filtered));
        }
      }
    } catch (_) {}
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
    } catch (_) {}
    return [];
  }
}
