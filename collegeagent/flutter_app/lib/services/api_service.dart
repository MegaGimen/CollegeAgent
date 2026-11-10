import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/session.dart';
import '../models/message.dart';
import '../models/memory_version.dart';

typedef OnToken = void Function(String token);
typedef OnDone = void Function(String messageId, String fullText);
typedef OnError = void Function(String error);
typedef OnToolStart = void Function(String name, Map<String, dynamic> args);
typedef OnToolEnd = void Function(String name, String result);
typedef OnIntermediateText = void Function(String text);
typedef OnCitations = void Function(List<Citation> citations);

class ApiService {
  String baseUrl;
  final http.Client _client = http.Client();

  ApiService({this.baseUrl = 'https://llinker.com/collegeagent-api'});

  Future<UserModel> login(String username) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username}),
    );
    if (res.statusCode != 200) {
      throw Exception('Login failed: ${res.body}');
    }
    return UserModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<SessionModel>> getSessions(String userId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/sessions?userId=$userId'),
    );
    if (res.statusCode != 200) {
      throw Exception('Get sessions failed: ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => SessionModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SessionModel> createSession(
    String userId, {
    String mode = 'regular',
    String? courseId,
    String? courseName,
    List<String>? fileIds,
    String? title,
  }) async {
    final body = <String, dynamic>{
      'userId': userId,
      'mode': mode,
    };
    if (courseId != null) body['courseId'] = courseId;
    if (courseName != null) body['courseName'] = courseName;
    if (fileIds != null) body['fileIds'] = fileIds;
    if (title != null) body['title'] = title;

    final res = await _client.post(
      Uri.parse('$baseUrl/api/sessions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 201) {
      throw Exception('Create session failed: ${res.body}');
    }
    return SessionModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<SessionModel> forkSession(String userId, String sessionId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/sessions/fork'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userId': userId, 'sessionId': sessionId}),
    );
    if (res.statusCode != 201) {
      throw Exception('Fork session failed: ${res.body}');
    }
    return SessionModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<MessageModel>> getMessages(String sessionId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/messages?sessionId=$sessionId'),
    );
    if (res.statusCode != 200) {
      throw Exception('Get messages failed: ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => MessageModel.fromJson(e as Map<String, dynamic>, sessionId))
        .toList();
  }

  Future<void> stopChat(String sessionId) async {
    try {
      await _client.post(
        Uri.parse('$baseUrl/api/chat/stop'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'sessionId': sessionId}),
      );
    } catch (_) {}
  }

  /// Sends a message and streams the AI response via SSE.
  /// Returns a Future that resolves to a cancel function.
  Future<void Function()> streamChat({
    required String userId,
    required String sessionId,
    required String text,
    required OnToken onToken,
    required OnDone onDone,
    OnError? onError,
    OnToolStart? onToolStart,
    OnToolEnd? onToolEnd,
    OnIntermediateText? onIntermediateText,
    OnCitations? onCitations,
  }) async {
    final now = DateTime.now();
    final requestBody = jsonEncode({
      'userId': userId,
      'sessionId': sessionId,
      'text': text,
      'localTime': now.toIso8601String(),
      'timeZoneOffset': now.timeZoneOffset.inMinutes,
      'timeZoneName': now.timeZoneName,
    });

    final client = http.Client();

    final request = http.StreamedRequest(
      'POST',
      Uri.parse('$baseUrl/api/chat'),
    );
    request.headers.addAll({
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'text/event-stream',
    });
    request.sink.add(utf8.encode(requestBody));
    request.sink.close();

    final response = await client.send(request);

    if (response.statusCode != 200) {
      final errBody = await response.stream.transform(utf8.decoder).join();
      client.close();
      throw Exception('Chat failed (${response.statusCode}): $errBody');
    }

    bool cancelled = false;

    () async {
      String buf = '';
      try {
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          if (cancelled) break;
          buf += chunk;

          final parts = buf.split('\n\n');
          buf = parts.removeLast();

          for (final part in parts) {
            final lines = part.split('\n');
            String? eventType;
            String? dataStr;

            for (final line in lines) {
              if (line.startsWith('event: ')) {
                eventType = line.substring(7);
              } else if (line.startsWith('data: ')) {
                dataStr = line.substring(6);
              }
            }

            if (eventType == null || dataStr == null) continue;

            try {
              final data = jsonDecode(dataStr) as Map<String, dynamic>;

              switch (eventType) {
                case 'token':
                  onToken(data['content'] as String);
                  break;
                case 'done':
                  onDone(
                    data['messageId'] as String,
                    data['text'] as String,
                  );
                  break;
                case 'error':
                  onError?.call(data['message'] as String);
                  break;
                case 'tool_start':
                  onToolStart?.call(
                    data['name'] as String,
                    (data['args'] as Map<String, dynamic>?) ?? {},
                  );
                  break;
                case 'tool_end':
                  onToolEnd?.call(
                    data['name'] as String,
                    (data['result'] as String?) ?? '',
                  );
                  break;
                case 'intermediate_text':
                  onIntermediateText?.call(
                    data['content'] as String? ?? '',
                  );
                  break;
                case 'citations':
                  final citationList = (data['citations'] as List<dynamic>?)
                      ?.map((e) => Citation.fromJson(e as Map<String, dynamic>))
                      .toList() ?? [];
                  onCitations?.call(citationList);
                  break;
              }
            } catch (_) {
              // skip malformed events
            }
          }
        }
      } catch (e) {
        if (!cancelled) onError?.call(e.toString());
      } finally {
        client.close();
      }
    }();

    return () {
      cancelled = true;
      client.close();
    };
  }

  Future<String> getMemory(String userId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/memory?userId=$userId'),
    );
    if (res.statusCode != 200) {
      throw Exception('Get memory failed: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['content'] as String? ?? '';
  }

  Future<void> putMemory(String userId, String content) async {
    final res = await _client.put(
      Uri.parse('$baseUrl/api/memory'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'content': content,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Put memory failed: ${res.body}');
    }
  }

  Future<List<MemoryVersion>> getMemoryVersions(String userId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/memory/versions?userId=$userId'),
    );
    if (res.statusCode != 200) {
      throw Exception('Get memory versions failed: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['versions'] as List<dynamic>? ?? [];
    return list.map((e) => MemoryVersion.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String> rollbackMemory(String userId, String versionId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/memory/rollback'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'versionId': versionId,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Rollback memory failed: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['content'] as String? ?? '';
  }

  Future<void> rollbackMessage(String sessionId, String messageId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/messages/rollback'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'sessionId': sessionId,
        'messageId': messageId,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Rollback message failed: ${res.body}');
    }
  }

  Future<void> deleteSession(String sessionId) async {
    final res = await _client.delete(
      Uri.parse('$baseUrl/api/sessions/$sessionId'),
    );
    if (res.statusCode != 200) {
      throw Exception('Delete session failed: ${res.body}');
    }
  }

  Future<SessionModel> patchSession(String sessionId, {String? title, bool? pinned}) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (pinned != null) body['pinned'] = pinned;
    final res = await _client.patch(
      Uri.parse('$baseUrl/api/sessions/$sessionId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception('Patch session failed: ${res.body}');
    }
    return SessionModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<dynamic> listCanvasCourses(String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/courses?userId=$userId'));
    if (res.statusCode != 200) throw Exception('Failed to list Canvas courses: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<dynamic> getCanvasModules(String courseId, String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/modules?courseId=$courseId&userId=$userId'));
    if (res.statusCode != 200) throw Exception('Failed to get Canvas modules: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<dynamic> getCanvasAssignments(String courseId, String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/assignments?courseId=$courseId&userId=$userId'));
    if (res.statusCode != 200) throw Exception('Failed to get Canvas assignments: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<dynamic> getCanvasPages(String courseId, String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/pages?courseId=$courseId&userId=$userId'));
    if (res.statusCode != 200) throw Exception('Failed to get Canvas pages: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<dynamic> getCanvasFiles(String courseId, {String? userId}) async {
    final query = userId != null ? 'courseId=$courseId&userId=$userId' : 'courseId=$courseId';
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/files?$query'));
    if (res.statusCode != 200) throw Exception('Failed to get Canvas files: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> packageCanvasFiles({
    required String courseId,
    required String courseName,
    required List<String> fileIds,
    String? userId,
  }) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/canvas/package-files'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'courseId': courseId,
        'courseName': courseName,
        'fileIds': fileIds,
        'userId': userId,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('打包文件失败: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<dynamic> getCanvasPageDetail(String courseId, String? moduleId, String pageId, String userId, {String? itemType, String? itemId}) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/canvas/page-detail'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'courseId': courseId,
        'moduleId': moduleId,
        'pageId': pageId,
        'userId': userId,
        'itemType': itemType,
        'itemId': itemId,
      }),
    );
    if (res.statusCode != 200) throw Exception('Failed to fetch Canvas page detail: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> getVaultStatus(String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/canvas/vault-status?userId=$userId'));
    if (res.statusCode != 200) throw Exception('Failed to get vault status: ${res.body}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<dynamic> batchFetchGraph(String userId, List<Map<String, dynamic>> pages) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/canvas/batch-fetch-graph'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'pages': pages,
      }),
    );
    if (res.statusCode != 200) throw Exception('Failed to start batch fetch: ${res.body}');
    return jsonDecode(res.body);
  }

  Future<dynamic> getCalendarEvents(String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/calendar/events?userId=$userId'));
    if (res.statusCode == 401) {
      throw Exception('NEEDS_AUTH');
    } else if (res.statusCode != 200) {
      throw Exception('Failed to get calendar events: ${res.body}');
    }
    return jsonDecode(res.body);
  }
  Future<dynamic> getGmailMessages(String userId) async {
    print('[API] getGmailMessages called for userId: $userId');
    try {
      final uri = Uri.parse('$baseUrl/api/gmail/messages?userId=$userId');
      print('[API] Sending GET request to: $uri');
      final res = await _client.get(uri);
      print('[API] Response received. Status: ${res.statusCode}');
      
      if (res.statusCode == 401) {
        print('[API] Status is 401, throwing NEEDS_AUTH Exception');
        throw Exception('NEEDS_AUTH');
      } else if (res.statusCode != 200) {
        print('[API] Status is NOT 200, throwing general Exception');
        throw Exception('Failed to get Gmail messages: ${res.body}');
      }
      
      print('[API] Parsing JSON body');
      final decoded = jsonDecode(res.body);
      print('[API] JSON parsed successfully. Type: ${decoded.runtimeType}');
      return decoded;
    } catch (e) {
      print('[API] Exception inside getGmailMessages: $e');
      rethrow;
    }
  }

  Future<dynamic> getGmailMessageHtml(String userId, String messageId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/gmail/message/$messageId?userId=$userId'));
    if (res.statusCode == 401) {
      throw Exception('NEEDS_AUTH');
    } else if (res.statusCode != 200) {
      throw Exception('Failed to get Gmail message detail: ${res.body}');
    }
    return jsonDecode(res.body);
  }

  Future<dynamic> syncGmailVault(String userId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/gmail/sync'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userId': userId}),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to trigger Gmail sync: ${res.body}');
    }
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> getGmailSyncStatus(String userId) async {
    final res = await _client.get(Uri.parse('$baseUrl/api/gmail/sync-status?userId=$userId'));
    if (res.statusCode != 200) {
      return {'syncing': false};
    }
    return Map<String, dynamic>.from(jsonDecode(res.body));
  }

  Future<Map<String, dynamic>> getLumaEvents({
    String city = 'san_francisco',
    List<String>? categories,
    String? startDate,
    String? endDate,
    int limit = 50,
    String? cursor,
    String? query,
    String? slug,
  }) async {
    final queryParams = <String, String>{
      'city': city,
      'pagination_limit': limit.toString(),
    };
    if (categories != null && categories.isNotEmpty) {
      queryParams['categories'] = categories.join(',');
    } else if (slug != null && slug.isNotEmpty) {
      queryParams['slug'] = slug;
    }
    if (startDate != null && startDate.isNotEmpty) {
      queryParams['start_date'] = startDate;
    }
    if (endDate != null && endDate.isNotEmpty) {
      queryParams['end_date'] = endDate;
    }
    if (cursor != null && cursor.isNotEmpty) {
      queryParams['pagination_cursor'] = cursor;
    }
    if (query != null && query.isNotEmpty) {
      queryParams['query'] = query;
    }

    final uri = Uri.parse('$baseUrl/api/luma/events').replace(queryParameters: queryParams);
    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch Luma events: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getLumaEventDetail(String eventApiId) async {
    final uri = Uri.parse('$baseUrl/api/luma/event-detail').replace(queryParameters: {
      'event_api_id': eventApiId,
    });
    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch Luma event detail: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getLumaDumpMarkdown({
    String city = 'san_francisco',
    List<String>? categories,
    String? startDate,
    String? endDate,
    int page = 1,
    String? cursor,
  }) async {
    final queryParams = <String, String>{
      'city': city,
      'locations': city,
      'page': page.toString(),
    };
    if (categories != null && categories.isNotEmpty) {
      queryParams['categories'] = categories.join(',');
    }
    if (startDate != null && startDate.isNotEmpty) {
      queryParams['start_date'] = startDate;
    }
    if (endDate != null && endDate.isNotEmpty) {
      queryParams['end_date'] = endDate;
    }
    if (cursor != null && cursor.isNotEmpty) {
      queryParams['pagination_cursor'] = cursor;
    }

    final uri = Uri.parse('$baseUrl/api/luma/dump-markdown').replace(queryParameters: queryParams);
    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch Luma dump markdown: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startLumaVaultSync({
    required String startDate,
    required String endDate,
    List<String>? locations,
  }) async {
    final uri = Uri.parse('$baseUrl/api/luma/vault/sync-task');
    final res = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start_date': startDate,
        'end_date': endDate,
        if (locations != null && locations.isNotEmpty) 'locations': locations,
      }),
    );
    if (res.statusCode != 200) {
      String errMsg = '启动同步任务失败';
      try {
        final err = jsonDecode(res.body);
        if (err['error'] != null) errMsg = err['error'];
      } catch (_) {}
      throw Exception(errMsg);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getLumaVaultSyncStatus() async {
    final uri = Uri.parse('$baseUrl/api/luma/vault/sync-task');
    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw Exception('获取同步任务状态失败');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void dispose() {
    _client.close();
  }
}
