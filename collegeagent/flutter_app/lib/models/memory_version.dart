class MemoryVersion {
  final String id;
  final int version;
  final DateTime timestamp;
  final String source;
  final String summary;
  final String content;
  final int charCount;
  final int lineCount;

  const MemoryVersion({
    required this.id,
    required this.version,
    required this.timestamp,
    required this.source,
    required this.summary,
    required this.content,
    required this.charCount,
    required this.lineCount,
  });

  factory MemoryVersion.fromJson(Map<String, dynamic> json) {
    return MemoryVersion(
      id: json['id'] as String? ?? '',
      version: json['version'] as int? ?? 1,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      source: json['source'] as String? ?? 'unknown',
      summary: json['summary'] as String? ?? '',
      content: json['content'] as String? ?? '',
      charCount: json['charCount'] as int? ?? 0,
      lineCount: json['lineCount'] as int? ?? 0,
    );
  }
}
