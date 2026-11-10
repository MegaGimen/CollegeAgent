import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/file_picker_service.dart';

class PersonalVaultScreen extends StatefulWidget {
  final String userId;
  const PersonalVaultScreen({super.key, required this.userId});

  @override
  State<PersonalVaultScreen> createState() => _PersonalVaultScreenState();
}

class _PersonalVaultScreenState extends State<PersonalVaultScreen> {
  final ApiService _api = ApiService();
  List<dynamic> _files = [];
  bool _loading = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    try {
      final res = await http.get(
        Uri.parse('${_api.baseUrl}/api/vault/personal?userId=${widget.userId}'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _files = data['files'] ?? [];
        });
      }
    } catch (e) {
      debugPrint('Error loading personal vault: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _uploadFile() async {
    try {
      final pickedFiles = await AppFilePicker.pickFiles(
        allowMultiple: true,
        allowedExtensions: [
          'pdf', 'ppt', 'pptx', 'xls', 'xlsx', 'doc', 'docx', 'txt', 'csv', 'md'
        ],
      );

      if (pickedFiles.isEmpty) return;

      setState(() => _uploading = true);

      int successCount = 0;
      final failedFiles = <String>[];

      for (final file in pickedFiles) {
        try {
          final request = http.MultipartRequest(
            'POST',
            Uri.parse('${_api.baseUrl}/api/vault/personal/upload'),
          );
          request.fields['userId'] = widget.userId;
          request.files.add(http.MultipartFile.fromBytes(
            'file',
            file.bytes,
            filename: file.name,
          ));

          final streamedResponse = await request.send();
          if (streamedResponse.statusCode == 200) {
            successCount++;
          } else {
            failedFiles.add(file.name);
          }
        } catch (err) {
          failedFiles.add(file.name);
        }
      }

      await _loadFiles();
      if (mounted) {
        setState(() => _uploading = false);
        if (failedFiles.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('成功上传并解析 $successCount 个文档'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已上传 $successCount 个文档，失败：${failedFiles.join(", ")}'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteFile(String nodeId) async {
    try {
      final res = await http.delete(
        Uri.parse('${_api.baseUrl}/api/vault/personal/$nodeId?userId=${widget.userId}'),
      );
      if (res.statusCode == 200) {
        _loadFiles();
      }
    } catch (e) {
      debugPrint('Error deleting file: $e');
    }
  }

  void _showMarkdownPreview(dynamic fileNode) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF081226) : Colors.white,
        title: Text(
          fileNode['title'] ?? 'Document Preview',
          style: TextStyle(color: isDark ? Colors.white : Colors.black87),
        ),
        content: SizedBox(
          width: 800,
          height: 600,
          child: SelectionArea(
            child: Markdown(
              data: fileNode['content'] ?? 'No content',
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
                p: TextStyle(
                  color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                  fontSize: 13,
                  height: 1.6,
                ),
                h1: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                h2: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                h3: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                strong: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                code: TextStyle(
                  backgroundColor: isDark ? const Color(0xFF01385F) : Colors.grey.shade200,
                  color: isDark ? const Color(0xFF93C5FD) : Colors.black87,
                  fontFamily: 'monospace',
                ),
                tableColumnWidth: const IntrinsicColumnWidth(),
                tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                tablePadding: const EdgeInsets.symmetric(vertical: 8),
                tableBorder: TableBorder.all(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(4),
                ),
                tableHead: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                tableBody: TextStyle(
                  color: isDark ? const Color(0xFFF1F5F9) : Colors.black87,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Close',
              style: TextStyle(color: isDark ? const Color(0xFF38BDF8) : null),
            ),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Personal Vault'),
        actions: [
          if (_uploading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Upload Document',
            onPressed: _uploading ? null : _uploadFile,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Text(
                        '个人知识库为空。点击右上角上传 PDF、PPTX、DOCX、XLSX 等文档。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (ctx, i) {
                      final f = _files[i];
                      return ListTile(
                        leading: const Icon(Icons.description, color: Colors.blueAccent),
                        title: Text(f['title'] ?? 'Untitled'),
                        subtitle: Text(
                          f['date'] != null ? f['date'].toString().substring(0, 10) : '',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.visibility_outlined),
                              tooltip: 'Preview Markdown',
                              onPressed: () => _showMarkdownPreview(f),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: 'Delete',
                              onPressed: () => _deleteFile(f['id']),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
