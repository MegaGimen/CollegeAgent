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

    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              Icon(
                Icons.email,
                color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _message!['subject'] ?? widget.subject,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'From: ${_message!['from']}',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                      ),
                    ),
                    Text(
                      'Date: ${_message!['date']}',
                      style: TextStyle(
                        color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Divider(height: 32, color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300),
          if (inVault && content.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF01385F) : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade200,
                ),
              ),
              child: SelectionArea(
                child: MarkdownBody(
                  data: content,
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
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                        webOnlyWindowName: '_blank',
                      );
                    } catch (e) {
                      debugPrint('Failed to open URL $href: $e');
                    }
                  },
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                      fontSize: 14,
                      height: 1.6,
                    ),
                    h1: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                    strong: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                    code: TextStyle(
                      backgroundColor: isDark ? const Color(0xFF0C132C) : Colors.grey.shade200,
                      color: isDark ? const Color(0xFF93C5FD) : Colors.black87,
                      fontFamily: 'monospace',
                    ),
                    tableColumnWidth: const IntrinsicColumnWidth(),
                    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    tablePadding: const EdgeInsets.symmetric(vertical: 8),
                    tableBorder: TableBorder.all(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
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
          ] else ...[
            HtmlWidget(
              rawHtml,
              textStyle: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
              ),
            ),
          ],
          if (outboundLinks.isNotEmpty) ...[
            const SizedBox(height: 28),
            Divider(color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.hub_outlined,
                  size: 20,
                  color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                ),
                const SizedBox(width: 8),
                Text(
                  '1-Hop 关联外链节点 (${outboundLinks.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
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
                  color: isDark ? const Color(0xFF01385F) : Colors.blue.shade50.withOpacity(0.5),
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isDark ? const Color(0xFF1E4E79) : Colors.blue.shade100,
                    ),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.link,
                      color: isDark ? const Color(0xFF38BDF8) : Colors.blue,
                      size: 20,
                    ),
                    title: Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          url,
                          style: TextStyle(
                            color: isDark ? const Color(0xFF38BDF8) : Colors.blue.shade800,
                            fontSize: 11,
                          ),
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade700,
                            ),
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
