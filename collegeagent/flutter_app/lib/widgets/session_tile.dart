import 'package:flutter/material.dart';
import '../models/session.dart';

/// A session list tile for the sidebar / drawer.
///
/// In [compact] mode (sidebar), shows only the title with a three-dot menu
/// that appears on hover (web/desktop) or is always visible (mobile).
/// The menu provides Pin, Rename, and Delete actions.
class SessionTile extends StatefulWidget {
  final SessionModel session;
  final int unreadCount;
  final bool isStreaming;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onRename;
  final VoidCallback? onTogglePin;

  const SessionTile({
    super.key,
    required this.session,
    required this.onTap,
    this.unreadCount = 0,
    this.isStreaming = false,
    this.selected = false,
    this.compact = false,
    this.onDelete,
    this.onRename,
    this.onTogglePin,
  });

  @override
  State<SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<SessionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final title = widget.session.title ?? 'Chat';

    if (widget.compact) {
      return _buildCompactTile(context, title);
    }
    return _buildFullTile(context, title);
  }

  // ── Compact tile (sidebar / Gemini style) ──────────────────────────────────

  Widget _buildCompactTile(BuildContext context, String title) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0xFF6C63FF).withValues(alpha: 0.1)
                : _hovered
                    ? Colors.grey.shade200
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (widget.session.pinned) ...[
                Icon(Icons.push_pin,
                    size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: widget.selected
                        ? const Color(0xFF6C63FF)
                        : Colors.black87,
                  ),
                ),
              ),
              // Three-dot menu: show on hover or when selected
              AnimatedOpacity(
                opacity: (_hovered || widget.selected) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: _buildMenuButton(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Full tile (non-compact, for drawer on mobile with subtitle) ────────────

  Widget _buildFullTile(BuildContext context, String title) {
    String subtitle;
    if (widget.isStreaming) {
      subtitle = 'Generating...';
    } else if (widget.session.latestAssistant != null &&
        widget.session.latestAssistant!.isNotEmpty) {
      subtitle = widget.session.latestAssistant!;
    } else if (widget.session.lastMessage != null &&
        widget.session.lastMessage!.isNotEmpty) {
      subtitle = widget.session.lastMessage!;
    } else {
      subtitle = 'No messages yet';
    }

    return ListTile(
      selected: widget.selected,
      selectedTileColor: const Color(0xFF6C63FF).withValues(alpha: 0.08),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: widget.selected
                ? const Color(0xFF6C63FF)
                : Colors.grey.shade300,
            child: Icon(
              widget.session.pinned ? Icons.push_pin : Icons.chat,
              color: Colors.white,
              size: 18,
            ),
          ),
          if (widget.unreadCount > 0)
            Positioned(
              right: -4,
              top: -2,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                constraints:
                    const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Text(
                  widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: widget.unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
      subtitle: widget.isStreaming
          ? Row(children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: const Color(0xFF6C63FF)),
              ),
              const SizedBox(width: 6),
              Text(subtitle,
                  style: const TextStyle(
                      color: Color(0xFF6C63FF), fontStyle: FontStyle.italic)),
            ])
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade600)),
      trailing: _buildMenuButton(context),
      onTap: widget.onTap,
    );
  }

  // ── Three-dot popup menu ──────────────────────────────────────────────────

  Widget _buildMenuButton(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_vert,
            size: 18, color: Colors.grey.shade600),
        onSelected: (value) {
          switch (value) {
            case 'pin':
              widget.onTogglePin?.call();
              break;
            case 'rename':
              _showRenameDialog(context);
              break;
            case 'delete':
              _confirmDelete(context);
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'pin',
            child: Row(children: [
              Icon(
                widget.session.pinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(widget.session.pinned ? 'Unpin' : 'Pin'),
            ]),
          ),
          PopupMenuItem(
            value: 'rename',
            child: Row(children: [
              const Icon(Icons.edit_outlined, size: 18),
              const SizedBox(width: 10),
              const Text('Rename'),
            ]),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              const Icon(Icons.delete_outline,
                  size: 18, color: Colors.red),
              const SizedBox(width: 10),
              const Text('Delete',
                  style: TextStyle(color: Colors.red)),
            ]),
          ),
        ],
      ),
    );
  }

  // ── Rename dialog ─────────────────────────────────────────────────────────

  void _showRenameDialog(BuildContext context) {
    final controller =
        TextEditingController(text: widget.session.title ?? '');
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter new name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              widget.onRename?.call(value.trim());
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                widget.onRename?.call(value);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  // ── Delete confirmation ───────────────────────────────────────────────────

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
            'Delete "${widget.session.title ?? 'Chat'}" and all its messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete?.call();
            },
            child:
                const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
