import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/citation_badge.dart';
import 'package:intl/intl.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final VoidCallback? onRollback;

  const MessageBubble({super.key, required this.message, this.onRollback});

  String _fixText(String raw) {
    return raw.replaceAll('\\n', '\n');
  }

  Widget _buildMarkdownBody(BuildContext context, String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SelectionArea(
      child: MarkdownBody(
        data: text,
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
        inlineSyntaxes: [CitationSyntax()],
        builders: {
          'citation': CitationBuilder(
            citations: message.citations,
            context: context,
          ),
        },
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
            fontSize: 15,
            height: 1.4,
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
            fontSize: 13,
          ),
          codeblockDecoration: BoxDecoration(
            color: isDark ? const Color(0xFF0C132C) : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(6),
            border: isDark ? Border.all(color: const Color(0xFF1E4E79)) : null,
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF01385F),
                width: 3,
              ),
            ),
          ),
          listBullet: TextStyle(
            color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
            fontSize: 15,
          ),
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          tablePadding: const EdgeInsets.symmetric(vertical: 8),
          tableBorder: TableBorder.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
            borderRadius: BorderRadius.circular(4),
          ),
          tableBody: TextStyle(
            color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
          ),
          tableHead: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final timeFormat = DateFormat.Hm();
    DateTime? parsed;
    try {
      parsed = DateTime.parse(message.timestamp).toLocal();
    } catch (_) {}

    final rawText = _fixText(message.text);

    return Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser)
                CircleAvatar(
                  radius: 16,
                  backgroundColor: isDark ? const Color(0xFF01385F) : const Color(0xFF0C132C),
                  child: const Icon(Icons.smart_toy, size: 18, color: Colors.white),
                ),
              if (!isUser) const SizedBox(width: 8),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser
                        ? const Color(0xFF2196F3)
                        : (isDark ? const Color(0xFF01385F) : const Color(0xFFF0F0F0)),
                    border: isUser
                        ? null
                        : (isDark ? Border.all(color: const Color(0xFF1E4E79)) : null),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isUser)
                        SelectableText(
                          rawText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        )
                      else ...[
                        if (message.segments.isNotEmpty || message.toolCalls.isNotEmpty)
                          ThinkingCollapsible(
                            message: message,
                            buildMarkdown: (text) => _buildMarkdownBody(context, text),
                          ),
                        if (rawText.trim().isNotEmpty || (message.segments.isEmpty && message.toolCalls.isEmpty))
                          _buildMarkdownBody(context, rawText),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        parsed != null ? timeFormat.format(parsed) : '',
                        style: TextStyle(
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.7)
                              : (isDark ? const Color(0xFF8DA4C4) : Colors.black.withValues(alpha: 0.45)),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isUser) const SizedBox(width: 8),
            ],
          ),
        ),
        if (isUser)
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Text copied to clipboard'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.copy,
                          size: 14,
                          color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Copy',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (onRollback != null)
                  InkWell(
                    onTap: onRollback,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.history,
                            size: 14,
                            color: isDark ? const Color(0xFF64B5F6) : Colors.blue,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Rollback',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? const Color(0xFF64B5F6) : Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Build the interleaved text + tool call content from segments.
  }

class ThinkingCollapsible extends StatefulWidget {
  final MessageModel message;
  final Widget Function(String text) buildMarkdown;

  const ThinkingCollapsible({super.key, required this.message, required this.buildMarkdown});

  @override
  State<ThinkingCollapsible> createState() => _ThinkingCollapsibleState();
}

class _ThinkingCollapsibleState extends State<ThinkingCollapsible> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    String statusText = "Thought process";
    bool isActive = false;

    if (widget.message.toolCalls.any((tc) => tc.isLoading)) {
      final activeTool = widget.message.toolCalls.lastWhere((tc) => tc.isLoading);
      statusText = "calling tool: ${activeTool.name}...";
      isActive = true;
    } else if (widget.message.text.isEmpty) {
      statusText = "thinking...";
      isActive = true;
    } else {
      if (widget.message.toolCalls.isEmpty) {
        statusText = "Thinking process";
      } else {
        statusText = "Tool calls & thinking (${widget.message.toolCalls.length})";
      }
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600;

    final expandedWidgets = <Widget>[];
    for (final segment in widget.message.segments) {
      if (segment.type == SegmentType.text) {
        final segRaw = segment.text.replaceAll('\\n', '\n');
        if (segRaw.trim().isNotEmpty) {
          expandedWidgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: widget.buildMarkdown(segRaw),
          ));
        }
      } else if (segment.type == SegmentType.tool) {
        final idx = segment.toolCallIndex;
        if (idx >= 0 && idx < widget.message.toolCalls.length) {
          expandedWidgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ToolCallCard(toolCall: widget.message.toolCalls[idx]),
          ));
        }
      }
    }
    
    if (expandedWidgets.isEmpty && widget.message.toolCalls.isNotEmpty) {
      for (final tc in widget.message.toolCalls) {
        expandedWidgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ToolCallCard(toolCall: tc),
        ));
      }
    }

    if (expandedWidgets.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _isExpanded = !_isExpanded;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 4),
                if (isActive) ...[
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded)
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 8),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? Colors.black12 : Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: expandedWidgets,
            ),
          ),
      ],
    );
  }
}
