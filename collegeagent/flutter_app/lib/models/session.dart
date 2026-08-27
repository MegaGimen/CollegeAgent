class SessionModel {
  final String id;
  final String userId;
  final String? parentId;
  final String status;
  final String? lastActive;
  final String createdAt;
  String? title;
  String? lastMessage;
  String? latestAssistant;
  int msgCount;
  bool pinned;

  SessionModel({
    required this.id,
    required this.userId,
    this.parentId,
    required this.status,
    this.lastActive,
    required this.createdAt,
    this.title,
    this.lastMessage,
    this.latestAssistant,
    this.msgCount = 0,
    this.pinned = false,
  });

  factory SessionModel.fromJson(Map<String, dynamic> json) {
    return SessionModel(
      id: json['id'] as String,
      userId: (json['userId'] ?? json['user_id'] ?? '') as String,
      parentId: (json['parentId'] ?? json['parent_id']) as String?,
      status: json['status'] as String? ?? 'active',
      lastActive: (json['lastActive'] ?? json['last_active']) as String?,
      createdAt: (json['createdAt'] ?? json['created_at']) as String,
      title: json['title'] as String?,
      lastMessage: (json['lastMessage'] ?? json['last_message']) as String?,
      latestAssistant: (json['latestAssistant'] ?? json['latest_assistant']) as String?,
      msgCount: (json['msgCount'] ?? json['msg_count'] ?? 0) as int,
      pinned: _parseBool(json['pinned']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'parentId': parentId,
    'status': status,
    'lastActive': lastActive,
    'createdAt': createdAt,
    'title': title,
    'lastMessage': lastMessage,
    'latestAssistant': latestAssistant,
    'msgCount': msgCount,
    'pinned': pinned,
  };

  // Helper: parse bool from int (SQLite) or bool (JSON/server)
  static bool _parseBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is int) return v == 1;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return false;
  }

  Map<String, dynamic> toDbMap() => {
    'id': id,
    'user_id': userId,
    'parent_id': parentId,
    'title': title,
    'last_message': lastMessage,
    'latest_assistant': latestAssistant,
    'msg_count': msgCount,
    'last_active': lastActive,
    'created_at': createdAt,
    'pinned': pinned ? 1 : 0,
  };
}
