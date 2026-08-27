import 'dart:async';
import 'package:flutter/material.dart';
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
          const SnackBar(content: Text('Memory saved & synced')),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Agent Memory'),
            if (_lastSyncTime != null)
              Text(
                'synced ${_formatSyncTime()}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        backgroundColor: const Color(0xFF6C63FF),
        foregroundColor: Colors.white,
        actions: [
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
              icon: const Icon(Icons.edit),
              onPressed: () => setState(() => _editing = true),
            ),
          if (_editing)
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              onPressed: _saving ? null : _save,
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _controller,
                    enabled: _editing,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: 'Memory content...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: !_editing,
                      fillColor: Colors.grey.shade50,
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
      ),
    );
  }
}
