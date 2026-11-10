const fs = require('fs');
const file = '/home/collegeagent/collegeagent/flutter_app/lib/models/message.dart';
let content = fs.readFileSync(file, 'utf8');

const correctGraphNode = `class GraphNode {
  final int? sourceId;
  final String nodeId;
  final String title;
  final String? sourceUrl;
  final List<GraphLink> outboundLinks;

  GraphNode({
    this.sourceId,
    required this.nodeId,
    required this.title,
    this.sourceUrl,
    this.outboundLinks = const [],
  });

  factory GraphNode.fromJson(Map<String, dynamic> json) {
    return GraphNode(
      sourceId: json['sourceId'] as int?,
      nodeId: json['nodeId'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      sourceUrl: json['sourceUrl'] as String?,
      outboundLinks: (json['outboundLinks'] as List<dynamic>?)
              ?.map((e) => GraphLink.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}`;

const correctGraphLink = `class GraphLink {
  final int? sourceId;
  final String title;
  final String? nodeId;

  GraphLink({required this.title, this.nodeId, this.sourceId});

  factory GraphLink.fromJson(Map<String, dynamic> json) {
    return GraphLink(
      title: json['title'] as String? ?? '',
      sourceId: json['sourceId'] as int?,
      nodeId: json['nodeId'] as String?,
    );
  }
}`;

content = content.replace(/class GraphNode \{[\s\S]*?\}\n\}/, correctGraphNode);
content = content.replace(/class GraphLink \{[\s\S]*?\}\n\}/, correctGraphLink);

fs.writeFileSync(file, content);
console.log('Fixed GraphNode and GraphLink');
