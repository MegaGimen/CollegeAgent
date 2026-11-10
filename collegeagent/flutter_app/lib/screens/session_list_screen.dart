import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/session_provider.dart';
import '../providers/chat_provider.dart';
import '../widgets/session_tile.dart';
import '../widgets/create_teaching_dialog.dart';
import 'chat_screen.dart';
import 'memory_screen.dart';

class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSessions());
    // Refresh sessions every 5s to pick up title changes and new messages
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadSessions());
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sessionProv = context.watch<SessionProvider>();
    final chat = context.watch<ChatProvider>();
    final user = auth.user;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_zip_outlined),
            tooltip: '课程文件下载',
            onPressed: () async {
              if (user != null) {
                await CreateTeachingDialog.show(context, user.userId);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.memory),
            tooltip: 'Memory',
            onPressed: () {
              if (user != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MemoryScreen(userId: user.userId),
                  ),
                );
              }
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') auth.logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    const Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: sessionProv.loading && sessionProv.sessions.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : sessionProv.sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        'No chats yet',
                        style: TextStyle(
                          fontSize: 18,
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap + to start a new chat',
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async => _loadSessions(),
                  child: ListView.separated(
                    itemCount: sessionProv.sessions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final session = sessionProv.sessions[i];
                      final unread = chat.getUnreadCount(session.id, session.msgCount);
                      return SessionTile(
                        session: session,
                        unreadCount: unread,
                        isStreaming: chat.isStreaming(session.id),
                        onDelete: user != null
                            ? () => sessionProv.deleteSession(session.id, user.userId)
                            : null,
                        onTap: () {
                          if (user != null) {
                            chat.openSession(user.userId, session.id);
                            chat.markSessionRead(session.id, session.msgCount);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(session: session),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: user != null ? () => _createNewSession(user.userId) : null,
        backgroundColor: const Color(0xFF0C132C),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Future<void> _createNewSession(String userId) async {
    final sessionProv = context.read<SessionProvider>();
    try {
      final session = await sessionProv.createSession(userId);
      if (!mounted) return;
      context.read<ChatProvider>().openSession(userId, session.id);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(session: session),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create session: $e')),
      );
    }
  }
}
