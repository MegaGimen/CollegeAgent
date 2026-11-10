import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/memory_version.dart';
import '../services/api_service.dart';

class MemoryScreen extends StatefulWidget {
  final String userId;
  const MemoryScreen({super.key, required this.userId});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _api = ApiService();
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _editing = false;
  String? _error;
  Timer? _syncTimer;
  String _lastSyncedContent = '';
  DateTime? _lastSyncTime;

  @override
  void initState() {
    super.initState();
    _loadMemory();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncFromServer());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _controller.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _loadMemory() async {
    try {
      final content = await _api.getMemory(widget.userId);
      _controller.text = content;
      _lastSyncedContent = content;
      _lastSyncTime = DateTime.now();
      _loading = false;
      setState(() {});
    } catch (e) {
      _loading = false;
      _error = e.toString();
      setState(() {});
    }
  }

  Future<void> _syncFromServer() async {
    if (_editing) return;
    try {
      final content = await _api.getMemory(widget.userId);
      if (content != _lastSyncedContent && mounted) {
        _controller.text = content;
        _lastSyncedContent = content;
        _lastSyncTime = DateTime.now();
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    _saving = true;
    setState(() {});
    try {
      await _api.putMemory(widget.userId, _controller.text);
      _lastSyncedContent = _controller.text;
      _lastSyncTime = DateTime.now();
      _saving = false;
      _editing = false;
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory saved & snapshot created')),
        );
      }
    } catch (e) {
      _saving = false;
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  String _formatSyncTime() {
    if (_lastSyncTime == null) return '';
    final diff = DateTime.now().difference(_lastSyncTime!);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  void _openVersionHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MemoryVersionHistorySheet(
        userId: widget.userId,
        api: _api,
        onRollbackSuccess: (newContent, versionNum) {
          setState(() {
            _controller.text = newContent;
            _lastSyncedContent = newContent;
            _lastSyncTime = DateTime.now();
            _editing = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Rolled back to v$versionNum (new snapshot created)'),
              backgroundColor: const Color(0xFF0284C7),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0C132C) : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Agent Memory'),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _editing
                        ? const Color(0xFFF59E0B).withOpacity(0.2)
                        : const Color(0xFF38BDF8).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _editing ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    _editing ? 'Editing' : 'Markdown Preview',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: _editing ? const Color(0xFFFCD34D) : const Color(0xFF7DD3FC),
                    ),
                  ),
                ),
              ],
            ),
            if (_lastSyncTime != null)
              Text(
                'synced ${_formatSyncTime()}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                  color: isDark ? const Color(0xFF8DA4C4) : Colors.white70,
                ),
              ),
          ],
        ),
        backgroundColor: const Color(0xFF0C132C),
        foregroundColor: Colors.white,
        actions: [
          if (!_editing)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Version history',
              onPressed: _openVersionHistory,
            ),
          if (!_editing)
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sync now',
              onPressed: () async {
                await _syncFromServer();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Memory synced'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          if (!_editing && !_loading)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit memory',
              onPressed: () => setState(() => _editing = true),
            ),
          if (_editing)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel edit',
              onPressed: () => setState(() {
                _controller.text = _lastSyncedContent;
                _editing = false;
              }),
            ),
          if (_editing)
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check),
              tooltip: 'Save memory',
              onPressed: _saving ? null : _save,
            ),
        ],
      ),
      floatingActionButton: !_loading && !_editing && _error == null
          ? FloatingActionButton(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              tooltip: 'Edit memory',
              onPressed: () => setState(() => _editing = true),
              child: const Icon(Icons.edit),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(
                      'Error: $_error',
                      style: TextStyle(color: isDark ? Colors.redAccent : Colors.red),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: _editing
                        ? TextField(
                            controller: _controller,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: isDark ? const Color(0xFF38BDF8) : const Color(0xFF01385F),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14,
                              height: 1.5,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Memory content (Markdown supported)...',
                              hintStyle: TextStyle(
                                color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade400,
                              ),
                              filled: true,
                              fillColor: isDark ? const Color(0xFF01385F) : Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF01385F),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          )
                        : Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF081226) : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Markdown(
                                data: _controller.text.trim().isEmpty
                                    ? '*No memory recorded yet. Click edit to add memory.*'
                                    : _controller.text,
                                selectable: true,
                                padding: const EdgeInsets.all(16),
                                onTapLink: (text, href, title) async {
                                  if (href == null || href.trim().isEmpty) return;
                                  try {
                                    String urlStr = href.trim();
                                    if (!urlStr.startsWith('http://') &&
                                        !urlStr.startsWith('https://') &&
                                        !urlStr.startsWith('mailto:')) {
                                      urlStr = 'https://$urlStr';
                                    }
                                    final uri = Uri.parse(urlStr);
                                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                                  } catch (e) {
                                    debugPrint('Failed to open URL $href: $e');
                                  }
                                },
                                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                  p: TextStyle(
                                    fontSize: 14,
                                    height: 1.6,
                                    color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                                  ),
                                  h1: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : const Color(0xFF0C132C),
                                  ),
                                  h2: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : const Color(0xFF0C132C),
                                  ),
                                  h3: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : const Color(0xFF0C132C),
                                  ),
                                  code: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                    color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                  ),
                                  codeblockDecoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF020617) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  blockquote: TextStyle(
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                    fontStyle: FontStyle.italic,
                                  ),
                                  blockquoteDecoration: BoxDecoration(
                                    border: Border(
                                      left: BorderSide(
                                        color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                        width: 4,
                                      ),
                                    ),
                                  ),
                                  listBullet: TextStyle(
                                    color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                  ),
                                  tableColumnWidth: const IntrinsicColumnWidth(),
                                  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  tablePadding: const EdgeInsets.symmetric(vertical: 8),
                                  tableBorder: TableBorder.all(
                                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  tableHead: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                  tableBody: TextStyle(
                                    color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
      ),
    );
  }
}

class MemoryVersionHistorySheet extends StatefulWidget {
  final String userId;
  final ApiService api;
  final void Function(String newContent, int versionNum) onRollbackSuccess;

  const MemoryVersionHistorySheet({
    super.key,
    required this.userId,
    required this.api,
    required this.onRollbackSuccess,
  });

  @override
  State<MemoryVersionHistorySheet> createState() => _MemoryVersionHistorySheetState();
}

class _MemoryVersionHistorySheetState extends State<MemoryVersionHistorySheet> {
  List<MemoryVersion> _versions = [];
  bool _loading = true;
  String? _error;
  String? _rollingBackVersionId;

  @override
  void initState() {
    super.initState();
    _fetchVersions();
  }

  Future<void> _fetchVersions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.api.getMemoryVersions(widget.userId);
      list.sort((a, b) => b.version.compareTo(a.version));
      if (mounted) {
        setState(() {
          _versions = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  Widget _buildSourceBadge(String source, bool isDark) {
    Color bg;
    Color fg;
    String label;

    switch (source) {
      case 'agent_pre':
        bg = isDark ? const Color(0xFF312E81) : const Color(0xFFEEF2FF);
        fg = isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5);
        label = 'Agent Pre-Edit';
        break;
      case 'agent_post':
        bg = isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5);
        fg = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF059669);
        label = 'Agent Post-Edit';
        break;
      case 'user_edit':
        bg = isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7);
        fg = isDark ? const Color(0xFFFCD34D) : const Color(0xFFD97706);
        label = 'User Edit';
        break;
      case 'rollback':
        bg = isDark ? const Color(0xFF831843) : const Color(0xFFFCE7F3);
        fg = isDark ? const Color(0xFFF472B6) : const Color(0xFFDB2777);
        label = 'Rollback';
        break;
      default:
        bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
        fg = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        label = 'Initial';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Future<void> _confirmAndRollback(MemoryVersion ver) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rollback to v${ver.version}?'),
        content: Text(
          'This will restore memory to the state of v${ver.version} (${ver.summary}).\n\nA new rollback version snapshot will be created automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm Rollback'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _rollingBackVersionId = ver.id);
    try {
      final newContent = await widget.api.rollbackMemory(widget.userId, ver.id);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onRollbackSuccess(newContent, ver.version);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _rollingBackVersionId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rollback failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _previewVersion(MemoryVersion ver) {
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: isDark ? const Color(0xFF081226) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'v${ver.version}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0C132C),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildSourceBadge(ver.source, isDark),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  Text(
                    '${ver.summary} • ${_formatDateTime(ver.timestamp)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF020617) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Markdown(
                          data: ver.content.isEmpty ? '*Empty content*' : ver.content,
                          selectable: true,
                          padding: const EdgeInsets.all(16),
                          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(ctx)).copyWith(
                            tableColumnWidth: const IntrinsicColumnWidth(),
                            tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            tablePadding: const EdgeInsets.symmetric(vertical: 8),
                            tableBorder: TableBorder.all(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.restore, size: 18),
                        label: Text('Rollback to v${ver.version}'),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _confirmAndRollback(ver);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0C132C) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.history,
                  color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Memory Version History (Max 20)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0C132C),
                        ),
                      ),
                      Text(
                        'Snapshots before/after edits. Rollback creates a new version.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _fetchVersions,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Error loading versions: $_error',
                              style: TextStyle(color: isDark ? Colors.redAccent : Colors.red),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: _fetchVersions,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _versions.isEmpty
                        ? Center(
                            child: Text(
                              'No version snapshots recorded yet.',
                              style: TextStyle(
                                color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _versions.length,
                            separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                            itemBuilder: (ctx, i) {
                              final ver = _versions[i];
                              final isRollingBack = _rollingBackVersionId == ver.id;

                              return Container(
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF081226) : const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0284C7).withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: const Color(0xFF0284C7), width: 0.8),
                                            ),
                                            child: Text(
                                              'v${ver.version}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF38BDF8),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildSourceBadge(ver.source, isDark),
                                          const Spacer(),
                                          Text(
                                            _formatDateTime(ver.timestamp),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        ver.summary,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${ver.charCount} characters • ${ver.lineCount} lines',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade600,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              minimumSize: const Size(0, 32),
                                            ),
                                            icon: const Icon(Icons.visibility_outlined, size: 16),
                                            label: const Text('Preview', style: TextStyle(fontSize: 12)),
                                            onPressed: () => _previewVersion(ver),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFF0284C7),
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              minimumSize: const Size(0, 32),
                                            ),
                                            icon: isRollingBack
                                                ? const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                                  )
                                                : const Icon(Icons.restore, size: 16),
                                            label: const Text('Rollback', style: TextStyle(fontSize: 12)),
                                            onPressed: isRollingBack ? null : () => _confirmAndRollback(ver),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
