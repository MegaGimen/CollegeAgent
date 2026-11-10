import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// A node in the 3-hop knowledge graph visualization.
class _KgNode {
  final String nodeId;
  final String title;
  final String? sourceUrl;
  final String? crawledAt;
  final List<_KgLink> outboundLinks;
  final int hop; // 0 = source, 1, 2, 3
  String? _cachedContent;

  _KgNode({
    required this.nodeId,
    required this.title,
    this.sourceUrl,
    this.crawledAt,
    this.outboundLinks = const [],
    this.hop = 0,
  });

  factory _KgNode.fromJson(Map<String, dynamic> json, int hop) {
    final node = _KgNode(
      nodeId: json['nodeId'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      sourceUrl: json['sourceUrl'] as String?,
      crawledAt: json['crawledAt'] as String?,
      outboundLinks: (json['outboundLinks'] as List<dynamic>?)
              ?.map((e) => _KgLink.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      hop: hop,
    );
    if (json['content'] != null && (json['content'] as String).isNotEmpty) {
      String content = json['content'] as String;
      final contentIdx = content.indexOf('## Content');
      if (contentIdx != -1) {
        content = content.substring(contentIdx + '## Content'.length).trim();
      }
      content = content
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\|'), ''))
          .join('\n');
      node._cachedContent = content;
    }
    return node;
  }
}

class _KgLink {
  final String title;
  final String? nodeId;

  _KgLink({required this.title, this.nodeId});

  factory _KgLink.fromJson(Map<String, dynamic> json) {
    return _KgLink(
      title: json['title'] as String? ?? '',
      nodeId: json['nodeId'] as String?,
    );
  }
}

/// An edge in the graph for rendering.
class _GraphEdge {
  final int fromIdx;
  final int toIdx;
  _GraphEdge(this.fromIdx, this.toIdx);
}

/// Full-screen 3-hop knowledge graph explorer.
class KnowledgeGraphScreen extends StatefulWidget {
  final String nodeId;
  final String title;

  const KnowledgeGraphScreen({
    super.key,
    required this.nodeId,
    required this.title,
  });

  @override
  State<KnowledgeGraphScreen> createState() => _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends State<KnowledgeGraphScreen> {
  static const String _baseUrl = 'https://llinker.com/collegeagent-api';
  final http.Client _client = http.Client();

  final List<_KgNode> _nodes = [];
  final List<_GraphEdge> _edges = [];
  final Map<String, int> _nodeIdToIdx = {};
  bool _loading = true;
  String? _error;

  // Positions for force-directed layout
  final List<Offset> _positions = [];

  // Manual transform (scale + offset) — replaces InteractiveViewer
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  double _startScale = 1.0;
  Offset _startOffset = Offset.zero;
  Offset _startFocalPoint = Offset.zero;
  Size? _lastViewport;

  @override
  void initState() {
    super.initState();
    _buildGraph();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _buildGraph() async {
    try {
      // Hop 0: fetch source node
      final sourceNode = await _fetchNode(widget.nodeId, 0);
      if (sourceNode == null) {
        setState(() {
          _error = '无法加载源节点';
          _loading = false;
        });
        return;
      }
      _addNode(sourceNode, widget.nodeId);

      // BFS for 2 hops
      final queue = <(String nodeId, int hop)>[];
      for (final link in sourceNode.outboundLinks) {
        if (link.nodeId != null && link.nodeId!.isNotEmpty) {
          queue.add((link.nodeId!, 1));
        }
      }

      final visited = <String>{widget.nodeId, sourceNode.nodeId};
      int head = 0;

      while (head < queue.length) {
        final (nid, hop) = queue[head++];
        if (visited.contains(nid) || hop > 2) continue;
        visited.add(nid);

        final node = await _fetchNode(nid, hop);
        if (node == null) continue;

        _addNode(node, nid);
        final toIdx = _nodes.length - 1;

        // Add edges from all previously-known nodes that link to this one
        for (final existingNode in _nodes) {
          if (existingNode.outboundLinks.any((l) => l.nodeId == nid || l.nodeId == node.nodeId)) {
            final existingIdx = _nodeIdToIdx[existingNode.nodeId];
            if (existingIdx != null) {
              _edges.add(_GraphEdge(existingIdx, toIdx));
            }
          }
        }

        if (hop < 2) {
          for (final link in node.outboundLinks) {
            if (link.nodeId != null &&
                link.nodeId!.isNotEmpty &&
                !visited.contains(link.nodeId)) {
              queue.add((link.nodeId!, hop + 1));
            }
          }
        }
      }

      // Add any remaining edges for nodes already in the graph
      for (int i = 0; i < _nodes.length; i++) {
        for (final link in _nodes[i].outboundLinks) {
          if (link.nodeId != null) {
            final targetIdx = _nodeIdToIdx[link.nodeId!];
            if (targetIdx != null &&
                !_edges.any((e) => e.fromIdx == i && e.toIdx == targetIdx)) {
              _edges.add(_GraphEdge(i, targetIdx));
            }
          }
        }
      }

      _runForceLayout();
      setState(() {
        _loading = false;
      });
      // Apply fit transform after first layout
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lastViewport != null) {
          _applyFitTransform(_lastViewport!);
        }
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<_KgNode?> _fetchNode(String nodeId, int hop) async {
    if (nodeId.isEmpty) return null;
    if (_nodeIdToIdx.containsKey(nodeId)) return null; // already loaded
    try {
      final res = await _client.get(
        Uri.parse('$_baseUrl/api/graph/node/${Uri.encodeComponent(nodeId)}'),
      );
      if (res.statusCode == 200) {
        return _KgNode.fromJson(
            jsonDecode(res.body) as Map<String, dynamic>, hop);
      }
    } catch (_) {}
    return null;
  }

  void _addNode(_KgNode node, [String? requestedId]) {
    final idx = _nodes.length;
    _nodes.add(node);
    if (node.nodeId.isNotEmpty) {
      _nodeIdToIdx[node.nodeId] = idx;
    }
    if (requestedId != null && requestedId.isNotEmpty && requestedId != node.nodeId) {
      _nodeIdToIdx[requestedId] = idx;
    }
  }

  /// Simple force-directed layout in a bounded area.
  void _runForceLayout() {
    final rng = math.Random(42);
    final w = 1400.0;
    final h = 1400.0;

    // Initial positions: place source at center, others randomly by hop ring
    for (int i = 0; i < _nodes.length; i++) {
      final hop = _nodes[i].hop;
      if (hop == 0) {
        _positions.add(Offset(w / 2, h / 2));
      } else {
        final angle = rng.nextDouble() * 2 * math.pi;
        final radius = 120.0 + hop * 160.0 + rng.nextDouble() * 60;
        _positions.add(Offset(
          w / 2 + radius * math.cos(angle),
          h / 2 + radius * math.sin(angle),
        ));
      }
    }

    // Run a few iterations of force-directed simulation
    const iterations = 120;
    const repulsion = 15000.0;
    const attraction = 0.004;
    const damping = 0.9;

    final velocities = List.generate(_nodes.length, (_) => Offset.zero);

    for (int iter = 0; iter < iterations; iter++) {
      final forces = List.generate(_nodes.length, (_) => Offset.zero);

      // Repulsion between all pairs
      for (int i = 0; i < _nodes.length; i++) {
        for (int j = i + 1; j < _nodes.length; j++) {
          final dx = _positions[i].dx - _positions[j].dx;
          final dy = _positions[i].dy - _positions[j].dy;
          final distSq = dx * dx + dy * dy + 1;
          final force = repulsion / distSq;
          final dist = math.sqrt(distSq);
          forces[i] += Offset(force * dx / dist, force * dy / dist);
          forces[j] -= Offset(force * dx / dist, force * dy / dist);
        }
      }

      // Attraction along edges
      for (final edge in _edges) {
        final dx = _positions[edge.toIdx].dx - _positions[edge.fromIdx].dx;
        final dy = _positions[edge.toIdx].dy - _positions[edge.fromIdx].dy;
        final dist = math.sqrt(dx * dx + dy * dy) + 0.1;
        final idealDist = 180.0 + (_nodes[edge.toIdx].hop) * 40.0;
        final force = attraction * (dist - idealDist);
        forces[edge.fromIdx] += Offset(force * dx / dist, force * dy / dist);
        forces[edge.toIdx] -= Offset(force * dx / dist, force * dy / dist);
      }

      // Update velocities and positions
      for (int i = 0; i < _nodes.length; i++) {
        velocities[i] = (velocities[i] + forces[i]) * damping;
        _positions[i] = Offset(
          (_positions[i].dx + velocities[i].dx).clamp(60.0, w - 60),
          (_positions[i].dy + velocities[i].dy).clamp(60.0, h - 60),
        );
      }
    }
  }

  /// Compute and apply a transform that fits all nodes in the viewport.
  void _applyFitTransform(Size viewport) {
    if (_positions.isEmpty) return;

    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in _positions) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    final graphW = maxX - minX + 160;
    final graphH = maxY - minY + 160;
    final graphCx = (minX + maxX) / 2;
    final graphCy = (minY + maxY) / 2;

    final scaleX = viewport.width * 0.85 / graphW;
    final scaleY = viewport.height * 0.85 / graphH;
    final newScale = math.min(scaleX, scaleY).clamp(0.05, 5.0);

    setState(() {
      _scale = newScale;
      _offset = Offset(
        viewport.width / 2 - graphCx * newScale,
        viewport.height / 2 - graphCy * newScale,
      );
    });
  }

  void _resetView(Size viewport) {
    _applyFitTransform(viewport);
  }

  void _zoomIn() {
    setState(() {
      final newScale = (_scale * 1.25).clamp(0.05, 5.0);
      if (_lastViewport != null) {
        final focal = Offset(_lastViewport!.width / 2, _lastViewport!.height / 2);
        _offset = focal - (focal - _offset) * (newScale / _scale);
      }
      _scale = newScale;
    });
  }

  void _zoomOut() {
    setState(() {
      final newScale = (_scale / 1.25).clamp(0.05, 5.0);
      if (_lastViewport != null) {
        final focal = Offset(_lastViewport!.width / 2, _lastViewport!.height / 2);
        _offset = focal - (focal - _offset) * (newScale / _scale);
      }
      _scale = newScale;
    });
  }

  /// Convert screen position to graph position.
  Offset _screenToGraph(Offset screen) {
    return (screen - _offset) / _scale;
  }

  Color _hopColor(int hop) {
    switch (hop) {
      case 0:
        return const Color(0xFF0C132C);
      case 1:
        return const Color(0xFF2196F3);
      case 2:
        return const Color(0xFF4CAF50);
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '页面跳转关系',
          style: const TextStyle(fontSize: 16),
        ),
        backgroundColor: const Color(0xFF0C132C),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '${_nodes.length} 个节点',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('正在拉取知识图谱...',
                        style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : _error != null
                ? Center(child: Text('错误: $_error'))
                : _nodes.isEmpty
                    ? const Center(child: Text('没有关联的知识节点'))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final viewport = Size(
                              constraints.maxWidth, constraints.maxHeight);
                          _lastViewport = viewport;
                          return ClipRect(
                            child: Listener(
                              onPointerSignal: (event) {
                                if (event is PointerScrollEvent) {
                                  setState(() {
                                    final zoomFactor = event.scrollDelta.dy > 0 ? 0.85 : 1.15;
                                    final newScale = (_scale * zoomFactor).clamp(0.05, 5.0);
                                    final focal = event.localPosition;
                                    _offset = focal - (focal - _offset) * (newScale / _scale);
                                    _scale = newScale;
                                  });
                                }
                              },
                              child: GestureDetector(
                                onScaleStart: (details) {
                                  _startScale = _scale;
                                  _startOffset = _offset;
                                  _startFocalPoint = details.focalPoint;
                                },
                                onScaleUpdate: (details) {
                                  setState(() {
                                    _scale = (_startScale * details.scale).clamp(0.05, 5.0);
                                    _offset = _startOffset + (details.focalPoint - _startFocalPoint);
                                  });
                                },
                                onTapUp: (details) =>
                                    _handleTap(details.localPosition),
                                behavior: HitTestBehavior.opaque,
                                child: Stack(
                                  children: [
                                    // Graph canvas
                                    Positioned.fill(
                                      child: Transform(
                                        transform: Matrix4.identity()
                                          ..translate(
                                              _offset.dx, _offset.dy)
                                          ..scale(_scale),
                                        transformHitTests: true,
                                        child: Container(
                                          width: 1400,
                                          height: 1400,
                                          color: Colors.transparent,
                                          child: CustomPaint(
                                            painter: _GraphPainter(
                                              nodes: _nodes,
                                              positions: _positions,
                                              edges: _edges,
                                              hopColor: _hopColor,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Zoom controls Column (Zoom In, Zoom Out, Reset)
                                    Positioned(
                                      right: 16,
                                      bottom: 16,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          FloatingActionButton.small(
                                            heroTag: 'graph_zoom_in',
                                            onPressed: _zoomIn,
                                            backgroundColor: const Color(0xFF0C132C),
                                            foregroundColor: Colors.white,
                                            tooltip: '放大',
                                            child: const Icon(Icons.add, size: 20),
                                          ),
                                          const SizedBox(height: 8),
                                          FloatingActionButton.small(
                                            heroTag: 'graph_zoom_out',
                                            onPressed: _zoomOut,
                                            backgroundColor: const Color(0xFF0C132C),
                                            foregroundColor: Colors.white,
                                            tooltip: '缩小',
                                            child: const Icon(Icons.remove, size: 20),
                                          ),
                                          const SizedBox(height: 8),
                                          FloatingActionButton.small(
                                            heroTag: 'graph_reset',
                                            onPressed: () =>
                                                _resetView(viewport),
                                            backgroundColor:
                                                const Color(0xFF4A148C),
                                            foregroundColor: Colors.white,
                                            tooltip: '重置主视图',
                                            child: const Icon(
                                                Icons.center_focus_strong,
                                                size: 20),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }

  void _handleTap(Offset screenPos) {
    // Convert screen tap to graph coordinates
    final graphPos = _screenToGraph(screenPos);
    // Find nearest node within radius (in graph coordinates)
    int? nearest;
    double minDist = 35.0 / _scale; // adjust hit radius for zoom level
    for (int i = 0; i < _positions.length; i++) {
      final dist = (graphPos - _positions[i]).distance;
      if (dist < minDist) {
        minDist = dist;
        nearest = i;
      }
    }
    if (nearest != null) {
      _openNodeContent(_nodes[nearest]);
    }
  }

  Future<void> _openNodeContent(_KgNode node) async {
    // Show a loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    String content;
    try {
      if (node._cachedContent != null) {
        content = node._cachedContent!;
      } else {
        final res = await _client.get(
          Uri.parse('$_baseUrl/api/graph/node/${Uri.encodeComponent(node.nodeId)}'),
        );
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          content = data['content'] as String? ?? '(无内容)';
          // Strip metadata
          final contentIdx = content.indexOf('## Content');
          if (contentIdx != -1) {
            content =
                content.substring(contentIdx + '## Content'.length).trim();
          }
          // Strip line numbers
          content = content
              .split('\n')
              .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\|'), ''))
              .join('\n');
          node._cachedContent = content;
        } else {
          content = '(加载失败: ${res.statusCode})';
        }
      }
    } catch (e) {
      content = '(加载失败: $e)';
    }

    if (!mounted) return;
    Navigator.pop(context); // dismiss loading dialog

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _NodeContentScreen(
          title: node.title,
          content: content,
          sourceUrl: node.sourceUrl,
          crawledAt: node.crawledAt,
          hop: node.hop,
          hopColor: _hopColor(node.hop),
        ),
      ),
    );
  }
}

/// Custom painter for the knowledge graph.
class _GraphPainter extends CustomPainter {
  final List<_KgNode> nodes;
  final List<Offset> positions;
  final List<_GraphEdge> edges;
  final Color Function(int hop) hopColor;

  _GraphPainter({
    required this.nodes,
    required this.positions,
    required this.edges,
    required this.hopColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.length != nodes.length) return;

    // Draw edges
    final edgePaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.35)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final edge in edges) {
      if (edge.fromIdx < positions.length && edge.toIdx < positions.length) {
        final from = positions[edge.fromIdx];
        final to = positions[edge.toIdx];

        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
        canvas.drawPath(path, edgePaint);

        // Arrow head
        final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
        const arrowLen = 8.0;
        const arrowAngle = 0.4;
        final tip = Offset(
          to.dx - 20 * math.cos(angle),
          to.dy - 20 * math.sin(angle),
        );
        final arrowPaint = Paint()
          ..color = Colors.grey.withValues(alpha: 0.5)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          tip,
          Offset(
            tip.dx - arrowLen * math.cos(angle - arrowAngle),
            tip.dy - arrowLen * math.sin(angle - arrowAngle),
          ),
          arrowPaint,
        );
        canvas.drawLine(
          tip,
          Offset(
            tip.dx - arrowLen * math.cos(angle + arrowAngle),
            tip.dy - arrowLen * math.sin(angle + arrowAngle),
          ),
          arrowPaint,
        );
      }
    }

    // Draw nodes
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final pos = positions[i];
      final color = hopColor(node.hop);

      // Circle
      final radius = node.hop == 0 ? 22.0 : 16.0;
      final circlePaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, radius, circlePaint);

      // Border
      final borderPaint = Paint()
        ..color = color.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(pos, radius + 2, borderPaint);

      // Hop number inside circle
      final hopPainter = TextPainter(
        text: TextSpan(
          text: '${node.hop}',
          style: TextStyle(
            color: Colors.white,
            fontSize: node.hop == 0 ? 14 : 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      hopPainter.paint(
        canvas,
        Offset(
          pos.dx - hopPainter.width / 2,
          pos.dy - hopPainter.height / 2,
        ),
      );

      // Title label below
      final displayTitle = node.title.length > 16
          ? '${node.title.substring(0, 16)}...'
          : node.title;
      final labelPainter = TextPainter(
        text: TextSpan(
          text: displayTitle,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 100);
      labelPainter.paint(
        canvas,
        Offset(
          pos.dx - labelPainter.width / 2,
          pos.dy + radius + 4,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Screen to display a single node's markdown content.
class _NodeContentScreen extends StatelessWidget {
  final String title;
  final String content;
  final String? sourceUrl;
  final String? crawledAt;
  final int hop;
  final Color hopColor;

  const _NodeContentScreen({
    required this.title,
    required this.content,
    this.sourceUrl,
    this.crawledAt,
    required this.hop,
    required this.hopColor,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontSize: 15),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: const Color(0xFF0C132C),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Meta bar
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.grey.shade50,
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: hopColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      hop == 0 ? '源节点' : '$hop跳',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (crawledAt != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_today,
                            size: 11, color: Colors.grey.shade500),
                        const SizedBox(width: 3),
                        Text(
                          crawledAt!,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  if (sourceUrl != null && sourceUrl!.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link,
                            size: 11, color: Color(0xFF4A6CF7)),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            sourceUrl!,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF4A6CF7),
                              decoration: TextDecoration.underline,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Markdown content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectionArea(
                  child: MarkdownBody(
                    data: content,
                    onTapLink: (text, href, title) async {
                      if (href == null || href.trim().isEmpty) return;
                      try {
                        String urlStr = href.trim();
                        if (!urlStr.startsWith('http://') &&
                            !urlStr.startsWith('https://') &&
                            !urlStr.startsWith('mailto:')) {
                          urlStr = 'https://$urlStr';
                        }
                        final uri = Uri.parse(urlStr);
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                          webOnlyWindowName: '_blank',
                        );
                      } catch (e) {
                        debugPrint('Failed to open URL $href: $e');
                      }
                    },
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 14, height: 1.6),
                    h1: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                    h2: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                    h3: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                    code: TextStyle(
                      backgroundColor: Colors.grey.shade200,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    blockquoteDecoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                            color: Colors.grey.shade400, width: 3),
                      ),
                    ),
                    tableColumnWidth: const IntrinsicColumnWidth(),
                    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    tablePadding: const EdgeInsets.symmetric(vertical: 8),
                    tableBorder: TableBorder.all(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}
