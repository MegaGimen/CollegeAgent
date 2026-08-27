import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/message.dart';

class ToolCallCard extends StatefulWidget {
  final ToolCallInfo toolCall;
  const ToolCallCard({super.key, required this.toolCall});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  String _summarizeArgs(Map<String, dynamic> args) {
    final entries = args.entries.toList();
    if (entries.isEmpty) return '';
    final parts = entries.take(2).map((e) {
      final val = e.value.toString();
      return '${e.key}: ${val.length > 30 ? '${val.substring(0, 30)}...' : val}';
    });
    final summary = parts.join(', ');
    if (entries.length > 2) return '$summary, ...';
    return summary;
  }

  String _formatJson(Map<String, dynamic> obj) {
    try {
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return obj.toString();
    }
  }

  String _formatValue(dynamic value, {int maxLen = 20}) {
    if (value == null) return 'null';
    if (value is Map<String, dynamic>) {
      final parts = <String>[];
      value.forEach((k, v) {
        String vStr = v?.toString().replaceAll('\n', ' ') ?? 'null';
        if (vStr.length > maxLen) vStr = '${vStr.substring(0, maxLen)}...';
        parts.add('$k: $vStr');
      });
      return '{${parts.join(', ')}}';
    }
    if (value is List) {
      if (value.isEmpty) return '[]';
      final formattedItems = value.map((item) {
        if (item is Map<String, dynamic>) {
          final itemParts = <String>[];
          item.forEach((k, v) {
            String vStr = v?.toString().replaceAll('\n', ' ') ?? 'null';
            if (vStr.length > maxLen) vStr = '${vStr.substring(0, maxLen)}...';
            itemParts.add('$k: $vStr');
          });
          return '{${itemParts.join(', ')}}';
        }
        String iStr = item.toString().replaceAll('\n', ' ');
        if (iStr.length > maxLen) iStr = '${iStr.substring(0, maxLen)}...';
        return iStr;
      }).join(',\n    ');
      return '[\n    $formattedItems\n  ]';
    }
    String valStr = value.toString().replaceAll('\n', ' ');
    if (valStr.length > maxLen) {
      valStr = '${valStr.substring(0, maxLen)}...';
    }
    return valStr;
  }

  String _formatResult(String result) {
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map<String, dynamic>) {
        final buf = StringBuffer();
        decoded.forEach((key, value) {
          buf.writeln('$key: ${_formatValue(value)}');
        });
        return buf.toString().trimRight();
      } else if (decoded is List) {
        final buf = StringBuffer();
        buf.writeln('[List of ${decoded.length} items]:');
        for (var i = 0; i < decoded.length; i++) {
          buf.writeln('  [$i]: ${_formatValue(decoded[i])}');
        }
        return buf.toString().trimRight();
      }
    } catch (_) {}

    String rawStr = result.replaceAll('\n', ' ');
    if (rawStr.length > 500) {
      rawStr = '${rawStr.substring(0, 500)}... (truncated)';
    }
    return rawStr;
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.toolCall;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE7F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD1C4E9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — always visible
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  if (tc.isLoading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    const Icon(Icons.check_circle,
                        size: 14, color: Color(0xFF6C63FF)),
                  const SizedBox(width: 6),
                  Text(
                    tc.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A148C),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _summarizeArgs(tc.args),
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (tc.graphNodes.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${tc.graphNodes.length} nodes',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey.shade500,
                  ),
                ],
              ),
            ),
          ),
          // Expanded details
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Knowledge graph visualization
                  if (tc.graphNodes.isNotEmpty) ...[
                    _buildGraphVisualization(tc.graphNodes),
                    const SizedBox(height: 8),
                  ],
                  // Arguments
                  const Text('Arguments',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF7B1FA2))),
                  const SizedBox(height: 2),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _formatJson(tc.args),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                  if (tc.result != null) ...[
                    const SizedBox(height: 6),
                    const Text('Result',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF7B1FA2))),
                    const SizedBox(height: 2),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        _formatResult(tc.result!),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build a visual knowledge graph showing crawled nodes and their connections.
  Widget _buildGraphVisualization(List<GraphNode> nodes) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF6C63FF).withValues(alpha: 0.08),
            const Color(0xFFB39DDB).withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD1C4E9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore,
                  size: 14, color: Color(0xFF6C63FF)),
              const SizedBox(width: 4),
              const Text(
                'Knowledge Graph Crawl',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF4A148C),
                ),
              ),
              const Spacer(),
              Text(
                '${nodes.length} page${nodes.length == 1 ? '' : 's'} visited',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...nodes.asMap().entries.map((entry) {
            final i = entry.key;
            final node = entry.value;
            return _buildGraphNodeWidget(node, i, nodes.length);
          }),
        ],
      ),
    );
  }

  Widget _buildGraphNodeWidget(GraphNode node, int index, int total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Node card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFD1C4E9)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.08),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step number
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color(0xFF6C63FF),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Node info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF311B92),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (node.sourceUrl != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        node.sourceUrl!,
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.grey.shade500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    // Outbound links
                    if (node.outboundLinks.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: node.outboundLinks.take(5).map((link) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE7F6),
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: const Color(0xFFD1C4E9)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  link.nodeId != null
                                      ? Icons.link
                                      : Icons.link_off,
                                  size: 9,
                                  color: link.nodeId != null
                                      ? const Color(0xFF6C63FF)
                                      : Colors.grey.shade400,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  link.title.length > 20
                                      ? '${link.title.substring(0, 20)}...'
                                      : link.title,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: link.nodeId != null
                                        ? const Color(0xFF4A148C)
                                        : Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                      if (node.outboundLinks.length > 5)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '+${node.outboundLinks.length - 5} more links',
                            style: TextStyle(
                                fontSize: 9, color: Colors.grey.shade500),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Connector line between nodes
        if (index < total - 1)
          Padding(
            padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
            child: Container(
              width: 2,
              height: 12,
              color: const Color(0xFFD1C4E9),
            ),
          ),
      ],
    );
  }
}
