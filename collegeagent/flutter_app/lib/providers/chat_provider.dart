import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/local_db.dart';

class ChatProvider extends ChangeNotifier {
  final ApiService api;
  final LocalDb localDb;

  /// Cache of messages per session: { sessionId: [MessageModel] }
  final Map<String, List<MessageModel>> _sessionMessages = {};

  /// Loading status per session: { sessionId: bool }
  final Map<String, bool> _sessionLoading = {};

  /// Set of active streaming sessionIds
  final Set<String> _streamingSessions = {};

  /// Cancel functions for active streams: { sessionId: cancelFunc }
  final Map<String, Function()> _cancelFuncs = {};

  /// Per-session pending token buffers — each session is fully isolated
  final Map<String, String> _pendingTokens = {};
  final Map<String, String> _pendingAssistantIds = {};

  /// Per-session throttle timers — each session has its own, preventing crosstalk
  final Map<String, Timer> _throttleTimers = {};

  /// Generation counter to invalidate stale openSession async callbacks.
  /// When a session is opened multiple times quickly, only the latest generation wins.
  final Map<String, int> _openSessionGeneration = {};

  String? _error;
  /// The currently *viewed* session id
  String? _sessionId;
  String? _userId;
  bool _memoryChanged = false;

  /// Tracks msgCount per session that was last seen (for unread calculation)
  final Map<String, int> _lastReadCounts = {};

  ChatProvider({required this.api, required this.localDb});

  // ── Public getters ──────────────────────────────────────────────────────────

  /// Messages for the *currently viewed* session.
  List<MessageModel> get messages =>
      _sessionId != null ? (_sessionMessages[_sessionId] ?? []) : [];

  /// Messages for any specific session (used by other widgets).
  List<MessageModel> getMessagesForSession(String sid) =>
      _sessionMessages[sid] ?? [];

  /// Loading state for the currently viewed session.
  bool get loading =>
      _sessionId != null ? (_sessionLoading[_sessionId] ?? false) : false;

  bool isLoadingSession(String sid) => _sessionLoading[sid] ?? false;

  /// Whether the *currently viewed* session is streaming.
  bool get sending =>
      _sessionId != null && _streamingSessions.contains(_sessionId);

  String? get error => _error;
  String? get sessionId => _sessionId;
  bool get memoryChanged => _memoryChanged;

  /// Whether any specific session is streaming.
  bool isStreaming(String sid) => _streamingSessions.contains(sid);

  void clearMemoryChanged() {
    _memoryChanged = false;
    notifyListeners();
  }

  // ── Unread tracking ─────────────────────────────────────────────────────────

  void markSessionRead(String sessionId, int msgCount) {
    _lastReadCounts[sessionId] = msgCount;
  }

  void initAllRead(Map<String, int> sessionMsgCounts) {
    for (final entry in sessionMsgCounts.entries) {
      _lastReadCounts.putIfAbsent(entry.key, () => entry.value);
    }
  }

  int getUnreadCount(String sessionId, int serverMsgCount) {
    final lastRead = _lastReadCounts[sessionId] ?? 0;
    final diff = serverMsgCount - lastRead;
    return diff > 0 ? diff : 0;
  }

  // ── Session switching ───────────────────────────────────────────────────────

  /// Switch to a session. Updates _sessionId FIRST (before async gap) so the
  /// UI immediately renders the correct (possibly cached) messages and avoids
  /// a blank-page flash. A generation counter ensures stale async callbacks
  /// from previous openSession calls cannot corrupt the current state.
  Future<void> openSession(String userId, String sessionId) async {
    _userId = userId;
    _error = null;

    // Bump generation for this sessionId to invalidate prior in-flight loads
    final gen = (_openSessionGeneration[sessionId] ?? 0) + 1;
    _openSessionGeneration[sessionId] = gen;

    // Switch the viewed session BEFORE the async gap
    _sessionId = sessionId;

    if (!_sessionMessages.containsKey(sessionId)) {
      _sessionMessages[sessionId] = [];
    }
    // Only show the loading spinner if we have no cached data yet
    if ((_sessionMessages[sessionId] ?? []).isEmpty &&
        !_streamingSessions.contains(sessionId)) {
      _sessionLoading[sessionId] = true;
    }
    notifyListeners();

    try {
      // Show local cache instantly while waiting for server
      if ((_sessionMessages[sessionId] ?? []).isEmpty) {
        final local = await localDb.getMessages(sessionId);
        if (_openSessionGeneration[sessionId] == gen &&
            local.isNotEmpty &&
            !_streamingSessions.contains(sessionId)) {
          _sessionMessages[sessionId] = local;
          notifyListeners();
        }
      }

      // Fetch authoritative data from server
      final remote = await api.getMessages(sessionId);

      // Reject stale callbacks — a newer openSession already took over
      if (_openSessionGeneration[sessionId] != gen) return;

      await localDb.clearSessionMessages(sessionId);
      await localDb.insertMessages(remote);

      // Don't overwrite if we are currently streaming into this session
      if (!_streamingSessions.contains(sessionId)) {
        _sessionMessages[sessionId] = remote;
      }
      _sessionLoading[sessionId] = false;
      notifyListeners();
    } catch (e) {
      if (_openSessionGeneration[sessionId] != gen) return;
      if (!_streamingSessions.contains(sessionId)) {
        _sessionMessages[sessionId] = await localDb.getMessages(sessionId);
      }
      _sessionLoading[sessionId] = false;
      _error = e.toString();
      notifyListeners();
    }
  }

  // ── Streaming ───────────────────────────────────────────────────────────────

  Future<void> sendMessage(String userId, String text) async {
    final currentSession = _sessionId;
    if (currentSession == null || text.trim().isEmpty) return;

    // Snapshot the target session — this closure must never read _sessionId again
    final targetSessionId = currentSession;

    _streamingSessions.add(targetSessionId);
    _error = null;

    final currentList = List<MessageModel>.from(
      _sessionMessages[targetSessionId] ?? [],
    );

    // Optimistic: show user message immediately
    final userMsg = MessageModel(
      id: 'opt-${DateTime.now().millisecondsSinceEpoch}',
      sessionId: targetSessionId,
      role: 'user',
      text: text.trim(),
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
    final assistantId = 'stream-${DateTime.now().millisecondsSinceEpoch}';
    final assistantMsg = MessageModel(
      id: assistantId,
      sessionId: targetSessionId,
      role: 'assistant',
      text: '',
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );

    _sessionMessages[targetSessionId] = [...currentList, userMsg, assistantMsg];
    notifyListeners();

    // Helper: flush pending tokens for one session into its message buffer
    void flushTokens(String sid) {
      final pending = _pendingTokens[sid] ?? '';
      final aid = _pendingAssistantIds[sid];
      if (aid == null || pending.isEmpty) return;

      final msgs = _sessionMessages[sid];
      if (msgs == null) return;
      final idx = msgs.indexWhere((m) => m.id == aid);
      if (idx < 0) return;

      final msg = msgs[idx];
      final updated = List<MessageModel>.from(msgs);
      updated[idx] = _rebuildAssistantMsg(sid, aid, msg,
          newText: msg.text + pending);
      _sessionMessages[sid] = updated;
      _pendingTokens[sid] = '';
      notifyListeners();
    }

    try {
      final cancelFunc = await api.streamChat(
        userId: userId,
        sessionId: targetSessionId,
        text: text.trim(),
        onToken: (token) {
          _pendingTokens[targetSessionId] =
              (_pendingTokens[targetSessionId] ?? '') + token;
          _pendingAssistantIds[targetSessionId] = assistantId;

          // Each session has its own isolated throttle timer (80ms)
          _throttleTimers[targetSessionId] ??=
              Timer(const Duration(milliseconds: 80), () {
            _throttleTimers.remove(targetSessionId);
            flushTokens(targetSessionId);
          });
        },
        onIntermediateText: (intermediateText) {
          // Cancel any pending throttle timer before flushing
          _throttleTimers[targetSessionId]?.cancel();
          _throttleTimers.remove(targetSessionId);

          final msgs = _sessionMessages[targetSessionId];
          if (msgs == null) return;
          final idx = msgs.indexWhere((m) => m.id == assistantId);
          if (idx < 0) return;

          final msg = msgs[idx];
          // Merge any buffered tokens into the segment text
          final buffered = _pendingTokens[targetSessionId] ?? '';
          _pendingTokens[targetSessionId] = '';
          final segText = msg.text + buffered;

          final updated = List<MessageModel>.from(msgs);
          final newSegments = List<StreamSegment>.from(msg.segments);
          final effectiveText =
              segText.trim().isNotEmpty ? segText : intermediateText;
          if (effectiveText.trim().isNotEmpty) {
            newSegments.add(StreamSegment.text(effectiveText));
          }
          updated[idx] = _rebuildAssistantMsg(
            targetSessionId,
            assistantId,
            msg,
            newText: '', // final answer starts fresh after this segment
            newSegments: newSegments,
          );
          _sessionMessages[targetSessionId] = updated;
          notifyListeners();
        },
        onDone: (messageId, fullText) async {
          // Cancel and remove throttle timer for this session
          _throttleTimers[targetSessionId]?.cancel();
          _throttleTimers.remove(targetSessionId);

          _pendingTokens.remove(targetSessionId);
          _pendingAssistantIds.remove(targetSessionId);
          _streamingSessions.remove(targetSessionId);
          _cancelFuncs.remove(targetSessionId);

          // Replace streaming placeholder with final authoritative message
          final msgs = _sessionMessages[targetSessionId];
          if (msgs != null) {
            final idx = msgs.indexWhere((m) => m.id == assistantId);
            if (idx >= 0) {
              final oldMsg = msgs[idx];
              final updated = List<MessageModel>.from(msgs);
              updated[idx] = MessageModel(
                id: messageId,
                sessionId: targetSessionId,
                role: 'assistant',
                text: fullText,
                timestamp: DateTime.now().toUtc().toIso8601String(),
                toolCalls: oldMsg.toolCalls,
                segments: oldMsg.segments,
                citations: oldMsg.citations,
              );
              _sessionMessages[targetSessionId] = updated;
            }
          }
          notifyListeners();

          // Refetch from server once (single authoritative fetch — no duplicate call)
          try {
            final remote = await api.getMessages(targetSessionId);
            await localDb.clearSessionMessages(targetSessionId);
            await localDb.insertMessages(remote);
            _sessionMessages[targetSessionId] = remote;
            if (_sessionId == targetSessionId) {
              _lastReadCounts[targetSessionId] = remote.length;
            }
            notifyListeners();
          } catch (_) {}

          await localDb.updateSessionMeta(
            targetSessionId,
            lastMessage: text.trim(),
          );
        },
        onToolStart: (name, args) {
          final msgs = _sessionMessages[targetSessionId];
          if (msgs == null) return;
          final idx = msgs.indexWhere((m) => m.id == assistantId);
          if (idx < 0) return;

          final msg = msgs[idx];
          final updated = List<MessageModel>.from(msgs);
          final newToolCalls = List<ToolCallInfo>.from(msg.toolCalls);
          newToolCalls.add(
            ToolCallInfo(name: name, args: args, isLoading: true),
          );
          final newSegments = List<StreamSegment>.from(msg.segments);
          newSegments.add(StreamSegment.tool(newToolCalls.length - 1));
          updated[idx] = _rebuildAssistantMsg(
            targetSessionId,
            assistantId,
            msg,
            newToolCalls: newToolCalls,
            newSegments: newSegments,
          );
          _sessionMessages[targetSessionId] = updated;
          notifyListeners();

          if (name == 'str_replace' || name == 'insert') {
            _memoryChanged = true;
            notifyListeners();
          }
        },
        onToolEnd: (name, result) {
          final msgs = _sessionMessages[targetSessionId];
          if (msgs == null) return;
          final idx = msgs.indexWhere((m) => m.id == assistantId);
          if (idx < 0) return;

          final toolCalls = msgs[idx].toolCalls;
          for (var i = toolCalls.length - 1; i >= 0; i--) {
            if (toolCalls[i].name == name && toolCalls[i].isLoading) {
              toolCalls[i].result = result;
              toolCalls[i].isLoading = false;
              toolCalls[i].tryParseGraphNodes();
              break;
            }
          }
          notifyListeners();
        },
        onCitations: (citations) {
          final msgs = _sessionMessages[targetSessionId];
          if (msgs == null) return;
          final idx = msgs.indexWhere((m) => m.id == assistantId);
          if (idx < 0) return;

          final msg = msgs[idx];
          final updated = List<MessageModel>.from(msgs);
          updated[idx] = MessageModel(
            id: assistantId,
            sessionId: targetSessionId,
            role: 'assistant',
            text: msg.text,
            timestamp: msg.timestamp,
            toolCalls: msg.toolCalls,
            segments: msg.segments,
            citations: citations,
          );
          _sessionMessages[targetSessionId] = updated;
          notifyListeners();
        },
        onError: (error) async {
          _throttleTimers[targetSessionId]?.cancel();
          _throttleTimers.remove(targetSessionId);
          _streamingSessions.remove(targetSessionId);
          _cancelFuncs.remove(targetSessionId);
          _pendingTokens.remove(targetSessionId);
          _pendingAssistantIds.remove(targetSessionId);

          // Only surface the error if this is still the viewed session
          if (_sessionId == targetSessionId) {
            _error = error;
          }
          notifyListeners();
          
          // Refetch from server to sync persisted partial state (e.g. user msg, partial tool calls)
          try {
            final remote = await api.getMessages(targetSessionId);
            await localDb.clearSessionMessages(targetSessionId);
            await localDb.insertMessages(remote);
            _sessionMessages[targetSessionId] = remote;
            if (_sessionId == targetSessionId) {
              _lastReadCounts[targetSessionId] = remote.length;
            }
            notifyListeners();
          } catch (_) {}
        },
      );

      _cancelFuncs[targetSessionId] = cancelFunc;

      await localDb.updateSessionMeta(
        targetSessionId,
        lastMessage: text.trim(),
      );
    } catch (e) {
      _throttleTimers[targetSessionId]?.cancel();
      _throttleTimers.remove(targetSessionId);
      _streamingSessions.remove(targetSessionId);
      _cancelFuncs.remove(targetSessionId);
      _pendingTokens.remove(targetSessionId);
      _pendingAssistantIds.remove(targetSessionId);

      if (_sessionId == targetSessionId) {
        _error = e.toString();
      }
      notifyListeners();
      
      try {
        final remote = await api.getMessages(targetSessionId);
        await localDb.clearSessionMessages(targetSessionId);
        await localDb.insertMessages(remote);
        _sessionMessages[targetSessionId] = remote;
        if (_sessionId == targetSessionId) {
          _lastReadCounts[targetSessionId] = remote.length;
        }
        notifyListeners();
      } catch (_) {}
    }
  }

  /// Immediately stops active streaming generation for a session.
  Future<void> stopStreaming([String? sid]) async {
    final targetSessionId = sid ?? _sessionId;
    if (targetSessionId == null) return;

    // 1. Trigger local stream cancellation
    if (_cancelFuncs.containsKey(targetSessionId)) {
      try {
        _cancelFuncs[targetSessionId]?.call();
      } catch (_) {}
      _cancelFuncs.remove(targetSessionId);
    }

    // 2. Notify backend to abort DeepSeek stream or finish after running tools
    try {
      await api.stopChat(targetSessionId);
    } catch (_) {}

    // 3. Clear buffers and state
    _throttleTimers[targetSessionId]?.cancel();
    _throttleTimers.remove(targetSessionId);
    _pendingTokens.remove(targetSessionId);
    _pendingAssistantIds.remove(targetSessionId);
    _streamingSessions.remove(targetSessionId);
    notifyListeners();

    // 4. Refetch messages from server to sync final state
    try {
      final remote = await api.getMessages(targetSessionId);
      await localDb.clearSessionMessages(targetSessionId);
      await localDb.insertMessages(remote);
      _sessionMessages[targetSessionId] = remote;
      if (_sessionId == targetSessionId) {
        _lastReadCounts[targetSessionId] = remote.length;
      }
      notifyListeners();
    } catch (_) {}
  }

  // ── Rollback ────────────────────────────────────────────────────────────────

  Future<void> rollbackToMessage(MessageModel targetMsg) async {
    final curSession = _sessionId;
    if (curSession == null || _userId == null) return;

    final msgs = _sessionMessages[curSession] ?? [];
    final idx = msgs.indexWhere((m) => m.id == targetMsg.id);
    if (idx < 0) return;

    // Optimistic UI update
    _sessionMessages[curSession] = msgs.sublist(0, idx);
    notifyListeners();

    try {
      await api.rollbackMessage(curSession, targetMsg.id);
      final remote = await api.getMessages(curSession);
      await localDb.clearSessionMessages(curSession);
      await localDb.insertMessages(remote);
      _sessionMessages[curSession] = remote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  MessageModel _rebuildAssistantMsg(
    String targetSessionId,
    String assistantId,
    MessageModel old, {
    String? newText,
    List<ToolCallInfo>? newToolCalls,
    List<StreamSegment>? newSegments,
  }) {
    return MessageModel(
      id: assistantId,
      sessionId: targetSessionId,
      role: 'assistant',
      text: newText ?? old.text,
      timestamp: old.timestamp,
      toolCalls: newToolCalls ?? old.toolCalls,
      segments: newSegments ?? old.segments,
    );
  }

  @override
  void dispose() {
    for (final t in _throttleTimers.values) {
      t.cancel();
    }
    _throttleTimers.clear();
    for (final cancel in _cancelFuncs.values) {
      try {
        cancel();
      } catch (_) {}
    }
    _cancelFuncs.clear();
    super.dispose();
  }
}
