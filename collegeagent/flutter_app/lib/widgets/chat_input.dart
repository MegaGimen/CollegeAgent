import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatInput extends StatefulWidget {
  final bool enabled;
  final ValueChanged<String> onSend;
  final TextEditingController? controller;
  final VoidCallback? onFork;

  const ChatInput({
    super.key,
    required this.onSend,
    this.enabled = true,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
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
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: TextStyle(color: Colors.grey.shade400),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade100,
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
                backgroundColor: Colors.grey.shade200,
                child: IconButton(
                  icon: const Icon(Icons.fork_right, size: 20, color: Colors.black87),
                  tooltip: 'Fork as Subagent',
                  onPressed: widget.onFork,
                ),
              ),
              const SizedBox(width: 8),
            ],
            CircleAvatar(
              radius: 22,
              backgroundColor: widget.enabled
                  ? const Color(0xFF2196F3)
                  : Colors.grey.shade300,
              child: IconButton(
                icon: const Icon(Icons.send, size: 20, color: Colors.white),
                onPressed: widget.enabled ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
