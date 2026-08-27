import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../models/message.dart';

/// Web-compatible LocalDb using shared_preferences.
///
/// Data layout in shared_preferences:
///   "nc_sessions_<userId>"  → JSON array of session maps
///   "nc_messages_<sessionId>" → JSON array of message maps
class LocalDb {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ── Sessions ───────────────────────────────────────────────────────────────

  Future<void> upsertSession(SessionModel session) async {
    final sp = await _sp;
    final key = 'nc_sessions_${session.userId}';
    final list = _decodeList(sp.getString(key));

    // Replace existing or add new
    final idx = list.indexWhere((m) => m['id'] == session.id);
    final map = session.toDbMap();
    if (idx >= 0) {
      list[idx] = map;
    } else {
      list.add(map);
    }
    await sp.setString(key, jsonEncode(list));
  }

  Future<List<SessionModel>> getSessions(String userId) async {
    final sp = await _sp;
    final key = 'nc_sessions_$userId';
    final list = _decodeList(sp.getString(key));

    final sessions = list.map((m) => SessionModel.fromJson(m)).toList();
    // Sort: pinned first, then by created_at DESC
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
    final sp = await _sp;
    // Find the session across all users (we store per-user, so scan keys)
    final keys = sp.getKeys().where((k) => k.startsWith('nc_sessions_'));
    for (final key in keys) {
      final list = _decodeList(sp.getString(key));
      final idx = list.indexWhere((m) => m['id'] == sessionId);
      if (idx >= 0) {
        if (title != null) list[idx]['title'] = title;
        if (lastMessage != null) list[idx]['last_message'] = lastMessage;
        if (latestAssistant != null) {
          list[idx]['latest_assistant'] = latestAssistant;
        }
        if (msgCount != null) list[idx]['msg_count'] = msgCount;
        await sp.setString(key, jsonEncode(list));
        return;
      }
    }
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  Future<void> insertMessage(MessageModel msg) async {
    final sp = await _sp;
    final key = 'nc_messages_${msg.sessionId}';
    final list = _decodeList(sp.getString(key));

    // Ignore duplicates (same id)
    if (list.any((m) => m['id'] == msg.id)) return;
    list.add(msg.toDbMap());
    await sp.setString(key, jsonEncode(list));
  }

  Future<void> insertMessages(List<MessageModel> msgs) async {
    final sp = await _sp;
    for (final msg in msgs) {
      await insertMessage(msg);
    }
  }

  Future<List<MessageModel>> getMessages(String sessionId) async {
    final sp = await _sp;
    final key = 'nc_messages_$sessionId';
    final list = _decodeList(sp.getString(key));

    final messages =
        list.map((m) => MessageModel.fromJson(m, sessionId)).toList();
    // Sort by timestamp ASC (same as mobile)
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  Future<void> clear() async {
    final sp = await _sp;
    final keysToRemove =
        sp.getKeys().where((k) => k.startsWith('nc_')).toList();
    for (final key in keysToRemove) {
      await sp.remove(key);
    }
  }

  Future<void> clearSessionMessages(String sessionId) async {
    final sp = await _sp;
    final key = 'nc_messages_$sessionId';
    await sp.remove(key);
  }

  /// Deletes a session and all its messages from the local DB.
  Future<void> deleteSession(String sessionId) async {
    final sp = await _sp;
    // Remove messages
    await sp.remove('nc_messages_$sessionId');
    // Remove session from all user session lists
    final keys = sp.getKeys().where((k) => k.startsWith('nc_sessions_')).toList();
    for (final key in keys) {
      final list = _decodeList(sp.getString(key));
      final filtered = list.where((m) => m['id'] != sessionId).toList();
      if (filtered.length != list.length) {
        await sp.setString(key, jsonEncode(filtered));
      }
    }
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
