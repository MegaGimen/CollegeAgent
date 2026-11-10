import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class CanvasCoursesScreen extends StatefulWidget {
  final String userId;

  const CanvasCoursesScreen({super.key, required this.userId});

  @override
  State<CanvasCoursesScreen> createState() => _CanvasCoursesScreenState();
}

class _CanvasCoursesScreenState extends State<CanvasCoursesScreen> {
  final ApiService _api = ApiService();
  Timer? _statusTimer;

  bool _loadingCourses = false;
  bool _loadingModules = false;
  bool _submittingBatch = false;
  String? _error;

  List<dynamic> _courses = [];
  Map<String, dynamic>? _selectedCourse;

  List<dynamic> _modules = [];
  List<dynamic> _assignments = [];
  Map<String, dynamic>? _selectedModule;

  List<Map<String, dynamic>> _currentPages = [];
  final Set<String> _selectedPageKeys = {};
  final Set<String> _selectedModuleKeys = {};

  Set<String> _savedVaultKeys = {};
  Set<String> _runningTaskKeys = {};
  Map<String, String> _failedTasksMap = {};

  @override
  void initState() {
    super.initState();
    _loadCourses();
    _loadVaultStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _loadVaultStatus();
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _loadVaultStatus() async {
    try {
      final res = await _api.getVaultStatus(widget.userId);
      if (!mounted) return;
      setState(() {
        _savedVaultKeys = Set<String>.from(res['savedKeys'] as List<dynamic>? ?? []);
        _runningTaskKeys = Set<String>.from(res['runningTasks'] as List<dynamic>? ?? []);
        _failedTasksMap = Map<String, String>.from(res['failedTasks'] as Map<dynamic, dynamic>? ?? {});
      });
    } catch (_) {}
  }

  Future<void> _loadCourses() async {
    setState(() {
      _loadingCourses = true;
      _error = null;
    });
    try {
      final res = await _api.listCanvasCourses(widget.userId);
      if (!mounted) return;
      setState(() {
        _courses = res is List ? res : [];
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载课程失败: $e';
        _loadingCourses = false;
      });
    }
  }

  Future<void> _selectCourse(Map<String, dynamic> course) async {
    final courseId = course['id']?.toString() ?? '';
    setState(() {
      _selectedCourse = course;
      _selectedModule = null;
      _modules = [];
      _currentPages = [];
      _selectedPageKeys.clear();
      _selectedModuleKeys.clear();
      _loadingModules = true;
      _error = null;
    });

    try {
      final res = await _api.getCanvasModules(courseId, widget.userId);
      final assignmentsRes = await _api.getCanvasAssignments(courseId, widget.userId);
      if (!mounted) return;
      setState(() {
        if (res is Map && res['isError'] == true) {
          _error = '加载 Module 失败: ${res['error']}';
          _modules = [];
        } else if (assignmentsRes is Map && assignmentsRes['isError'] == true) {
          _error = '加载 Assignments 失败: ${assignmentsRes['error']}';
          _modules = res is List ? res : [];
        } else {
          _modules = res is List ? res : [];
          _assignments = assignmentsRes is List ? assignmentsRes : [];
        }
        _loadingModules = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载 Module 失败: $e';
        _loadingModules = false;
      });
    }
  }

  void _selectModule(Map<String, dynamic> module) {
    final courseId = _selectedCourse?['id']?.toString() ?? '';
    final items = (module['items'] as List<dynamic>?) ?? [];

    final List<Map<String, dynamic>> pageList = [];
    for (final item in items) {
      final type = item['type'] as String? ?? 'Page';
      final title = item['title'] as String? ?? 'Untitled';
      final pageUrl = item['page_url'] as String? ?? item['title']?.toString() ?? '';
      final itemId = item['id']?.toString() ?? '';

      pageList.add({
        'courseId': courseId,
        'courseName': _selectedCourse?['name'] ?? 'Course $courseId',
        'moduleId': module['id']?.toString() ?? '',
        'moduleName': module['name'] ?? 'Module ${module['id']}',
        'pageId': pageUrl,
        'title': title,
        'type': type,
        'itemId': itemId,
        'htmlUrl': item['html_url'],
      });
    }

    setState(() {
      _selectedModule = module;
      _currentPages = pageList;
      _selectedPageKeys.clear();
    });
  }

  bool _isModuleRunning(Map<String, dynamic> module) {
    final items = (module['items'] as List<dynamic>?) ?? [];
    if (items.isEmpty) return false;
    for (final item in items) {
      final pageUrl = item['page_url'] as String? ?? item['title']?.toString() ?? '';
      final courseId = _selectedCourse?['id']?.toString() ?? '';
      final moduleId = module['id']?.toString() ?? 'none';
      final key = '${courseId}_${moduleId}_$pageUrl';
      if (_runningTaskKeys.contains(key) || _runningTaskKeys.contains(pageUrl)) {
        return true;
      }
    }
    return false;
  }

  bool _isPageSaved(Map<String, dynamic> page) {
    final pageId = page['pageId'] as String? ?? '';
    final courseId = page['courseId'] as String? ?? '';
    final moduleId = page['moduleId'] as String? ?? 'none';
    final key = '${courseId}_${moduleId}_$pageId';
    return _savedVaultKeys.contains(pageId) ||
        _savedVaultKeys.contains(key) ||
        _savedVaultKeys.contains(page['title']);
  }

  bool _isPageRunning(Map<String, dynamic> page) {
    final pageId = page['pageId'] as String? ?? '';
    final courseId = page['courseId'] as String? ?? '';
    final moduleId = page['moduleId'] as String? ?? 'none';
    final key = '${courseId}_${moduleId}_$pageId';
    return _runningTaskKeys.contains(key) || _runningTaskKeys.contains(pageId);
  }

  String? _getPageError(Map<String, dynamic> page) {
    final pageId = page['pageId'] as String? ?? '';
    final courseId = page['courseId'] as String? ?? '';
    final moduleId = page['moduleId'] as String? ?? 'none';
    final key = '${courseId}_${moduleId}_$pageId';
    return _failedTasksMap[key] ?? _failedTasksMap[pageId];
  }

  Future<void> _submitBatchFetch() async {
    if (_selectedPageKeys.isEmpty) return;

    int minIdx = -1;
    int maxIdx = -1;
    for (int i = 0; i < _currentPages.length; i++) {
      if (_selectedPageKeys.contains(_currentPages[i]['pageId'])) {
        if (minIdx == -1) minIdx = i;
        maxIdx = i;
      }
    }

    final List<Map<String, dynamic>> selectedPages = [];
    if (minIdx != -1 && maxIdx != -1) {
      for (int i = minIdx; i <= maxIdx; i++) {
        final p = _currentPages[i];
        if (!_isPageSaved(p)) {
          selectedPages.add(p);
        }
      }
    }

    if (selectedPages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选择的页面均已在个人图谱中，已跳过。')),
      );
      setState(() => _selectedPageKeys.clear());
      return;
    }

    setState(() => _submittingBatch = true);

    try {
      final res = await _api.batchFetchGraph(widget.userId, selectedPages);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已创建 ${res['queuedCount']} 个后台异步图谱任务！'),
          backgroundColor: Colors.green,
        ),
      );

      setState(() {
        _selectedPageKeys.clear();
        _submittingBatch = false;
      });
      _loadVaultStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交异步任务失败: $e'), backgroundColor: Colors.red),
      );
      setState(() => _submittingBatch = false);
    }
  }

  Future<void> _submitBatchModulesFetch() async {
    if (_selectedModuleKeys.isEmpty) return;

    int minIdx = -1;
    int maxIdx = -1;
    for (int i = 0; i < _modules.length; i++) {
      final moduleId = _modules[i]['id']?.toString() ?? '';
      if (_selectedModuleKeys.contains(moduleId)) {
        if (minIdx == -1) minIdx = i;
        maxIdx = i;
      }
    }

    final List<Map<String, dynamic>> allPages = [];
    if (minIdx == -1 || maxIdx == -1) return;

    final courseId = _selectedCourse?['id']?.toString() ?? '';
    final courseName = _selectedCourse?['name'] ?? 'Course $courseId';

    for (int i = minIdx; i <= maxIdx; i++) {
      final module = _modules[i];
      final moduleId = module['id']?.toString() ?? '';

      final items = (module['items'] as List<dynamic>?) ?? [];
      for (final item in items) {
        final type = item['type'] as String? ?? 'Page';
        final title = item['title'] as String? ?? 'Untitled';
        final pageUrl = item['page_url'] as String? ?? item['title']?.toString() ?? '';
        final itemId = item['id']?.toString() ?? '';

        final pageData = {
          'courseId': courseId,
          'courseName': courseName,
          'moduleId': moduleId,
          'moduleName': module['name'] ?? 'Module $moduleId',
          'pageId': pageUrl,
          'title': title,
          'type': type,
          'itemId': itemId,
          'htmlUrl': item['html_url'],
        };
        
        if (!_isPageSaved(pageData)) {
          allPages.add(pageData);
        }
      }
    }

    if (allPages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选中的 Module 中所有页面均已入库，无需再次拉取。')),
      );
      setState(() => _selectedModuleKeys.clear());
      return;
    }

    setState(() => _submittingBatch = true);

    try {
      final res = await _api.batchFetchGraph(widget.userId, allPages);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已创建 ${res['queuedCount']} 个后台异步图谱任务！'),
          backgroundColor: Colors.green,
        ),
      );

      setState(() {
        _selectedModuleKeys.clear();
        _submittingBatch = false;
      });
      _loadVaultStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交异步任务失败: $e'), backgroundColor: Colors.red),
      );
      setState(() => _submittingBatch = false);
    }
  }

  Future<void> _showPageDetailDialog(Map<String, dynamic> page) async {
    showDialog(
      context: context,
      builder: (ctx) => _PageDetailModal(
        api: _api,
        userId: widget.userId,
        page: page,
      ),
    );
  }

  // Requirement 1: Hierarchical Title Banner
  String _buildAppBarTitle() {
    if (_selectedCourse == null) {
      return 'Canvas 课程管理';
    }
    final courseName = _selectedCourse!['name'] ?? 'Course ${_selectedCourse!['id']}';
    final courseId = _selectedCourse!['id']?.toString() ?? '';
    if (_selectedModule == null) {
      return 'Course: $courseName (ID: $courseId)';
    }
    final moduleName = _selectedModule!['name'] ?? 'Module ${_selectedModule!['id']}';
    final moduleId = _selectedModule!['id']?.toString() ?? '';
    return 'Course $courseId → Module $moduleId ($moduleName)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.school_outlined, color: Color(0xFF0C132C)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _buildAppBarTitle(),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (_selectedCourse == null) {
                _loadCourses();
              } else {
                _selectCourse(_selectedCourse!);
              }
              _loadVaultStatus();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Breadcrumb Trail with explicit hierarchy (Requirement 1)
            if (_selectedCourse != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.grey.shade100,
                child: Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.apps, size: 16),
                      label: const Text('所有课程'),
                      onPressed: () => setState(() {
                        _selectedCourse = null;
                        _selectedModule = null;
                      }),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            InkWell(
                              onTap: _selectedModule != null
                                  ? () => setState(() => _selectedModule = null)
                                  : null,
                              child: Text(
                                'Course: ${_selectedCourse!['name']} (${_selectedCourse!['id']})',
                                style: TextStyle(
                                  fontWeight: _selectedModule == null ? FontWeight.bold : FontWeight.normal,
                                  color: const Color(0xFF0C132C),
                                ),
                              ),
                            ),
                            if (_selectedModule != null) ...[
                              const Text(' → ', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                              Text(
                                'Module: ${_selectedModule!['name']} (ID: ${_selectedModule!['id']})',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.red.shade50,
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              ),

            // Main View
            Expanded(
              child: _selectedCourse == null
                  ? _buildCoursesList()
                  : (_selectedModule == null
                      ? _buildModulesList()
                      : _buildPagesListTable()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoursesList() {
    if (_loadingCourses) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_courses.isEmpty) {
      return const Center(child: Text('没有找到 Canvas 课程'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _courses.length,
      itemBuilder: (ctx, i) {
        final course = _courses[i];
        final name = course['name'] ?? 'Untitled Course';
        final code = course['course_code'] ?? '';
        final id = course['id']?.toString() ?? '';

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFF0C132C),
              child: Icon(Icons.book, color: Colors.white),
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('Course ID: $id ${code.isNotEmpty ? " • $code" : ""}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectCourse(course),
          ),
        );
      },
    );
  }

  Widget _buildModulesList() {
    if (_loadingModules) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_modules.isEmpty) {
      return const Center(child: Text('该课程下没有找到 Module'));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Checkbox(
                value: _modules.isNotEmpty && _selectedModuleKeys.length == _modules.length,
                onChanged: _submittingBatch ? null : (val) {
                  setState(() {
                    if (val == true) {
                      _selectedModuleKeys.clear();
                      _selectedModuleKeys.addAll(_modules.map((m) => m['id'].toString()));
                    } else {
                      _selectedModuleKeys.clear();
                    }
                  });
                },
              ),
              ),
              const Text('全选', style: TextStyle(fontSize: 14)),
              const Spacer(),
              Text(
                '包含 ${_modules.length} 个 Modules',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                ),
                icon: _submittingBatch
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_photos, size: 18),
                label: Text('加入个人图谱 (${_selectedModuleKeys.length})'),
                onPressed: (_selectedModuleKeys.isEmpty || _submittingBatch)
                    ? null
                    : _submitBatchModulesFetch,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _modules.length,
            itemBuilder: (ctx, i) {
              final module = _modules[i];
              final name = module['name'] ?? 'Untitled Module';
              final id = module['id']?.toString() ?? '';
              final itemCount = module['items_count'] ?? (module['items'] as List?)?.length ?? 0;
              final isRunning = _isModuleRunning(module);
              
              // Compute module error
              String? moduleError;
              final items = (module['items'] as List<dynamic>?) ?? [];
              for (final item in items) {
                final pageUrl = item['page_url'] as String? ?? item['title']?.toString() ?? '';
                final courseId = _selectedCourse?['id']?.toString() ?? '';
                final key = '${courseId}_${id}_$pageUrl';
                if (_failedTasksMap.containsKey(key) || _failedTasksMap.containsKey(pageUrl)) {
                  moduleError = _failedTasksMap[key] ?? _failedTasksMap[pageUrl];
                  break;
                }
              }

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Checkbox(
                    value: _selectedModuleKeys.contains(id),
                    onChanged: isRunning
                        ? null // Lock if currently running
                        : (selected) {
                            setState(() {
                              if (selected == true) {
                                _selectedModuleKeys.add(id);
                              } else {
                                _selectedModuleKeys.remove(id);
                              }
                            });
                          },
                  ),
                  title: Row(
                    children: [
                      const CircleAvatar(
                        radius: 14,
                        backgroundColor: Color(0xFF4CAF50),
                        child: Icon(Icons.view_module, color: Colors.white, size: 16),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (isRunning)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      if (!isRunning && moduleError != null)
                        Tooltip(
                          message: moduleError,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(Icons.error, color: Colors.red.shade700, size: 18),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Builder(
                    builder: (context) {
                      final items = module['items'] as List<dynamic>? ?? [];
                      int completedCount = 0;
                      int reqCount = 0;
                      String quizSummary = '';
                      
                      for (final item in items) {
                        if (item['completion_requirement'] != null) {
                          reqCount++;
                          if (item['completion_requirement']['completed'] == true) {
                            completedCount++;
                          }
                        }
                        if (item['type'] == 'Quiz') {
                          // Try to match with an assignment to get the score
                          final quizAssign = _assignments.firstWhere(
                            (a) => a['is_quiz_assignment'] == true && (a['name'] == item['title'] || a['quiz_id'] == item['content_id']),
                            orElse: () => null,
                          );
                          if (quizAssign != null && quizAssign['submission'] != null) {
                            final score = quizAssign['submission']['score'];
                            quizSummary += ' | 测验: ${item['title']} (得分: $score)';
                          }
                        }
                      }
                      
                      int vaultSavedCount = 0;
                      for (final item in items) {
                        final pageUrl = item['page_url'] as String? ?? item['title']?.toString() ?? '';
                        final key = '${_selectedCourse?['id']}_${id}_$pageUrl';
                        if (_savedVaultKeys.contains(key) || _savedVaultKeys.contains(pageUrl)) {
                          vaultSavedCount++;
                        }
                      }
                      
                      bool isCompleted = reqCount > 0 ? (completedCount == reqCount) : (module['state'] == 'completed');
                      
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Module ID: $id  •  包含 $itemCount 项内容', style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text('入库进度: $vaultSavedCount/$itemCount', style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                              const SizedBox(width: 12),
                              Text('硬性要求: $completedCount/$reqCount', style: const TextStyle(fontSize: 13)),
                              if (isCompleted) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.circle, color: Colors.green.shade600, size: 8),
                                      const SizedBox(width: 4),
                                      Text('completed!', style: TextStyle(color: Colors.green.shade700, fontSize: 11, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (quizSummary.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(quizSummary, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                            ),
                        ],
                      );
                    },
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _selectModule(module),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Requirement 2: Single Checkbox column (removed duplicate custom checkbox column)
  Widget _buildPagesListTable() {
    if (_currentPages.isEmpty) {
      return const Center(child: Text('该 Module 下没有页面卡片'));
    }

    int vaultSavedCount = _currentPages.where((p) => _isPageSaved(p)).length;
    int hardReqTotal = 0;
    int hardReqCompleted = 0;
    if (_selectedModule != null) {
      final items = (_selectedModule!['items'] as List<dynamic>?) ?? [];
      for (final item in items) {
        if (item['completion_requirement'] != null) {
          hardReqTotal++;
          if (item['completion_requirement']['completed'] == true) {
            hardReqCompleted++;
          }
        }
      }
    }

    return Column(
      children: [
        // Action Bar for Batch Selection
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '入库进度: $vaultSavedCount / ${_currentPages.length} 页面',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '硬性要求: $hardReqCompleted / $hardReqTotal',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                ],
              ),
              const Spacer(),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0C132C),
                  foregroundColor: Colors.white,
                ),
                icon: _submittingBatch
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_photos, size: 18),
                label: Text('加入个人图谱 (${_selectedPageKeys.length})'),
                onPressed: (_selectedPageKeys.isEmpty || _submittingBatch)
                    ? null
                    : _submitBatchFetch,
              ),
            ],
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  // Rely ONLY on DataRow's built-in selection checkbox to prevent duplicates!
                  DataColumn(label: Text('页面标题')),
                  DataColumn(label: Text('类型')),
                  DataColumn(label: Text('个人图谱状态')),
                  DataColumn(label: Text('操作')),
                ],
                rows: _currentPages.map((page) {
                  final pageId = page['pageId'] as String? ?? '';
                  final title = page['title'] as String? ?? '';
                  final type = page['type'] as String? ?? '';
                  final isPage = type == 'Page';
                  final isSaved = _isPageSaved(page);
                  final isRunning = _isPageRunning(page);
                  final pageError = _getPageError(page);

                  return DataRow(
                    selected: _selectedPageKeys.contains(pageId),
                    onSelectChanged: (!isPage || isRunning)
                        ? null // Lock selection if not a Page or if running!
                        : (selected) {
                            setState(() {
                              if (selected == true) {
                                _selectedPageKeys.add(pageId);
                              } else {
                                _selectedPageKeys.remove(pageId);
                              }
                            });
                          },
                    cells: [
                      DataCell(
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      DataCell(
                        Chip(
                          label: Text(type, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      DataCell(
                        _buildStatusBadge(
                          isSaved: isSaved, 
                          isRunning: isRunning, 
                          isSupported: isPage,
                          error: pageError,
                        ),
                      ),
                      DataCell(
                        type == 'Quiz'
                            ? InkWell(
                                onSecondaryTap: () {
                                  final htmlUrl = page['htmlUrl']?.toString() ?? '';
                                  if (htmlUrl.isNotEmpty) {
                                    Clipboard.setData(ClipboardData(text: htmlUrl));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已复制链接'), behavior: SnackBarBehavior.floating)
                                    );
                                  }
                                },
                                child: TextButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: const Text('跳转quiz链接'),
                                  onPressed: () {
                                    final htmlUrl = page['htmlUrl']?.toString() ?? '';
                                    if (htmlUrl.isNotEmpty) {
                                      launchUrl(Uri.parse(htmlUrl));
                                    }
                                  },
                                ),
                              )
                            : TextButton.icon(
                                icon: const Icon(Icons.visibility_outlined, size: 16),
                                label: const Text('查看 HTML/MD'),
                                onPressed: isSaved ? () => _showPageDetailDialog(page) : null,
                              ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge({required bool isSaved, required bool isRunning, bool isSupported = true, String? error}) {
    if (error != null) {
      return Tooltip(
        message: error,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 14, color: Colors.red.shade900),
              const SizedBox(width: 4),
              Text('获取失败', style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    if (!isSupported) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '暂不支持该类型',
          style: TextStyle(color: Colors.red.shade800, fontSize: 12),
        ),
      );
    }
    if (isRunning) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.amber.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.amber.shade800,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '异步任务抓取中...',
              style: TextStyle(color: Colors.amber.shade900, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (isSaved) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '已放入个人 Vault',
          style: TextStyle(color: Colors.green.shade800, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        '未入库',
        style: TextStyle(color: Colors.grey, fontSize: 12),
      ),
    );
  }
}

// ── Requirement 3: Modal Dialog with proper HTML Rendering & Clean Markdown ──

class _PageDetailModal extends StatefulWidget {
  final ApiService api;
  final String userId;
  final Map<String, dynamic> page;

  const _PageDetailModal({
    required this.api,
    required this.userId,
    required this.page,
  });

  @override
  State<_PageDetailModal> createState() => _PageDetailModalState();
}

class _PageDetailModalState extends State<_PageDetailModal>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = true;
  String? _error;

  String _title = '';
  String _rawHtml = '';
  String _markdownContent = '';
  String _aiSummary = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _title = widget.page['title']?.toString() ?? 'Page Details';
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    try {
      final courseId = widget.page['courseId']?.toString() ?? '';
      final moduleId = widget.page['moduleId']?.toString();
      final pageId = widget.page['pageId']?.toString() ?? '';

      final res = await widget.api.getCanvasPageDetail(
        courseId,
        moduleId,
        pageId,
        widget.userId,
        itemType: widget.page['type']?.toString(),
        itemId: widget.page['itemId']?.toString(),
      );

      if (!mounted) return;
      setState(() {
        _title = res['title'] ?? _title;
        _rawHtml = res['rawHtml']?.toString() ?? '';
        _markdownContent = res['rawContent']?.toString() ?? res['content']?.toString() ?? '';
        _aiSummary = res['summary']?.toString() ?? '暂无 AI 总结。';
        if (_aiSummary.isEmpty) _aiSummary = '暂无 AI 总结。';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取页面详情失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final courseId = widget.page['courseId']?.toString() ?? '';
    final moduleId = widget.page['moduleId']?.toString() ?? '';
    final pageId = widget.page['pageId']?.toString() ?? '';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 860,
        height: 640,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Requirement 1: Hierarchical Title in Dialog
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Course $courseId → Module $moduleId → Page',
                        style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$_title ($pageId)',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TabBar(
              controller: _tabController,
              labelColor: const Color(0xFF0C132C),
              tabs: const [
                Tab(text: 'AI 内容总结'),
                Tab(text: 'HTML 网页渲染 (Canvas 原生 HTML)'),
                Tab(text: 'DOM 转义 Markdown (本地知识库)'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            // Tab 1: AI Summary View
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: SelectionArea(
                                child: Markdown(
                                  data: _aiSummary,
                                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                    tableColumnWidth: const IntrinsicColumnWidth(),
                                    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    tablePadding: const EdgeInsets.symmetric(vertical: 8),
                                    tableBorder: TableBorder.all(
                                      color: const Color(0xFFCBD5E1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
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
                                ),
                              ),
                            ),
                            // Tab 2: Rendered HTML with flutter_widget_from_html
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SingleChildScrollView(
                                child: HtmlWidget(
                                  _rawHtml.isNotEmpty ? _rawHtml : _markdownContent,
                                  textStyle: const TextStyle(fontSize: 14, height: 1.6),
                                ),
                              ),
                            ),
                            // Tab 3: Clean Markdown Rendering
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectionArea(
                                child: Markdown(
                                  data: _markdownContent,
                                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                    tableColumnWidth: const IntrinsicColumnWidth(),
                                    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    tablePadding: const EdgeInsets.symmetric(vertical: 8),
                                    tableBorder: TableBorder.all(
                                      color: const Color(0xFFCBD5E1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
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
                                ),
                              ),
                            ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
