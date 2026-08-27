import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../models/message.dart';

/// Web-compatible LocalDb using shared_preferences.
///
/// On Web, SharedPreferences (localStorage) ONLY maintains the session index
/// (`nc_sessions_<userId>`). Chat message history is fetched on-demand from the server.
class LocalDb {
  SharedPreferences? _prefs;
  bool _cleanedLegacyMessages = false;

  Future<SharedPreferences> get _sp async {
    if (_prefs == null) {
      _prefs = await SharedPreferences.getInstance();
      _purgeLegacyMessages(_prefs!);
    }
    return _prefs!;
  }

  void _purgeLegacyMessages(SharedPreferences sp) {
    if (_cleanedLegacyMessages) return;
    _cleanedLegacyMessages = true;
    try {
      final msgKeys = sp.getKeys().where((k) => k.startsWith('nc_messages_')).toList();
      for (final k in msgKeys) {
        sp.remove(k);
      }
    } catch (_) {}
  }

  // ── Sessions Index ─────────────────────────────────────────────────────────

  Future<void> upsertSession(SessionModel session) async {
    final sp = await _sp;
    final key = 'nc_sessions_${session.userId}';
    final list = _decodeList(sp.getString(key));

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
    final keys = sp.getKeys().where((k) => k.startsWith('nc_sessions_'));
    for (final key in keys) {
      final list = _decodeList(sp.getString(key));
      final idx = list.indexWhere((m) => m['id'] == sessionId);
      if (idx >= 0) {
        if (title != null) list[idx]['title'] = title;
        if (lastMessage != null) list[idx]['last_message'] = lastMessage;
        if (latestAssistant != null) list[idx]['latest_assistant'] = latestAssistant;
        if (msgCount != null) list[idx]['msg_count'] = msgCount;
        await sp.setString(key, jsonEncode(list));
        return;
      }
    }
  }

  // ── Messages (Web: on-demand from server) ───────────────────────────────────

  Future<void> insertMessage(MessageModel msg) async {
    // No-op on Web: messages are managed on the server
  }

  Future<void> insertMessages(List<MessageModel> msgs) async {
    // No-op on Web: messages are managed on the server
  }

  Future<List<MessageModel>> getMessages(String sessionId) async {
    // Return empty so ChatProvider / caller fetches directly from server
    return [];
  }

  Future<void> clearSessionMessages(String sessionId) async {
    final sp = await _sp;
    await sp.remove('nc_messages_$sessionId');
  }

  // ── Clear & Delete ─────────────────────────────────────────────────────────

  Future<void> clear() async {
    final sp = await _sp;
    final keysToRemove = sp.getKeys().where((k) => k.startsWith('nc_')).toList();
    for (final key in keysToRemove) {
      await sp.remove(key);
    }
  }

  Future<void> deleteSession(String sessionId) async {
    final sp = await _sp;
    await sp.remove('nc_messages_$sessionId');
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
