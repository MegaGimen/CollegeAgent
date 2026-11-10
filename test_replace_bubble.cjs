const fs = require('fs');
const path = 'collegeagent/flutter_app/lib/widgets/message_bubble.dart';
let code = fs.readFileSync(path, 'utf8');

const regex = /\/\/ Render body based on segments[\s\S]*?else\s*_buildMarkdownBody\(context, rawText\),/g;
code = code.replace(regex, `if (isUser)
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
                      ],`);

// Remove _buildSegmentedContent
code = code.replace(/List<Widget> _buildSegmentedContent[\s\S]*?return widgets;\n  }\n/g, '');

const thinkingCollapsibleCode = `
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
      statusText = "calling tool: \${activeTool.name}...";
      isActive = true;
    } else if (widget.message.text.isEmpty) {
      statusText = "thinking...";
      isActive = true;
    } else {
      statusText = "Tool calls & thinking (\${widget.message.toolCalls.length})";
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600;

    final expandedWidgets = <Widget>[];
    for (final segment in widget.message.segments) {
      if (segment.type == SegmentType.text) {
        final segRaw = segment.text.replaceAll('\\\\n', '\\n');
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
              color: isDark ? Colors.black12 : Colors.black.withOpacity(0.05),
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
`;

code += thinkingCollapsibleCode;
fs.writeFileSync(path, code);
console.log("Replaced message_bubble.dart successfully");
