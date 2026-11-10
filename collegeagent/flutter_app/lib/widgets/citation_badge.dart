import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../screens/knowledge_graph_screen.dart';

/// Utility to show a citation detail bottom sheet.
class CitationBottomSheet {
  /// Strip line-number prefixes (e.g. "  42|text") from content.
  static String _stripLineNumbers(String text) {
    return text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\|'), ''))
        .join('\n');
  }

  static Future<void> handleLink(String? href) async {
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
  }

  static void show(BuildContext context, Citation citation) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          builder: (_, scrollCtrl) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle bar
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 8, bottom: 4),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  // Header with index badge + title
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C63FF),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${citation.index}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            citation.title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // Content
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Relevant excerpt
                          if (citation.snippet != null &&
                              citation.snippet!.isNotEmpty) ...[
                            Row(
                              children: [
                                Icon(Icons.format_quote,
                                    size: 14, color: Colors.grey.shade600),
                                const SizedBox(width: 4),
                                Text(
                                  '引用内容',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8F7FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFE8E5F0),
                                ),
                              ),
                              child: SelectionArea(
                                child: MarkdownBody(
                                  data: _stripLineNumbers(citation.snippet!),
                                  onTapLink: (text, href, title) =>
                                      CitationBottomSheet.handleLink(href),
                                  styleSheet: MarkdownStyleSheet(
                                  p: const TextStyle(
                                      fontSize: 13, height: 1.6),
                                  h1: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                  h2: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold),
                                  h3: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                  code: TextStyle(
                                    backgroundColor: Colors.grey.shade200,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                  blockquoteDecoration: BoxDecoration(
                                    border: Border(
                                      left: BorderSide(
                                          color: Colors.grey.shade400,
                                          width: 3),
                                    ),
                                  ),
                                  tableColumnWidth: const IntrinsicColumnWidth(),
                                  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  tablePadding: const EdgeInsets.symmetric(vertical: 8),
                                  tableBorder: TableBorder.all(
                                    color: Colors.grey.shade300,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                          // View page relationship button
                          if (citation.nodeId != null) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.bubble_chart_outlined, size: 16),
                                label: const Text('查看页面跳转关系'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF4A148C),
                                  side: const BorderSide(color: Color(0xFFD1C4E9)),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => KnowledgeGraphScreen(
                                        nodeId: citation.nodeId!,
                                        title: citation.title,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                          // Load full content button
                          if (citation.nodeId != null) ...[
                            const SizedBox(height: 8),
                            _LoadFullContentButton(citation: citation),
                          ],
                          // Source URL + crawled date info
                          if ((citation.sourceUrl != null && citation.sourceUrl!.isNotEmpty) ||
                              (citation.crawledAt != null && citation.crawledAt!.isNotEmpty)) ...[
                            const SizedBox(height: 10),
                            // Crawled date
                            if (citation.crawledAt != null && citation.crawledAt!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Icon(Icons.calendar_today,
                                        size: 12, color: Colors.grey.shade500),
                                    const SizedBox(width: 4),
                                    Text(
                                      '爬取于 ${CitationBottomSheet.formatDate(citation.crawledAt!)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Source URL
                            if (citation.sourceUrl != null && citation.sourceUrl!.isNotEmpty)
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: citation.sourceUrl!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('链接已复制'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF0F4FF),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: const Color(0xFFD0DAFF)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.link,
                                        size: 14,
                                        color: Color(0xFF4A6CF7)),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        citation.sourceUrl!,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF4A6CF7),
                                          decoration:
                                              TextDecoration.underline,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(Icons.copy,
                                        size: 12,
                                        color: Color(0xFF4A6CF7)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              ),
            );
          },
        );
      },
    );
  }

  /// Format ISO timestamp to human-readable date string.
  static String formatDate(String isoString) {
    try {
      final dt = DateTime.parse(isoString);
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (_) {
      return isoString;
    }
  }
}

/// Button that loads the full markdown content of a citation's graph node.
class _LoadFullContentButton extends StatefulWidget {
  final Citation citation;

  const _LoadFullContentButton({required this.citation});

  @override
  State<_LoadFullContentButton> createState() => _LoadFullContentButtonState();
}

class _LoadFullContentButtonState extends State<_LoadFullContentButton> {
  bool _loading = false;
  String? _fullContent;
  String? _sourceUrl;
  String? _crawledAt;
  String? _error;

  Future<void> _loadContent() async {
    if (_fullContent != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final baseUrl = 'https://llinker.com/collegeagent-api';
      final res = await http.get(
        Uri.parse('$baseUrl/api/graph/node/${widget.citation.nodeId}'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        String content = data['content'] as String? ?? '(empty)';
        // Strip line-number prefixes if present
        content = content.split('\n')
            .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\|'), ''))
            .join('\n');
        // Strip metadata header, keep only actual content
        final contentIdx = content.indexOf('## Content');
        if (contentIdx != -1) {
          content = content
              .substring(contentIdx + '## Content'.length)
              .trim();
        }
        setState(() {
          _fullContent = content;
          _sourceUrl = data['sourceUrl'] as String?;
          _crawledAt = data['crawledAt'] as String?;
          _loading = false;
        });
      } else {
        setState(() {
          _error = '加载失败 (${res.statusCode})';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fullContent != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.article_outlined,
                  size: 14, color: Colors.grey.shade600),
              const SizedBox(width: 4),
              Text(
                '完整内容',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          // Source URL + crawled date
          if (_crawledAt != null || _sourceUrl != null) ...[
            const SizedBox(height: 4),
            if (_crawledAt != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 11, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      '爬取于 ${CitationBottomSheet.formatDate(_crawledAt!)}',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            if (_sourceUrl != null && _sourceUrl!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.link, size: 11, color: Color(0xFF4A6CF7)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _sourceUrl!,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF4A6CF7),
                          decoration: TextDecoration.underline,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: SelectionArea(
              child: MarkdownBody(
                data: _fullContent!,
                onTapLink: (text, href, title) =>
                    CitationBottomSheet.handleLink(href),
                styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 13, height: 1.5),
                h1: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
                h2: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
                h3: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold),
                code: TextStyle(
                  backgroundColor: Colors.grey.shade200,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                blockquoteDecoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        color: Colors.grey.shade400, width: 3),
                  ),
                ),
                tableColumnWidth: const IntrinsicColumnWidth(),
                tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                tablePadding: const EdgeInsets.symmetric(vertical: 8),
                tableBorder: TableBorder.all(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: _loading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            : const Icon(Icons.download, size: 16),
        label: Text(_error ?? '加载完整来源内容'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFEDE7F6),
          foregroundColor: const Color(0xFF4A148C),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFD1C4E9)),
          ),
        ),
        onPressed: _loading ? null : _loadContent,
      ),
    );
  }
}

/// Inline badge for rendering citations directly next to text (like academic paper citations).
class CitationInlineBadge extends StatefulWidget {
  final Citation citation;
  final String label;
  final VoidCallback onTap;

  const CitationInlineBadge({
    super.key,
    required this.citation,
    required this.label,
    required this.onTap,
  });

  @override
  State<CitationInlineBadge> createState() => _CitationInlineBadgeState();
}

class _CitationInlineBadgeState extends State<CitationInlineBadge> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF6C63FF);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.citation.title.isNotEmpty
            ? widget.citation.title
            : '引用来源 ${widget.label}',
        waitDuration: const Duration(milliseconds: 200),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2.0),
            padding: const EdgeInsets.symmetric(horizontal: 5.0, vertical: 1.0),
            decoration: BoxDecoration(
              color: _hovered
                  ? primaryColor.withValues(alpha: 0.22)
                  : primaryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _hovered
                    ? primaryColor.withValues(alpha: 0.70)
                    : primaryColor.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _hovered ? primaryColor : primaryColor.withValues(alpha: 0.95),
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom inline markdown syntax that matches numeric and legacy citation tags in markdown text.
class CitationSyntax extends md.InlineSyntax {
  int _counter = 0;

  CitationSyntax()
      : super(r'\[Source:\s*[^\]]+\]|\[\s*\d+[^\]]*\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    _counter++;
    final raw = match.group(0)!;
    final el = md.Element('citation', [md.Text(raw)]);
    el.attributes['raw'] = raw;
    el.attributes['matchIdx'] = '$_counter';
    parser.addNode(el);
    return true;
  }
}

/// Custom element builder for rendering citation tags as inline WidgetSpans in MarkdownBody.
class CitationBuilder extends MarkdownElementBuilder {
  final List<Citation> citations;
  final BuildContext context;

  CitationBuilder({
    required this.citations,
    required this.context,
  });

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = element.attributes['raw'] ?? element.textContent;
    final matchIdx = int.tryParse(element.attributes['matchIdx'] ?? '') ?? 0;

    Citation? citation;
    try {
      citation = citations.firstWhere((c) => c.index == matchIdx);
    } catch (_) {}

    int? parsedSourceId;
    final numMatch = RegExp(r'\[(\d+)').firstMatch(raw);
    if (numMatch != null) {
      parsedSourceId = int.tryParse(numMatch.group(1)!);
    }

    if (citation == null && parsedSourceId != null) {
      try {
        citation = citations.firstWhere((c) => c.sourceId == parsedSourceId);
      } catch (_) {}
    }

    citation ??= Citation(
      index: matchIdx > 0 ? matchIdx : (parsedSourceId ?? 1),
      title: parsedSourceId != null ? 'Source $parsedSourceId' : raw,
    );

    String label;
    if (raw.startsWith('[Source:')) {
      label = '[${citation.index}]';
    } else {
      label = raw.replaceAllMapped(
        RegExp(r'\[\s*(\d+)\s*(?:,\s*(\d+)(?:\s*[\-,]\s*(\d+))?)?\s*\]'),
        (m) {
          final id = m.group(1)!;
          if (m.group(2) != null) {
            final start = m.group(2)!;
            final end = m.group(3) != null ? '-${m.group(3)!}' : '';
            return '[$id, $start$end]';
          }
          return '[$id]';
        },
      );
      if (!label.startsWith('[')) label = '[$label]';
    }

    final targetCitation = citation;

    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: CitationInlineBadge(
          citation: targetCitation,
          label: label,
          onTap: () => CitationBottomSheet.show(context, targetCitation),
        ),
      ),
    );
  }
}

