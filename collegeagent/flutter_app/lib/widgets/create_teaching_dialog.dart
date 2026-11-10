import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/session_provider.dart';
import '../services/download_helper.dart';

class CreateTeachingDialog extends StatefulWidget {
  final String userId;

  const CreateTeachingDialog({super.key, required this.userId});

  static Future<dynamic> show(BuildContext context, String userId) {
    return showDialog<dynamic>(
      context: context,
      barrierDismissible: true,
      builder: (_) => CreateTeachingDialog(userId: userId),
    );
  }

  @override
  State<CreateTeachingDialog> createState() => _CreateTeachingDialogState();
}

class _CreateTeachingDialogState extends State<CreateTeachingDialog> {
  bool _loadingCourses = true;
  String? _courseError;
  List<dynamic> _courses = [];
  dynamic _selectedCourse;

  bool _loadingFiles = false;
  String? _fileError;
  List<dynamic> _files = [];
  final Set<String> _selectedFileIds = {};

  final TextEditingController _searchController = TextEditingController();
  String _fileSearchQuery = '';

  bool _submitting = false;
  String? _submitError;
  Map<String, dynamic>? _packagedResult;

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCourses() async {
    setState(() {
      _loadingCourses = true;
      _courseError = null;
    });

    try {
      final sessionProv = context.read<SessionProvider>();
      final data = await sessionProv.api.listCanvasCourses(widget.userId);
      if (data is List) {
        setState(() {
          _courses = data;
          _loadingCourses = false;
          if (_courses.isNotEmpty) {
            _onSelectCourse(_courses.first);
          }
        });
      } else {
        setState(() {
          _courseError = '无法获取课程列表';
          _loadingCourses = false;
        });
      }
    } catch (e) {
      setState(() {
        _courseError = '加载课程失败: $e';
        _loadingCourses = false;
      });
    }
  }

  void _onSelectCourse(dynamic course) {
    setState(() {
      _selectedCourse = course;
      _selectedFileIds.clear();
      _fileSearchQuery = '';
      _searchController.clear();
      _packagedResult = null;
      _submitError = null;
    });
    _loadFiles(course['id'].toString());
  }

  Future<void> _loadFiles(String courseId) async {
    setState(() {
      _loadingFiles = true;
      _fileError = null;
      _files = [];
    });

    try {
      final sessionProv = context.read<SessionProvider>();
      final data = await sessionProv.api.getCanvasFiles(courseId, userId: widget.userId);
      if (data is List) {
        setState(() {
          _files = data;
          _loadingFiles = false;
        });
      } else {
        setState(() {
          _fileError = '无法获取文件列表';
          _loadingFiles = false;
        });
      }
    } catch (e) {
      setState(() {
        _fileError = '加载文件失败: $e';
        _loadingFiles = false;
      });
    }
  }

  Future<void> _downloadSingleFile(dynamic file) async {
    final url = file['url']?.toString();
    final fileName = (file['display_name'] ?? file['filename'] ?? 'file').toString();
    if (url != null && url.isNotEmpty) {
      try {
        triggerBrowserDownload(url, fileName);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('下载文件失败: $e')),
          );
        }
      }
    }
  }

  Future<void> _submit() async {
    if (_selectedCourse == null || _selectedFileIds.isEmpty) return;

    setState(() {
      _submitting = true;
      _submitError = null;
      _packagedResult = null;
    });

    try {
      final sessionProv = context.read<SessionProvider>();
      final courseId = _selectedCourse['id'].toString();
      final courseName = _selectedCourse['name'] ?? _selectedCourse['course_code'] ?? 'course';

      final res = await sessionProv.api.packageCanvasFiles(
        courseId: courseId,
        courseName: courseName,
        fileIds: _selectedFileIds.toList(),
        userId: widget.userId,
      );

      final downloadUrl = res['downloadUrl'] as String? ?? '';
      final fileName = res['fileName'] as String? ?? 'files.zip';

      String fullUrl = downloadUrl;
      if (!fullUrl.startsWith('http://') && !fullUrl.startsWith('https://')) {
        final base = sessionProv.api.baseUrl;
        fullUrl = '$base$downloadUrl';
      }

      res['fullUrl'] = fullUrl;

      // Attempt automatic download
      triggerBrowserDownload(fullUrl, fileName);

      if (mounted) {
        setState(() {
          _submitting = false;
          _packagedResult = res;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitError = '打包下载失败: $e';
        });
      }
    }
  }

  IconData _getFileIcon(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.ppt') || lower.endsWith('.pptx')) return Icons.slideshow;
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return Icons.description;
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx')) return Icons.table_chart;
    if (lower.endsWith('.zip') || lower.endsWith('.tar') || lower.endsWith('.gz')) return Icons.folder_zip;
    return Icons.insert_drive_file;
  }

  String _formatSize(dynamic size) {
    if (size == null) return '';
    final bytes = int.tryParse(size.toString()) ?? 0;
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C);
    final cardBg = isDark ? const Color(0xFF0C1D36) : const Color(0xFFF1F5F9);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: isDark ? const Color(0xFF081226) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 680,
        height: 720,
        padding: const EdgeInsets.all(24),
        child: _packagedResult != null
            ? _buildSuccessView(isDark, cardBg)
            : _buildSelectionView(isDark, primaryColor, cardBg),
      ),
    );
  }

  Widget _buildSuccessView(bool isDark, Color cardBg) {
    final fileName = _packagedResult!['fileName']?.toString() ?? 'files.zip';
    final fullUrl = _packagedResult!['fullUrl']?.toString() ?? '';
    final totalFiles = _packagedResult!['totalFiles']?.toString() ?? '0';
    final sizeStr = _formatSize(_packagedResult!['size']);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle_outline, color: Color(0xFF10B981), size: 52),
        ),
        const SizedBox(height: 20),
        Text(
          '课件压缩包已打包完成',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : const Color(0xFF0C132C),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '已成功将选中的 $totalFiles 个文件打包完毕 ($sizeStr)',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 24),

        // File Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_zip, color: Color(0xFF10B981), size: 32),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '文件大小: $sizeStr  •  共 $totalFiles 个文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Hint banner about browser popup blockers
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, color: Colors.amber, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '注意：浏览器通常会拦截非即时用户点击触发的自动下载弹窗。若浏览器未自动弹出下载窗口，请直接点击下方【点击立即下载】按钮。',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),

        // Main Action: Click to download now
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 2,
          ),
          onPressed: () {
            triggerBrowserDownload(fullUrl, fileName);
          },
          icon: const Icon(Icons.download, size: 20),
          label: const Text(
            '点击立即下载压缩包',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),

        const SizedBox(height: 12),

        // Secondary Actions: Copy Link & Close
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C),
                side: BorderSide(color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade400),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: fullUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制下载直链到剪贴板'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制下载直链', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () {
                setState(() => _packagedResult = null);
              },
              child: Text(
                '返回重新选择',
                style: TextStyle(color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade700),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '关闭',
                style: TextStyle(color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionView(bool isDark, Color primaryColor, Color cardBg) {
    final filteredFiles = _files.where((f) {
      if (_fileSearchQuery.isEmpty) return true;
      final name = (f['display_name'] ?? f['filename'] ?? '').toString().toLowerCase();
      return name.contains(_fileSearchQuery.toLowerCase());
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.folder_zip_outlined, color: Color(0xFF10B981), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '课程文件下载',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0C132C),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '选择课程与需要的文件，直接打包为 ZIP 下载查阅，无需格式转换',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (!_submitting)
              IconButton(
                icon: Icon(Icons.close, size: 20, color: isDark ? Colors.white70 : Colors.grey.shade600),
                onPressed: () => Navigator.of(context).pop(),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),

        // Course selection
        Text(
          '1. 选择课程',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 8),

        if (_loadingCourses)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('正在加载 Canvas 课程...', style: TextStyle(fontSize: 13)),
              ],
            ),
          )
        else if (_courseError != null)
          Row(
            children: [
              Expanded(
                child: Text(_courseError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
              TextButton(onPressed: _loadCourses, child: const Text('重试')),
            ],
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<dynamic>(
                isExpanded: true,
                value: _selectedCourse,
                dropdownColor: isDark ? const Color(0xFF0C1D36) : Colors.white,
                hint: const Text('请选择一门课程'),
                items: _courses.map((c) {
                  final name = c['name'] ?? c['course_code'] ?? '未命名课程';
                  final code = c['course_code'];
                  return DropdownMenuItem<dynamic>(
                    value: c,
                    child: Text(
                      code != null && code != name ? '$name ($code)' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: _submitting ? null : (c) => _onSelectCourse(c),
              ),
            ),
          ),

        const SizedBox(height: 16),

        // Files selection
        Row(
          children: [
            Text(
              '2. 选择文件 (已选 ${_selectedFileIds.length} 个)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const Spacer(),
            if (_files.isNotEmpty && !_loadingFiles) ...[
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        setState(() {
                          _selectedFileIds.addAll(_files.map((f) => f['id'].toString()));
                        });
                      },
                child: const Text('全选', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        setState(() {
                          _selectedFileIds.clear();
                        });
                      },
                child: const Text('清空', style: TextStyle(fontSize: 12)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),

        // Search bar for files
        if (_files.isNotEmpty && !_loadingFiles)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            height: 38,
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _fileSearchQuery = val),
              style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                hintText: '搜索文件名...',
                hintStyle: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500),
                prefixIcon: Icon(Icons.search, size: 16, color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500),
                filled: true,
                fillColor: cardBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

        // File list container
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? const Color(0xFF1E4E79) : Colors.grey.shade300),
            ),
            child: _loadingFiles
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2),
                        SizedBox(height: 12),
                        Text('正在加载课程文件...', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  )
                : _fileError != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_fileError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                            const SizedBox(height: 8),
                            if (_selectedCourse != null)
                              ElevatedButton(
                                onPressed: () => _loadFiles(_selectedCourse['id'].toString()),
                                child: const Text('重试'),
                              ),
                          ],
                        ),
                      )
                    : filteredFiles.isEmpty
                        ? Center(
                            child: Text(
                              _files.isEmpty ? '该课程暂无可用文件' : '未找到匹配的文件',
                              style: TextStyle(
                                color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: filteredFiles.length,
                            separatorBuilder: (_, index) => Divider(
                              height: 1,
                              color: isDark ? const Color(0xFF1E4E79).withValues(alpha: 0.5) : Colors.grey.shade200,
                            ),
                            itemBuilder: (ctx, idx) {
                              final file = filteredFiles[idx];
                              final fileId = file['id'].toString();
                              final fileName = file['display_name'] ?? file['filename'] ?? '文件 $fileId';
                              final isSelected = _selectedFileIds.contains(fileId);
                              final sizeStr = _formatSize(file['size']);

                              return InkWell(
                                onTap: _submitting
                                    ? null
                                    : () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedFileIds.remove(fileId);
                                          } else {
                                            _selectedFileIds.add(fileId);
                                          }
                                        });
                                      },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Row(
                                    children: [
                                      Checkbox(
                                        value: isSelected,
                                        activeColor: primaryColor,
                                        onChanged: _submitting
                                            ? null
                                            : (val) {
                                                setState(() {
                                                  if (val == true) {
                                                    _selectedFileIds.add(fileId);
                                                  } else {
                                                    _selectedFileIds.remove(fileId);
                                                  }
                                                });
                                              },
                                      ),
                                      Icon(
                                        _getFileIcon(fileName),
                                        size: 20,
                                        color: isSelected
                                            ? (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0C132C))
                                            : (isDark ? Colors.white60 : Colors.grey.shade600),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              fileName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                                color: isDark ? Colors.white : Colors.black87,
                                              ),
                                            ),
                                            if (sizeStr.isNotEmpty)
                                              Text(
                                                sizeStr,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade500,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          Icons.download_outlined,
                                          size: 18,
                                          color: isDark ? Colors.white70 : Colors.grey.shade700,
                                        ),
                                        tooltip: '单独下载此文件',
                                        onPressed: _submitting ? null : () => _downloadSingleFile(file),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ),

        if (_submitError != null) ...[
          const SizedBox(height: 8),
          Text(_submitError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
        ],

        const SizedBox(height: 16),

        // Action Buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              child: Text(
                '取消',
                style: TextStyle(color: isDark ? const Color(0xFF8DA4C4) : Colors.grey.shade700),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: (_selectedFileIds.isEmpty || _submitting) ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(
                _submitting
                    ? '正在打包文件...'
                    : '打包下载选中文件 (${_selectedFileIds.length})',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
