import 'package:flutter/foundation.dart';
import '../models/session.dart';
import '../services/api_service.dart';
import '../services/local_db.dart';
import '../providers/chat_provider.dart';

class SessionProvider extends ChangeNotifier {
  final ApiService api;
  final LocalDb localDb;
  ChatProvider? _chatProvider;

  List<SessionModel> _sessions = [];
  bool _loading = false;
  String? _error;

  SessionProvider({required this.api, required this.localDb});

  void attachChatProvider(ChatProvider chat) {
    _chatProvider = chat;
  }

  List<SessionModel> get sessions => _sessions;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> loadSessions(String userId) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _sessions = await localDb.getSessions(userId);
      notifyListeners();

      final remote = await api.getSessions(userId);
      for (final s in remote) {
        await localDb.upsertSession(s);
      }
      _sessions = await localDb.getSessions(userId);
      _loading = false;
      // Initialize all loaded sessions as read (prevents false unread on app start)
      _chatProvider?.initAllRead({
        for (final s in _sessions) s.id: s.msgCount,
      });
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<SessionModel> createSession(
    String userId, {
    String mode = 'regular',
    String? courseId,
    String? courseName,
    List<String>? fileIds,
    String? title,
  }) async {
    final session = await api.createSession(
      userId,
      mode: mode,
      courseId: courseId,
      courseName: courseName,
      fileIds: fileIds,
      title: title,
    );
    if (title != null && title.isNotEmpty) {
      session.title = title;
    } else if (mode != 'teaching') {
      session.title = 'New Chat';
    }
    await localDb.upsertSession(session);
    _sessions = await localDb.getSessions(userId);
    notifyListeners();
    return session;
  }

  Future<SessionModel> forkSession(String userId, String sessionId) async {
    final session = await api.forkSession(userId, sessionId);
    await localDb.upsertSession(session);
    _sessions = await localDb.getSessions(userId);
    
    // Also fetch remote messages to local db for this new session
    final remoteMsgs = await api.getMessages(session.id);
    await localDb.clearSessionMessages(session.id);
    await localDb.insertMessages(remoteMsgs);
    
    notifyListeners();
    return session;
  }

  Future<void> deleteSession(String sessionId, String userId) async {
    await api.deleteSession(sessionId);
    // Remove from local DB (abstraction handles both mobile & web)
    await localDb.deleteSession(sessionId);
    _sessions = _sessions.where((s) => s.id != sessionId).toList();
    notifyListeners();
  }

  Future<void> renameSession(String sessionId, String userId, String newTitle) async {
    try {
      await api.patchSession(sessionId, title: newTitle);
    } catch (_) {
      // Server might not support it, update locally anyway
    }
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0) {
      _sessions[idx].title = newTitle;
      await localDb.upsertSession(_sessions[idx]);
      notifyListeners();
    }
  }

  Future<void> togglePin(String sessionId, String userId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final newPinned = !_sessions[idx].pinned;
    try {
      await api.patchSession(sessionId, pinned: newPinned);
    } catch (_) {
      // Server might not support it, update locally anyway
    }
    _sessions[idx].pinned = newPinned;
    await localDb.upsertSession(_sessions[idx]);
    // Re-sort: pinned first
    _sessions.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    notifyListeners();
  }
}
