import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/session.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/session_provider.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';
import '../widgets/session_tile.dart';
import 'memory_screen.dart';
import 'canvas_courses_screen.dart';
import 'calendar_screen.dart';
import 'gmail_screen.dart';
import 'personal_vault_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _desktopSidebarOpen = true;
  Timer? _refreshTimer;
  SessionModel? _selectedSession;
  String? _selectedRootId;
  final List<String> _activeTabIds = [];
  final Map<String, int> _tabFixedIds = {};
  int _nextFixedId = 1;
  final Map<String, String> _customTabNames = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSessions());
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _loadSessions());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _loadSessions() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final sessions = context.read<SessionProvider>();
    final chat = context.read<ChatProvider>();
    sessions.attachChatProvider(chat);
    if (auth.user != null) {
      sessions.loadSessions(auth.user!.userId);
    }
  }

  Future<void> _refreshSessions() async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final sessions = context.read<SessionProvider>();
    final chat = context.read<ChatProvider>();
    sessions.attachChatProvider(chat);
    if (auth.user != null) {
      await sessions.loadSessions(auth.user!.userId);
    }
  }

  Future<void> _createNewSession() async {
    final auth = context.read<AuthProvider>();
    final sessionProv = context.read<SessionProvider>();
    final chat = context.read<ChatProvider>();
    if (auth.user == null) return;
    try {
      final session = await sessionProv.createSession(auth.user!.userId);
      chat.openSession(auth.user!.userId, session.id);
      chat.markSessionRead(session.id, session.msgCount);
      _selectedRootId = session.id;
      _activeTabIds.clear();
      _tabFixedIds.clear();
      _nextFixedId = 1;
      _activeTabIds.add(session.id);
      _tabFixedIds[session.id] = _nextFixedId++;
      setState(() => _selectedSession = session);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create session: $e')),
      );
    }
  }

  void _selectSession(SessionModel session) {
    final auth = context.read<AuthProvider>();
    final chat = context.read<ChatProvider>();
    if (auth.user == null) return;
    final rootId = session.parentId ?? session.id;
    if (_selectedRootId != rootId) {
      _selectedRootId = rootId;
      _activeTabIds.clear();
      _tabFixedIds.clear();
      _nextFixedId = 1;
      // We rely on _buildMainContent to populate _activeTabIds from sessionProv
    }
    chat.openSession(auth.user!.userId, session.id);
    chat.markSessionRead(session.id, session.msgCount);
    setState(() => _selectedSession = session);
  }

  void _clearSelection() {
    setState(() {
      _selectedSession = null;
      _selectedRootId = null;
      _activeTabIds.clear();
      _tabFixedIds.clear();
      _nextFixedId = 1;
    });
  }

  bool get _isDesktop {
    return MediaQuery.of(context).size.width >= 768;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sessionProv = context.watch<SessionProvider>();
    final chat = context.watch<ChatProvider>();
    final user = auth.user;
    final username = user?.username ?? 'User';

    // Keep selected session in sync (in case it was deleted)
    if (_selectedSession != null &&
        !sessionProv.sessions.any((s) => s.id == _selectedSession!.id)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => setState(() => _selectedSession = null));
    }

    return PopScope(
      canPop: _selectedSession == null || _isDesktop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedSession != null && !_isDesktop) {
          _clearSelection();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _isDesktop
            ? null
            : _SessionSidebar(
                sessions: sessionProv.sessions,
                selectedId: _selectedSession?.id,
                username: username,
                chat: chat,
                user: user,
                isDesktop: false,
                onCloseSidebar: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                onNewChat: () {
                  _createNewSession();
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                onSelectSession: (s) {
                  _selectSession(s);
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                onLoadSessions: _refreshSessions,
              ),
        body: SafeArea(
          child: _isDesktop
              ? Row(
                  children: [
                    if (_desktopSidebarOpen) ...[
                      SizedBox(
                        width: 280,
                        child: _SessionSidebar(
                          sessions: sessionProv.sessions,
                          selectedId: _selectedSession?.id,
                          username: username,
                          chat: chat,
                          user: user,
                          isDesktop: true,
                          onCloseSidebar: () {
                            setState(() => _desktopSidebarOpen = false);
                          },
                          onNewChat: _createNewSession,
                          onSelectSession: _selectSession,
                          onLoadSessions: _refreshSessions,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      child: _buildMainContent(chat, sessionProv, auth, user),
                    ),
                  ],
                )
              : _buildMainContent(chat, sessionProv, auth, user),
        ),
      ),
    );
  }

  Widget _buildMainContent(
      ChatProvider chat, SessionProvider sessionProv, AuthProvider auth, UserModel? user) {
    if (_selectedSession == null) {
      return _WelcomeView(
        username: auth.user?.username ?? 'User',
        isDesktop: _isDesktop,
        desktopSidebarOpen: _desktopSidebarOpen,
        onToggleSidebar: () {
          if (_isDesktop) {
            setState(() => _desktopSidebarOpen = !_desktopSidebarOpen);
          } else {
            _scaffoldKey.currentState?.openDrawer();
          }
        },
        onSend: (text) async {
          if (auth.user == null) return;
          await _createNewSession();
          if (_selectedSession != null && mounted) {
            chat.sendMessage(auth.user!.userId, text);
          }
        },
      );
    }
    final rootId = _selectedSession!.parentId ?? _selectedSession!.id;
    final allRelated = sessionProv.sessions
        .where((s) => s.id == rootId || s.parentId == rootId)
        .toList();
    allRelated.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (var s in allRelated) {
      if (!_activeTabIds.contains(s.id)) {
        _activeTabIds.add(s.id);
        if (!_tabFixedIds.containsKey(s.id)) {
          _tabFixedIds[s.id] = _nextFixedId++;
        }
      }
    }
    _activeTabIds.removeWhere((id) => !allRelated.any((s) => s.id == id));

    final tabs = _activeTabIds
        .map((id) => allRelated.firstWhere((s) => s.id == id))
        .toList();

    return _ChatView(
      key: ValueKey(_selectedSession!.id),  // CRITICAL: forces State rebuild on every session switch
      session: _selectedSession!,
      tabs: tabs,
      tabFixedIds: _tabFixedIds,
      customTabNames: _customTabNames,
      isDesktop: _isDesktop,
      desktopSidebarOpen: _desktopSidebarOpen,
      onToggleSidebar: () {
        if (_isDesktop) {
          setState(() => _desktopSidebarOpen = !_desktopSidebarOpen);
        } else {
          _scaffoldKey.currentState?.openDrawer();
        }
      },
      onBack: _clearSelection,
      onTabSelected: _selectSession,
      onTabClosed: (s) {
        if (user != null) sessionProv.deleteSession(s.id, user.userId);
        if (s.id == _selectedSession!.id) {
          final remaining = tabs.where((t) => t.id != s.id).toList();
          if (remaining.isNotEmpty) {
            _selectSession(remaining.first);
          } else {
            _clearSelection();
          }
        }
      },
      onTabRenamed: (s, newTitle) {
        setState(() {
          _customTabNames[s.id] = newTitle;
        });
        if (user != null) {
          sessionProv.renameSession(s.id, user.userId, newTitle);
        }
      },
      onFork: () async {
        if (user == null) return;
        try {
          final newSession = await sessionProv.forkSession(user.userId, _selectedSession!.id);
          _activeTabIds.remove(newSession.id);
          final currentIndex = _activeTabIds.indexOf(_selectedSession!.id);
          if (currentIndex != -1) {
            _activeTabIds.insert(currentIndex + 1, newSession.id);
          } else {
            _activeTabIds.add(newSession.id);
          }
          if (!_tabFixedIds.containsKey(newSession.id)) {
            _tabFixedIds[newSession.id] = _nextFixedId++;
          }
          _selectSession(newSession);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fork failed: $e')));
          }
        }
      },
    );
  }
}

// ── Session Sidebar ──────────────────────────────────────────────────────────

class _SessionSidebar extends StatelessWidget {
  final List<SessionModel> sessions;
  final String? selectedId;
  final String username;
  final ChatProvider chat;
  final UserModel? user;
  final bool isDesktop;
  final VoidCallback onCloseSidebar;
  final VoidCallback onNewChat;
  final ValueChanged<SessionModel> onSelectSession;
  final Future<void> Function() onLoadSessions;

  const _SessionSidebar({
    required this.sessions,
    required this.selectedId,
    required this.username,
    required this.chat,
    required this.user,
    required this.isDesktop,
    required this.onCloseSidebar,
    required this.onNewChat,
    required this.onSelectSession,
    required this.onLoadSessions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF8F9FA),
      child: SafeArea(
        top: true,
        bottom: true,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu_open, size: 20),
                    tooltip: isDesktop ? 'Collapse sidebar' : 'Close sidebar',
                    onPressed: onCloseSidebar,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'CollegeAgent',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6C63FF),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.upload_file_outlined, size: 20),
                    tooltip: 'Personal Vault',
                    onPressed: () {
                      if (user != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PersonalVaultScreen(userId: user!.userId),
                          ),
                        );
                      }
                    },
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20, color: Colors.black54),
                    tooltip: 'More options',
                    onSelected: (value) {
                      if (user == null) return;
                      if (value == 'calendar') {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => CalendarScreen(userId: user!.userId)));
                      } else if (value == 'gmail') {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => GmailScreen(userId: user!.userId)));
                      } else if (value == 'canvas') {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => CanvasCoursesScreen(userId: user!.userId)));
                      } else if (value == 'memory') {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => MemoryScreen(userId: user!.userId)));
                      }
                    },
                    itemBuilder: (BuildContext context) => [
                      PopupMenuItem(
                        value: 'calendar',
                        child: Row(children: [
                          const Icon(Icons.calendar_month_outlined, size: 18),
                          const SizedBox(width: 8),
                          const Text('Google Calendar')
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'gmail',
                        child: Row(children: [
                          const Icon(Icons.email_outlined, size: 18),
                          const SizedBox(width: 8),
                          const Text('Gmail')
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'canvas',
                        child: Row(children: [
                          const Icon(Icons.school_outlined, size: 18),
                          const SizedBox(width: 8),
                          const Text('Canvas Courses')
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'memory',
                        child: Row(children: [
                          const Icon(Icons.memory_outlined, size: 18),
                          const SizedBox(width: 8),
                          const Text('Memory')
                        ]),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'logout',
                        onTap: () {
                          Future.delayed(Duration.zero, () {
                            context.read<AuthProvider>().logout();
                          });
                        },
                        child: Row(children: [
                          const Icon(Icons.logout, size: 18),
                          const SizedBox(width: 8),
                          const Text('Logout')
                        ]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // New chat button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: InkWell(
                onTap: onNewChat,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.edit_outlined, size: 18),
                      const SizedBox(width: 10),
                      const Text('New chat',
                          style: TextStyle(fontWeight: FontWeight.w500)),
                      const Spacer(),
                      Icon(Icons.add, size: 18, color: Colors.grey.shade600),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Recents header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Recents',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Session list
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Text(
                        'No chats yet',
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () async => onLoadSessions(),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        itemCount: sessions.where((s) => s.parentId == null).length,
                        itemBuilder: (_, i) {
                          final session = sessions.where((s) => s.parentId == null).toList()[i];
                          final unread =
                              chat.getUnreadCount(session.id, session.msgCount);
                          
                          // Check if this root session or any of its subagents are selected
                          final isSelected = selectedId == session.id || 
                            sessions.any((sub) => sub.id == selectedId && sub.parentId == session.id);

                          return SessionTile(
                            session: session,
                            unreadCount: unread,
                            isStreaming: chat.isStreaming(session.id),
                            selected: isSelected,
                            compact: true,
                            onTap: () => onSelectSession(session),
                            onDelete: user != null
                                ? () => context
                                    .read<SessionProvider>()
                                    .deleteSession(session.id, user!.userId)
                                : null,
                            onRename: user != null
                                ? (newTitle) => context
                                    .read<SessionProvider>()
                                    .renameSession(
                                        session.id, user!.userId, newTitle)
                                : null,
                            onTogglePin: user != null
                                ? () => context
                                    .read<SessionProvider>()
                                    .togglePin(session.id, user!.userId)
                                : null,
                          );
                        },
                      ),
                    ),
            ),
            // User info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFF6C63FF),
                    child: Text(
                      username.isNotEmpty ? username[0].toUpperCase() : 'U',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.settings_outlined,
                        size: 18, color: Colors.grey.shade600),
                    onSelected: (v) {
                      if (v == 'logout') context.read<AuthProvider>().logout();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'logout',
                        child: Row(children: [
                          Icon(Icons.logout,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          const Text('Logout'),
                        ]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Welcome View ─────────────────────────────────────────────────────────────

class _WelcomeView extends StatelessWidget {
  final String username;
  final bool isDesktop;
  final bool desktopSidebarOpen;
  final VoidCallback onToggleSidebar;
  final ValueChanged<String> onSend;

  const _WelcomeView({
    required this.username,
    required this.isDesktop,
    required this.desktopSidebarOpen,
    required this.onToggleSidebar,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFEEF0FF), Colors.white],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (!isDesktop || !desktopSidebarOpen)
                    IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: 'Open sidebar',
                      onPressed: onToggleSidebar,
                    ),
                  const Spacer(),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Hi $username,\nwhat can I help with?',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          height: 1.3,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const SizedBox(height: 40),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: _WelcomeInput(onSend: onSend),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          backgroundColor: const Color(0xFF6C63FF),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.school_outlined, size: 20),
                        label: const Text(
                          'Canvas 课程与图谱管理',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () {
                          final auth = context.read<AuthProvider>();
                          if (auth.user != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CanvasCoursesScreen(userId: auth.user!.userId),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Welcome Input ────────────────────────────────────────────────────────────

class _WelcomeInput extends StatefulWidget {
  final ValueChanged<String> onSend;
  const _WelcomeInput({required this.onSend});

  @override
  State<_WelcomeInput> createState() => _WelcomeInputState();
}

class _WelcomeInputState extends State<_WelcomeInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, shift: false): _submit,
              },
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                hintText: 'Ask anything...',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF6C63FF),
              child: IconButton(
                icon: const Icon(Icons.send, size: 18, color: Colors.white),
                onPressed: _submit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Chat View (embedded) ─────────────────────────────────────────────────────

class _ChatView extends StatefulWidget {
  final SessionModel session;
  final List<SessionModel> tabs;
  final Map<String, int> tabFixedIds;
  final Map<String, String> customTabNames;
  final bool isDesktop;
  final bool desktopSidebarOpen;
  final VoidCallback onToggleSidebar;
  final VoidCallback onBack;
  final ValueChanged<SessionModel> onTabSelected;
  final ValueChanged<SessionModel> onTabClosed;
  final void Function(SessionModel, String) onTabRenamed;
  final VoidCallback onFork;

  const _ChatView({
    super.key,
    required this.session,
    required this.tabs,
    required this.tabFixedIds,
    required this.customTabNames,
    required this.isDesktop,
    required this.desktopSidebarOpen,
    required this.onToggleSidebar,
    required this.onBack,
    required this.onTabSelected,
    required this.onTabClosed,
    required this.onTabRenamed,
    required this.onFork,
  });

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final _scrollCtrl = ScrollController();
  final _chatInputCtrl = TextEditingController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final atBottom = _scrollCtrl.position.pixels >=
          _scrollCtrl.position.maxScrollExtent - 80;
      if (_userScrolledUp && atBottom) {
        setState(() => _userScrolledUp = false);
      } else if (!_userScrolledUp && !atBottom) {
        setState(() => _userScrolledUp = true);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _chatInputCtrl.dispose();
    super.dispose();
  }

  void _showRenameDialog(SessionModel tab) {
    final ctrl = TextEditingController(text: tab.title ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Tab'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter new name'),
          onSubmitted: (val) {
            Navigator.pop(ctx);
            if (val.trim().isNotEmpty) {
              widget.onTabRenamed(tab, val.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (ctrl.text.trim().isNotEmpty) {
                widget.onTabRenamed(tab, ctrl.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (_userScrolledUp) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _buildExportText(List<MessageModel> messages, String sessionTitle) {
    final buf = StringBuffer();
    buf.writeln('Session: $sessionTitle');
    buf.writeln('Exported: ${DateTime.now().toLocal().toString().substring(0, 19)}');
    buf.writeln('Messages: ${messages.length}');
    buf.writeln('');

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      buf.writeln('=' * 60);

      // Role + timestamp
      final roleLabel = msg.role == 'user' ? '👤 User' : '🤖 Assistant';
      String timeStr = '';
      try {
        timeStr = DateTime.parse(msg.timestamp)
            .toLocal()
            .toString()
            .substring(0, 19);
      } catch (_) {
        timeStr = msg.timestamp;
      }
      buf.writeln('[$roleLabel]  $timeStr');
      buf.writeln('');

      // Render segments (interleaved text + tools) if available
      if (msg.segments.isNotEmpty) {
        for (final seg in msg.segments) {
          if (seg.type == SegmentType.text) {
            if (seg.text.trim().isNotEmpty) {
              buf.writeln(seg.text.trim());
              buf.writeln('');
            }
          } else if (seg.type == SegmentType.tool) {
            if (seg.toolCallIndex >= 0 &&
                seg.toolCallIndex < msg.toolCalls.length) {
              _writeToolCall(buf, msg.toolCalls[seg.toolCallIndex]);
            }
          }
        }
        // Final text (after all tool calls)
        if (msg.text.trim().isNotEmpty) {
          buf.writeln(msg.text.trim());
          buf.writeln('');
        }
      } else if (msg.toolCalls.isNotEmpty) {
        // Fallback: tool calls then text
        for (final tc in msg.toolCalls) {
          _writeToolCall(buf, tc);
        }
        if (msg.text.trim().isNotEmpty) {
          buf.writeln(msg.text.trim());
          buf.writeln('');
        }
      } else {
        // Plain text message
        buf.writeln(msg.text.trim());
        buf.writeln('');
      }
    }

    buf.writeln('=' * 60);
    buf.writeln('[ End of session ]');
    return buf.toString();
  }

  void _writeToolCall(StringBuffer buf, ToolCallInfo tc) {
    buf.writeln('┌─ Tool Call: ${tc.name}');

    // Args
    try {
      final argsStr =
          const JsonEncoder.withIndent('  ').convert(tc.args);
      buf.writeln('│ Args: $argsStr');
    } catch (_) {
      buf.writeln('│ Args: ${tc.args}');
    }

    // Result
    if (tc.result != null && tc.result!.isNotEmpty) {
      try {
        final decoded = jsonDecode(tc.result!);
        if (decoded is Map<String, dynamic>) {
          buf.writeln('│ Result:');
          decoded.forEach((key, value) {
            String valStr = value.toString().replaceAll('\n', ' ');
            if (valStr.length > 20) {
              valStr = '${valStr.substring(0, 20)}...';
            }
            buf.writeln('│   $key: $valStr');
          });
        } else if (decoded is List) {
          buf.writeln('│ Result: [List of ${decoded.length} items]');
          if (decoded.isNotEmpty && decoded.first is Map<String, dynamic>) {
             final firstObj = decoded.first as Map<String, dynamic>;
             buf.writeln('│ First Item Fields:');
             firstObj.forEach((key, value) {
                String valStr = value.toString().replaceAll('\n', ' ');
                if (valStr.length > 20) {
                  valStr = '${valStr.substring(0, 20)}...';
                }
                buf.writeln('│   $key: $valStr');
             });
          }
        } else {
          String rawStr = tc.result!.replaceAll('\n', ' ');
          if (rawStr.length > 500) rawStr = '${rawStr.substring(0, 500)}...';
          buf.writeln('│ Result: $rawStr');
        }
      } catch (_) {
        final resultPreview = tc.result!.length > 500
            ? '${tc.result!.substring(0, 500)}... (truncated)'
            : tc.result!;
        buf.writeln('│ Result: $resultPreview');
      }
    } else if (tc.isLoading) {
      buf.writeln('│ Result: (loading...)');
    }

    // Graph nodes
    if (tc.graphNodes.isNotEmpty) {
      buf.writeln('│ Graph Nodes (${tc.graphNodes.length}):');
      for (var n = 0; n < tc.graphNodes.length; n++) {
        final node = tc.graphNodes[n];
        buf.writeln('│   Node [${node.nodeId}]: ${node.title}');
      }
    }

    buf.writeln('└──────────────────────────────────────────────────');
    buf.writeln('');
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final title = widget.session.title ?? 'Chat';

    // Read messages for THIS specific session — never the global chat.messages
    // which depends on the mutable _sessionId and can leak across sessions.
    final sessionMessages = chat.getMessagesForSession(widget.session.id);
    final isLoading = chat.isLoadingSession(widget.session.id);
    final isStreaming = chat.isStreaming(widget.session.id);

    if (chat.memoryChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        chat.clearMemoryChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(children: [
                Icon(Icons.memory, size: 16, color: Colors.white),
                SizedBox(width: 8),
                Text('AI updated your memory'),
              ]),
              duration: Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
    }

    if (sessionMessages.isNotEmpty) _scrollToBottom();

    return Column(
      children: [
        // App bar & Tabs
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tabs row
              Row(
                children: widget.tabs.map((tab) {
                  final fixedId = widget.tabFixedIds[tab.id] ?? 1;
                  final isSelected = tab.id == widget.session.id;
                  
                  String displayText = '$fixedId';
                  if (widget.customTabNames.containsKey(tab.id)) {
                    displayText = widget.customTabNames[tab.id]!;
                  }
                  
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4, bottom: 4),
                      child: Material(
                        color: isSelected ? Colors.grey.shade200 : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () => widget.onTabSelected(tab),
                          onLongPress: () => _showRenameDialog(tab),
                          onDoubleTap: () => _showRenameDialog(tab),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    displayText,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (widget.tabs.length > 1) ...[
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: () => widget.onTabClosed(tab),
                                    child: Icon(Icons.close, size: 14, color: Colors.grey.shade600),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              Row(
                children: [
                  if (!widget.isDesktop || !widget.desktopSidebarOpen)
                    IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: 'Open sidebar',
                      onPressed: widget.onToggleSidebar,
                    ),
                  if (!widget.isDesktop)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: widget.onBack,
                    ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (sessionMessages.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.file_download_outlined,
                          color: Colors.grey.shade600),
                      tooltip: 'Export chat',
                      onPressed: () {
                        final exportText =
                            _buildExportText(sessionMessages, title);
                        Clipboard.setData(ClipboardData(text: exportText));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Row(children: [
                              Icon(Icons.check_circle,
                                  size: 18, color: Colors.white),
                              SizedBox(width: 8),
                              Text('Chat exported to clipboard'),
                            ]),
                            behavior: SnackBarBehavior.floating,
                            backgroundColor: Color(0xFF4CAF50),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        // Messages — strictly scoped to this session's data
        Expanded(
          child: isLoading && sessionMessages.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : sessionMessages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.send,
                              size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text(
                            'Send a message to start',
                            style: TextStyle(color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: sessionMessages.length,
                      itemBuilder: (_, i) {
                        final msg = sessionMessages[i];
                        return MessageBubble(
                          message: msg,
                          onRollback: msg.role == 'user'
                              ? () {
                                  _chatInputCtrl.text = msg.text;
                                  chat.rollbackToMessage(msg);
                                }
                              : null,
                        );
                      },
                    ),
        ),
        // Input
        Container(
          padding: const EdgeInsets.only(bottom: 4),
          color: Colors.white,
          child: SafeArea(
            top: false,
            child: ChatInput(
              controller: _chatInputCtrl,
              enabled: !isLoading && !isStreaming,
              onFork: widget.onFork,
              onSend: (text) {
                final auth = context.read<AuthProvider>();
                if (auth.user != null) {
                  chat.sendMessage(auth.user!.userId, text);
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}
