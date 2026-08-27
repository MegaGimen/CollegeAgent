import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class GmailDetailScreen extends StatefulWidget {
  final String userId;
  final String messageId;
  final String subject;
  const GmailDetailScreen({super.key, required this.userId, required this.messageId, required this.subject});

  @override
  State<GmailDetailScreen> createState() => _GmailDetailScreenState();
}

class _GmailDetailScreenState extends State<GmailDetailScreen> {
  Map<String, dynamic>? _message;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchMessage();
  }

  final ApiService _api = ApiService();

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  Future<void> _fetchMessage() async {
    try {
      final msg = await _api.getGmailMessageHtml(widget.userId, widget.messageId);
      if (!mounted) return;
      setState(() {
        _message = msg;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final inVault = _message?['inVault'] == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.subject),
        actions: [
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: inVault ? Colors.green.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: inVault ? Colors.green.shade300 : Colors.grey.shade300,
                    ),
                  ),
                  child: Text(
                    inVault ? 'Private Vault' : '未入库',
                    style: TextStyle(
                      fontSize: 12,
                      color: inVault ? Colors.green.shade800 : Colors.grey.shade600,
                      fontWeight: inVault ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_message == null) return const Center(child: Text('Failed to load message.'));

    final inVault = _message!['inVault'] == true;
    final content = _message!['content'] ?? '';
    final rawHtml = _message!['html'] ?? '';
    final outboundLinks = (_message!['outboundLinks'] as List<dynamic>?) ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.email, color: Color(0xFF6C63FF), size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _message!['subject'] ?? widget.subject,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'From: ${_message!['from']}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Date: ${_message!['date']}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 32),
          if (inVault && content.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: SelectionArea(
                child: MarkdownBody(
                  data: content,
                  onTapLink: (text, href, title) {
                    if (href != null) {
                      launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
                    }
                  },
                ),
              ),
            ),
          ] else ...[
            HtmlWidget(
              rawHtml,
              textStyle: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ],
          if (outboundLinks.isNotEmpty) ...[
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.hub_outlined, size: 20, color: Color(0xFF6C63FF)),
                const SizedBox(width: 8),
                Text(
                  '1-Hop 关联外链节点 (${outboundLinks.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: outboundLinks.length,
              itemBuilder: (context, idx) {
                final link = outboundLinks[idx];
                final url = link['url'] ?? '';
                final title = link['title'] ?? 'External Node';
                final summary = link['summary'] ?? '';

                return Card(
                  elevation: 0,
                  color: Colors.blue.shade50.withOpacity(0.5),
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Colors.blue.shade100),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.link, color: Colors.blue, size: 20),
                    title: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          url,
                          style: TextStyle(color: Colors.blue.shade800, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            summary,
                            style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                    trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
                    onTap: () {
                      if (url.isNotEmpty) {
                        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                      }
                    },
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
