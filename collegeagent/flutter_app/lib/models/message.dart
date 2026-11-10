import 'dart:convert';

/// Represents a single node fetched from the knowledge graph.
class GraphNode {
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
}

/// Represents an outbound link from a knowledge graph node.
class GraphLink {
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
}

/// Represents a single tool call made by the AI during a response.
class ToolCallInfo {
  final String name;
  final Map<String, dynamic> args;
  String? result;
  bool isLoading;

  /// Parsed knowledge graph nodes (for search/read tools from networker).
  List<GraphNode> graphNodes;

  ToolCallInfo({
    required this.name,
    required this.args,
    this.result,
    this.isLoading = true,
    List<GraphNode>? graphNodes,
  }) : graphNodes = graphNodes ?? [];

  /// Try to parse graph nodes from the tool result JSON.
  void tryParseGraphNodes() {
    if (result == null || result!.isEmpty) return;
    if (name != 'search' && name != 'read' && name != 'expand' && name != 'get_page_content') return;
    try {
      final parsed = jsonDecode(result!);
      if (parsed is Map<String, dynamic>) {
        // search result: has "results" array
        if (parsed.containsKey('results') && parsed['results'] is List) {
          graphNodes = (parsed['results'] as List)
              .whereType<Map<String, dynamic>>()
              .map((e) => GraphNode.fromJson(e))
              .toList();
        }
        // expand/get_page_content result: has "neighbors" array
        else if (parsed.containsKey('neighbors') && parsed['neighbors'] is List) {
          final nodes = <GraphNode>[];
          if (parsed.containsKey('title')) {
            nodes.add(GraphNode.fromJson(parsed));
          }
          nodes.addAll((parsed['neighbors'] as List)
              .whereType<Map<String, dynamic>>()
              .map((e) => GraphNode.fromJson(e)));
          graphNodes = nodes;
        }
        // read or expand(url) result: single node
        else if (parsed.containsKey('title') && (parsed.containsKey('nodeId') || parsed.containsKey('sourceUrl'))) {
          graphNodes = [GraphNode.fromJson(parsed)];
        }
      }
    } catch (e) {
      print('Failed to parse graph nodes for tool $name: $e');
      // not JSON or unexpected format — ignore
    }
  }
}

/// A segment in the streaming response — either a text block or a tool call.
/// Used to display the interleaved "text → tool → text → tool" flow.
enum SegmentType { text, tool }

class StreamSegment {
  final SegmentType type;

  /// Text content (only for type == text).
  String text;

  /// Index into MessageModel.toolCalls (only for type == tool).
  int toolCallIndex;

  StreamSegment.text(this.text) : type = SegmentType.text, toolCallIndex = -1;
  StreamSegment.tool(this.toolCallIndex)
      : type = SegmentType.tool,
        text = '';
}

/// A citation referencing a source from the knowledge graph.
class Citation {
  final int index;         // Sequential index in the text
  final String title;      // Source node title
  final int? sourceId;     // Numeric source ID
  final String? nodeId;    // Graph node ID (null if not found in graph)
  final String? snippet;   // Text snippet from the source
  final String? sourceUrl; // Web URL (for web_search sources or graph node)
  final String? crawledAt; // ISO timestamp when the page was crawled
  String? fullMarkdown;    // Full markdown (loaded on demand)
  bool isLoading;

  Citation({
    required this.index,
    required this.title,
    this.sourceId,
    this.nodeId,
    this.snippet,
    this.sourceUrl,
    this.crawledAt,
    this.fullMarkdown,
    this.isLoading = false,
  });

  factory Citation.fromJson(Map<String, dynamic> json) {
    return Citation(
      index: json['index'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      sourceId: json['sourceId'] as int?,
      nodeId: json['nodeId'] as String?,
      snippet: json['snippet'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      crawledAt: json['crawledAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'index': index,
    'title': title,
    'sourceId': sourceId,
    'nodeId': nodeId,
    'snippet': snippet,
    'sourceUrl': sourceUrl,
    'crawledAt': crawledAt,
  };
}

class MessageModel {
  final String id;
  final String sessionId;
  final String role; // 'user' | 'assistant'
  final String text;
  final String timestamp;
  final int? seq;

  /// Tool calls attached to this message (only for assistant messages during streaming).
  List<ToolCallInfo> toolCalls;

  /// Ordered segments for interleaved text + tool display.
  List<StreamSegment> segments;

  /// Citations parsed from [Source: title] patterns.
  List<Citation> citations;

  MessageModel({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.timestamp,
    this.seq,
    List<ToolCallInfo>? toolCalls,
    List<StreamSegment>? segments,
    List<Citation>? citations,
  })  : toolCalls = toolCalls ?? [],
        segments = segments ?? [],
        citations = citations ?? [];

  factory MessageModel.fromJson(Map<String, dynamic> json, String sessionId) {
    final toolCalls = <ToolCallInfo>[];
    final segments = <StreamSegment>[];

    // Parse persisted tool calls and citations from meta
    // meta can be a Map (from server JSON) or a JSON string (from SQLite)
    Map<String, dynamic>? meta;
    final rawMeta = json['meta'];
    if (rawMeta is Map<String, dynamic>) {
      meta = rawMeta;
    } else if (rawMeta is String && rawMeta.isNotEmpty) {
      try {
        meta = jsonDecode(rawMeta) as Map<String, dynamic>;
      } catch (_) {}
    }

    // Parse citations from meta
    final citations = <Citation>[];
    if (meta != null && meta['citations'] is List) {
      for (final c in meta['citations'] as List) {
        if (c is Map<String, dynamic>) {
          citations.add(Citation.fromJson(c));
        }
      }
    }

    if (meta != null && meta['toolCalls'] is List) {
      final savedTools = meta['toolCalls'] as List;
      for (final tc in savedTools) {
        if (tc is! Map<String, dynamic>) continue;

        // Add intermediate text segment (AI reasoning before this tool call)
        final interText = tc['intermediateText'] as String?;
        if (interText != null && interText.trim().isNotEmpty) {
          segments.add(StreamSegment.text(interText));
        }

        // Create tool call info
        final toolInfo = ToolCallInfo(
          name: tc['name'] as String? ?? '',
          args: (tc['args'] as Map<String, dynamic>?) ?? {},
          result: tc['result'] as String?,
          isLoading: false,
        );
        toolInfo.tryParseGraphNodes();
        toolCalls.add(toolInfo);
        segments.add(StreamSegment.tool(toolCalls.length - 1));
      }
    }

    return MessageModel(
      id: json['id'] as String,
      sessionId:
          (json['sessionId'] ?? json['session_id'] ?? sessionId) as String,
      role: json['role'] as String,
      text: json['text'] as String? ?? '',
      timestamp: json['timestamp'] as String,
      seq: json['seq'] as int?,
      toolCalls: toolCalls,
      segments: segments,
      citations: citations,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'role': role,
        'text': text,
        'timestamp': timestamp,
        'seq': seq,
      };

  Map<String, dynamic> toDbMap() {
    final map = <String, dynamic>{
      'id': id,
      'session_id': sessionId,
      'role': role,
      'text': text,
      'timestamp': timestamp,
      'seq': seq,
    };
    // Persist tool call and citation meta as JSON string for SQLite
    final metaMap = <String, dynamic>{};
    if (toolCalls.isNotEmpty) {
      final metaToolCalls = toolCalls.map((tc) => {
        'name': tc.name,
        'args': tc.args,
        'result': tc.result,
        'intermediateText': _findIntermediateText(tc),
      }).toList();
      metaMap['toolCalls'] = metaToolCalls;
    }
    if (citations.isNotEmpty) {
      metaMap['citations'] = citations.map((c) => c.toJson()).toList();
    }
    if (metaMap.isNotEmpty) {
      map['meta'] = jsonEncode(metaMap);
    }
    return map;
  }

  /// Find the intermediate text segment that precedes a given tool call.
  String? _findIntermediateText(ToolCallInfo tc) {
    final idx = toolCalls.indexOf(tc);
    if (idx < 0) return null;
    // Look for the text segment right before this tool's segment
    for (final seg in segments) {
      if (seg.type == SegmentType.tool && seg.toolCallIndex == idx) {
        // Found the tool segment — check if the previous segment is text
        final segIdx = segments.indexOf(seg);
        if (segIdx > 0 && segments[segIdx - 1].type == SegmentType.text) {
          return segments[segIdx - 1].text;
        }
        break;
      }
    }
    return null;
  }
}
