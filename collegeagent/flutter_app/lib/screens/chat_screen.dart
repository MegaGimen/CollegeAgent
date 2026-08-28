import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_input.dart';

class ChatScreen extends StatefulWidget {
  final SessionModel session;
  const ChatScreen({super.key, required this.session});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _chatInputCtrl = TextEditingController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final atBottom = _scrollCtrl.position.pixels >=
          _scrollCtrl.position.maxScrollExtent - 80;
      if (_userScrolledUp && atBottom) {
        setState(() => _userScrolledUp = false);
      } else if (!_userScrolledUp && !atBottom) {
        setState(() => _userScrolledUp = true);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _chatInputCtrl.dispose();
    super.dispose();
  }

  void _showRollbackMenu(BuildContext context, Offset position, MessageModel msg, ChatProvider chat) async {
    final value = await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(
          value: 'rollback',
          child: Row(
            children: [
              Icon(Icons.history, color: Colors.blue),
              SizedBox(width: 8),
              Text('Rollback here'),
            ],
          ),
        ),
      ],
    );

    if (value == 'rollback') {
      _chatInputCtrl.text = msg.text;
      chat.rollbackToMessage(msg);
    }
  }

  void _scrollToBottom() {
    if (_userScrolledUp) return; // Don't force scroll if user is reading
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Generate export text for the chat session.
  String _buildExportText(List<MessageModel> messages, String sessionTitle) {
    final buf = StringBuffer();
    buf.writeln('Session: $sessionTitle');
    buf.writeln('Exported: ${DateTime.now().toLocal().toString().substring(0, 19)}');
    buf.writeln('Messages: ${messages.length}');
    buf.writeln('');

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      buf.writeln('=' * 60);

      // Role + timestamp
      final roleLabel = msg.role == 'user' ? '👤 User' : '🤖 Assistant';
      String timeStr = '';
      try {
        timeStr = DateTime.parse(msg.timestamp)
            .toLocal()
            .toString()
            .substring(0, 19);
      } catch (_) {
        timeStr = msg.timestamp;
      }
      buf.writeln('[$roleLabel]  $timeStr');
      buf.writeln('');

      // Render segments (interleaved text + tools) if available
      if (msg.segments.isNotEmpty) {
        for (final seg in msg.segments) {
          if (seg.type == SegmentType.text) {
            if (seg.text.trim().isNotEmpty) {
              buf.writeln(seg.text.trim());
              buf.writeln('');
            }
          } else if (seg.type == SegmentType.tool) {
            if (seg.toolCallIndex >= 0 &&
                seg.toolCallIndex < msg.toolCalls.length) {
              _writeToolCall(buf, msg.toolCalls[seg.toolCallIndex]);
            }
          }
        }
        // Final text (after all tool calls)
        if (msg.text.trim().isNotEmpty) {
          buf.writeln(msg.text.trim());
          buf.writeln('');
        }
      } else if (msg.toolCalls.isNotEmpty) {
        // Fallback: tool calls then text
        for (final tc in msg.toolCalls) {
          _writeToolCall(buf, tc);
        }
        if (msg.text.trim().isNotEmpty) {
          buf.writeln(msg.text.trim());
          buf.writeln('');
        }
      } else {
        // Plain text message
        buf.writeln(msg.text.trim());
        buf.writeln('');
      }
    }

    buf.writeln('=' * 60);
    buf.writeln('[ End of session ]');
    return buf.toString();
  }

  void _writeToolCall(StringBuffer buf, ToolCallInfo tc) {
    buf.writeln('┌─ Tool Call: ${tc.name}');

    // Args
    try {
      final argsStr =
          const JsonEncoder.withIndent('  ').convert(tc.args);
      buf.writeln('│ Args: $argsStr');
    } catch (_) {
      buf.writeln('│ Args: ${tc.args}');
    }

    // Result
    if (tc.result != null && tc.result!.isNotEmpty) {
      try {
        final decoded = jsonDecode(tc.result!);
        if (decoded is Map<String, dynamic>) {
          buf.writeln('│ Result:');
          decoded.forEach((key, value) {
            String valStr = value.toString().replaceAll('\n', ' ');
            if (valStr.length > 20) {
              valStr = '${valStr.substring(0, 20)}...';
            }
            buf.writeln('│   $key: $valStr');
          });
        } else if (decoded is List) {
          buf.writeln('│ Result: [List of ${decoded.length} items]');
          if (decoded.isNotEmpty && decoded.first is Map<String, dynamic>) {
             final firstObj = decoded.first as Map<String, dynamic>;
             buf.writeln('│ First Item Fields:');
             firstObj.forEach((key, value) {
                String valStr = value.toString().replaceAll('\n', ' ');
                if (valStr.length > 20) {
                  valStr = '${valStr.substring(0, 20)}...';
                }
                buf.writeln('│   $key: $valStr');
             });
          }
        } else {
          String rawStr = tc.result!.replaceAll('\n', ' ');
          if (rawStr.length > 500) rawStr = '${rawStr.substring(0, 500)}...';
          buf.writeln('│ Result: $rawStr');
        }
      } catch (_) {
        final resultPreview = tc.result!.length > 500
            ? '${tc.result!.substring(0, 500)}... (truncated)'
            : tc.result!;
        buf.writeln('│ Result: $resultPreview');
      }
    } else if (tc.isLoading) {
      buf.writeln('│ Result: (loading...)');
    }

    // Graph nodes
    if (tc.graphNodes.isNotEmpty) {
      buf.writeln('│ Graph Nodes (${tc.graphNodes.length}):');
      for (var n = 0; n < tc.graphNodes.length; n++) {
        final node = tc.graphNodes[n];
        buf.writeln('│   ${n + 1}. ${node.title}');
        if (node.sourceUrl != null) {
          buf.writeln('│      URL: ${node.sourceUrl}');
        }
        if (node.outboundLinks.isNotEmpty) {
          final links = node.outboundLinks
              .map((l) => l.title)
              .take(5)
              .join(', ');
          buf.writeln('│      Links: $links');
          if (node.outboundLinks.length > 5) {
            buf.writeln(
                '│      ... +${node.outboundLinks.length - 5} more');
          }
        }
      }
    }

    buf.writeln('└─');
    buf.writeln('');
  }

  void _showExportDialog(
      BuildContext context, ChatProvider chat, String sessionTitle) {
    final exportText = _buildExportText(chat.messages, sessionTitle);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (_, scrollCtrl) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF081226) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                border: isDark ? const Border(top: BorderSide(color: Color(0xFF1E4E79))) : null,
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    // Handle bar
                    Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 4),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Header
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.description_outlined,
                              size: 20, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C)),
                          const SizedBox(width: 8),
                          Text(
                            'Export Chat',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${exportText.length} chars',
                            style: TextStyle(
                                fontSize: 12, color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade200),
                    // Content
                    Expanded(
                      child: SingleChildScrollView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        child: SelectableText(
                          exportText,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                            color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                          ),
                        ),
                      ),
                    ),
                    // Copy button
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy to Clipboard'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? const Color(0xFF01385F) : const Color(0xFF0C132C),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: isDark ? const BorderSide(color: Color(0xFF1E4E79)) : BorderSide.none,
                            ),
                          ),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: exportText));
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.check_circle,
                                        size: 18, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('Chat exported to clipboard'),
                                  ],
                                ),
                                behavior: SnackBarBehavior.floating,
                                backgroundColor: Color(0xFF4CAF50),
                              ),
                            );
                          },
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final title = widget.session.title ?? 'Chat';

    // Show SnackBar when memory is updated by AI (write ops only)
    if (chat.memoryChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        chat.clearMemoryChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.memory, size: 16, color: Colors.white),
                  SizedBox(width: 8),
                  Text('AI updated your memory'),
                ],
              ),
              duration: Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
    }

    if (chat.messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFF0C132C),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (chat.messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.file_download_outlined),
              tooltip: 'Export chat',
              onPressed: () => _showExportDialog(context, chat, title),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
        children: [
          Expanded(
            child: chat.loading && chat.messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : chat.messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline,
                                size: 48, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text(
                              'What can I help with?',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: chat.messages.length,
                        itemBuilder: (_, i) {
                          final msg = chat.messages[i];
                          if (msg.role == 'user') {
                            return GestureDetector(
                              onSecondaryTapDown: (details) {
                                _showRollbackMenu(context, details.globalPosition, msg, chat);
                              },
                              child: MessageBubble(message: msg),
                            );
                          }
                          return MessageBubble(message: msg);
                        },
                      ),
          ),
          ChatInput(
            controller: _chatInputCtrl,
            enabled: !chat.loading,
            isStreaming: chat.sending,
            onStop: () => chat.stopStreaming(),
            onSend: (text) {
              if (auth.user != null) {
                chat.sendMessage(auth.user!.userId, text);
              }
            },
          ),
        ],
      ),
      ),
    );
  }
}
