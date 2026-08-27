import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'gmail_detail_screen.dart';

class GmailScreen extends StatefulWidget {
  final String userId;
  const GmailScreen({super.key, required this.userId});

  @override
  State<GmailScreen> createState() => _GmailScreenState();
}

class _GmailScreenState extends State<GmailScreen> {
  List<dynamic> _messages = [];
  bool _loading = true;
  bool _syncing = false;
  bool _needsAuth = false;
  String _errorOnScreen = '';
  Timer? _syncPollTimer;

  final ApiService _api = ApiService();

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _checkSyncStatus();
  }

  @override
  void dispose() {
    _syncPollTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _fetchMessages() async {
    try {
      final messages = await _api.getGmailMessages(widget.userId);
      if (!mounted) return;
      if (messages is List) {
        setState(() {
          _messages = messages;
          _loading = false;
          _needsAuth = false;
        });
      } else {
        throw Exception('Backend returned non-list: $messages');
      }
    } catch (e, stacktrace) {
      if (!mounted) return;
      if (e.toString().contains('NEEDS_AUTH')) {
        setState(() {
          _needsAuth = true;
          _loading = false;
        });
      } else {
        setState(() { 
          _loading = false; 
          _errorOnScreen = '$e\n\n$stacktrace';
        });
      }
    }
  }

  Future<void> _checkSyncStatus() async {
    try {
      final status = await _api.getGmailSyncStatus(widget.userId);
      if (!mounted) return;
      final isSyncing = status['syncing'] == true;
      setState(() {
        _syncing = isSyncing;
      });
      if (isSyncing) {
        _syncPollTimer?.cancel();
        _syncPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
          final s = await _api.getGmailSyncStatus(widget.userId);
          if (!mounted) return;
          if (s['syncing'] != true) {
            _syncPollTimer?.cancel();
            setState(() => _syncing = false);
            _fetchMessages();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Gmail 知识库同步完成')),
            );
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _triggerSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await _api.syncGmailVault(widget.userId);
      _checkSyncStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('同步失败: $e')),
      );
    }
  }

  void _loginGoogle() {
    final baseUrl = _api.baseUrl;
    final url = '$baseUrl/oauth/google/connect?userId=${widget.userId}';
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gmail Inbox'),
        actions: [
          if (!_needsAuth)
            TextButton.icon(
              onPressed: _syncing ? null : _triggerSync,
              icon: _syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync, size: 18),
              label: Text(_syncing ? '同步中...' : '同步到 Vault'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              setState(() {
                _loading = true;
                _errorOnScreen = '';
              });
              _fetchMessages();
              _checkSyncStatus();
            },
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    
    if (_errorOnScreen.isNotEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            'ERROR:\n$_errorOnScreen',
            style: const TextStyle(color: Colors.red, fontFamily: 'monospace'),
          ),
        ),
      );
    }
    
    if (_needsAuth) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mark_email_unread_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Gmail access required.', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loginGoogle,
              icon: const Icon(Icons.login),
              label: const Text('Connect Google Account'),
            ),
          ],
        ),
      );
    }

    if (_messages.isEmpty) return const Center(child: Text('No messages found.'));

    return ListView.separated(
      itemCount: _messages.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final ev = _messages[index];
        final inVault = ev['inVault'] == true;

        return ListTile(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  ev['subject'] ?? '(No Subject)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: inVault ? Colors.green.shade50 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: inVault ? Colors.green.shade300 : Colors.grey.shade300,
                  ),
                ),
                child: Text(
                  inVault ? '已入库' : '未入库',
                  style: TextStyle(
                    fontSize: 11,
                    color: inVault ? Colors.green.shade800 : Colors.grey.shade600,
                    fontWeight: inVault ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${ev['from']} • ${ev['date']}\n${ev['snippet']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GmailDetailScreen(
                  userId: widget.userId,
                  messageId: ev['id'],
                  subject: ev['subject'] ?? '(No Subject)',
                ),
              ),
            ).then((_) {
              _fetchMessages();
            });
          },
        );
      },
    );
  }
}
