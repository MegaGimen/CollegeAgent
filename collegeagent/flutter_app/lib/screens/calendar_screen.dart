import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'package:intl/intl.dart';

class CalendarScreen extends StatefulWidget {
  final String userId;
  const CalendarScreen({super.key, required this.userId});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final ApiService _api = ApiService();
  bool _isLoading = true;
  List<dynamic> _events = [];
  String? _error;
  bool _needsAuth = false;

  @override
  void initState() {
    super.initState();
    _fetchEvents();
  }

  Future<void> _fetchEvents() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _needsAuth = false;
    });
    try {
      final data = await _api.getCalendarEvents(widget.userId);
      setState(() {
        _events = data;
        _isLoading = false;
      });
    } catch (e) {
      if (e.toString().contains('NEEDS_AUTH')) {
        setState(() {
          _needsAuth = true;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _connectGoogle() async {
    final url = Uri.parse('${_api.baseUrl}/oauth/google/connect?userId=${widget.userId}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      // Wait a bit, then refresh
      await Future.delayed(const Duration(seconds: 5));
      _fetchEvents();
    }
  }

  String _formatDate(dynamic start) {
    if (start == null) return '';
    if (start['dateTime'] != null) {
      final dt = DateTime.parse(start['dateTime']).toLocal();
      return DateFormat('MMM dd, yyyy - hh:mm a').format(dt);
    }
    if (start['date'] != null) {
      final dt = DateTime.parse(start['date']).toLocal();
      return DateFormat('MMM dd, yyyy (All Day)').format(dt);
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchEvents,
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_needsAuth) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.calendar_month, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Connect your Google Calendar to view events here and let the AI manage your schedule.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _connectGoogle,
              child: const Text('Connect Google Calendar'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _fetchEvents,
              child: const Text('I have connected, refresh now'),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(child: Text('Error: $_error', style: const TextStyle(color: Colors.red)));
    }
    if (_events.isEmpty) {
      return const Center(child: Text('No upcoming events found.'));
    }

    return ListView.builder(
      itemCount: _events.length,
      itemBuilder: (context, index) {
        final ev = _events[index];
        final title = ev['summary'] ?? 'No Title';
        final start = _formatDate(ev['start']);
        final link = ev['htmlLink'];

        return ListTile(
          leading: const Icon(Icons.event),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(start),
          trailing: link != null ? IconButton(
            icon: const Icon(Icons.open_in_new, size: 16),
            onPressed: () {
              launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
            },
          ) : null,
        );
      },
    );
  }
}
