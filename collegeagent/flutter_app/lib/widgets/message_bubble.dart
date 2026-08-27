import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
    return SelectionArea(
      child: MarkdownBody(
        data: text,
        inlineSyntaxes: [CitationSyntax()],
        builders: {
          'citation': CitationBuilder(
            citations: message.citations,
            context: context,
          ),
        },
        styleSheet: MarkdownStyleSheet(
          p: const TextStyle(
            color: Colors.black87,
            fontSize: 15,
            height: 1.4,
          ),
          code: TextStyle(
            backgroundColor: Colors.grey.shade200,
            fontFamily: 'monospace',
            fontSize: 13,
          ),
          codeblockDecoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(6),
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Colors.grey.shade400, width: 3),
            ),
          ),
          listBullet: const TextStyle(fontSize: 15),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
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
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: Color(0xFF6C63FF),
                  child: Icon(Icons.smart_toy, size: 18, color: Colors.white),
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
                        : const Color(0xFFF0F0F0),
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
                      // Render body based on segments (interleaved text + tools) or fallback
                      if (!isUser && message.segments.isNotEmpty)
                        ..._buildSegmentedContent(context, message, rawText)
                      else if (!isUser && message.toolCalls.isNotEmpty)
                        ...[
                          ...message.toolCalls
                              .map((tc) => ToolCallCard(toolCall: tc)),
                          const SizedBox(height: 6),
                          _buildMarkdownBody(context, rawText),
                        ]
                      else if (isUser)
                        SelectableText(
                          rawText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        )
                      else
                        _buildMarkdownBody(context, rawText),
                      const SizedBox(height: 4),
                      Text(
                        parsed != null ? timeFormat.format(parsed) : '',
                        style: TextStyle(
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.7)
                              : Colors.black.withValues(alpha: 0.45),
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
                        const Icon(Icons.copy, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text('Copy', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
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
                          const Icon(Icons.history, size: 14, color: Colors.blue),
                          const SizedBox(width: 4),
                          Text('Rollback', style: TextStyle(fontSize: 12, color: Colors.blue)),
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
  List<Widget> _buildSegmentedContent(
      BuildContext context, MessageModel message, String rawFullText) {
    final widgets = <Widget>[];
    for (final segment in message.segments) {
      if (segment.type == SegmentType.text) {
        final segRaw = _fixText(segment.text);
        if (segRaw.trim().isNotEmpty) {
          widgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildMarkdownBody(context, segRaw),
          ));
        }
      } else if (segment.type == SegmentType.tool) {
        final idx = segment.toolCallIndex;
        if (idx >= 0 && idx < message.toolCalls.length) {
          widgets.add(ToolCallCard(toolCall: message.toolCalls[idx]));
        }
      }
    }
    // Final text after all tool calls
    if (rawFullText.trim().isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _buildMarkdownBody(context, rawFullText),
      ));
    }
    return widgets;
  }
}
