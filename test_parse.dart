import 'dart:convert';
import 'dart:io';

class GraphLink {
  final String title;
  final String? nodeId;

  GraphLink({required this.title, this.nodeId});

  factory GraphLink.fromJson(Map<String, dynamic> json) {
    return GraphLink(
      title: json['title'] as String? ?? '',
      nodeId: json['nodeId'] as String?,
    );
  }
}

class GraphNode {
  final String nodeId;
  final String title;
  final String? sourceUrl;
  final List<GraphLink> outboundLinks;

  GraphNode({
    required this.nodeId,
    required this.title,
    this.sourceUrl,
    this.outboundLinks = const [],
  });

  factory GraphNode.fromJson(Map<String, dynamic> json) {
    return GraphNode(
      nodeId: json['nodeId'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      sourceUrl: json['sourceUrl'] as String?,
      outboundLinks: (json['outboundLinks'] as List<dynamic>?)
              ?.map((e) => GraphLink.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

void main() {
  final result = File('test_payload.txt').readAsStringSync();
  List<GraphNode> graphNodes = [];
  
  try {
    final parsed = jsonDecode(result);
    if (parsed is Map<String, dynamic>) {
      if (parsed.containsKey('neighbors') && parsed['neighbors'] is List) {
        final nodes = <GraphNode>[];
        if (parsed.containsKey('title')) {
          nodes.add(GraphNode.fromJson(parsed));
        }
        nodes.addAll((parsed['neighbors'] as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => GraphNode.fromJson(e)));
        graphNodes = nodes;
      }
    }
    print("Parsed successfully. Nodes count: " + graphNodes.length.toString());
  } catch (e) {
    print("Error: " + e.toString());
  }
}
