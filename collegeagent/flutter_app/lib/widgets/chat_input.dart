import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatInput extends StatefulWidget {
  final bool enabled;
  final bool isStreaming;
  final ValueChanged<String> onSend;
  final VoidCallback? onStop;
  final TextEditingController? controller;
  final VoidCallback? onFork;

  const ChatInput({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.isStreaming = false,
    this.onStop,
    this.controller,
    this.onFork,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  late TextEditingController _controller;
  final _focusNode = FocusNode();
  bool _ownController = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = TextEditingController();
      _ownController = true;
    }
  }

  @override
  void dispose() {
    if (_ownController) _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    _controller.clear();
    setState(() {});
    widget.onSend(text);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0C132C) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.05),
            blurRadius: isDark ? 6 : 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter, shift: false): _submit,
                },
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: widget.enabled,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(
                      color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade400,
                    ),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF01385F) : Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: isDark
                          ? const BorderSide(color: Color(0xFF1E4E79))
                          : BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: isDark
                          ? const BorderSide(color: Color(0xFF1E4E79))
                          : BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                        width: 1.5,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.onFork != null) ...[
              CircleAvatar(
                radius: 22,
                backgroundColor: isDark ? const Color(0xFF01385F) : Colors.grey.shade200,
                child: IconButton(
                  icon: Icon(
                    Icons.fork_right,
                    size: 20,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  tooltip: 'Fork as Subagent',
                  onPressed: widget.onFork,
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (widget.isStreaming && widget.onStop != null)
              CircleAvatar(
                radius: 22,
                backgroundColor: isDark ? const Color(0xFFDC2626) : const Color(0xFFEF4444),
                child: IconButton(
                  icon: const Icon(
                    Icons.stop_rounded,
                    size: 24,
                    color: Colors.white,
                  ),
                  tooltip: 'Stop output',
                  onPressed: widget.onStop,
                ),
              )
            else
              CircleAvatar(
                radius: 22,
                backgroundColor: widget.enabled
                    ? const Color(0xFF2196F3)
                    : (isDark ? const Color(0xFF01385F) : Colors.grey.shade300),
                child: IconButton(
                  icon: Icon(
                    Icons.send,
                    size: 20,
                    color: widget.enabled ? Colors.white : (isDark ? Colors.white38 : Colors.grey.shade500),
                  ),
                  onPressed: widget.enabled ? _submit : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
