import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'luma_sync_screen.dart';

class LumaEventsScreen extends StatefulWidget {
  const LumaEventsScreen({super.key});

  @override
  State<LumaEventsScreen> createState() => _LumaEventsScreenState();
}

class _LumaEventsScreenState extends State<LumaEventsScreen> {
  final ApiService _api = ApiService();

  // 地点：必须选择其一，默认旧金山
  String _selectedCity = 'san_francisco';

  // 类别多选：tech, ai, crypto（全不选则是全部）
  final Set<String> _selectedCategories = {};

  // 时间选择器：开始时间、结束时间
  DateTime? _startDate;
  DateTime? _endDate;

  int _currentPage = 1;
  final List<String?> _cursorHistory = [null]; // 游标历史栈，用于向前翻页
  bool _hasMore = false;
  String? _nextCursor;
  bool _isLoading = true;
  String? _error;
  List<dynamic> _events = [];

  final ScrollController _scrollController = ScrollController();

  final Map<String, String> _cities = {
    'san_francisco': '旧金山 (SF)',
    'berkeley': '伯克利 (Berkeley)',
    'shanghai': '上海 (Shanghai)',
  };

  final Map<String, String> _categoryLabels = {
    'tech': 'Tech',
    'ai': 'AI',
    'crypto': 'Crypto',
  };

  @override
  void initState() {
    super.initState();
    _fetchPage(1, null);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchPage(int targetPage, String? cursor) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final startDateStr = _startDate != null ? DateFormat('yyyy-MM-dd').format(_startDate!) : null;
      final endDateStr = _endDate != null ? DateFormat('yyyy-MM-dd').format(_endDate!) : null;

      final res = await _api.getLumaEvents(
        city: _selectedCity,
        categories: _selectedCategories.isNotEmpty ? _selectedCategories.toList() : null,
        startDate: startDateStr,
        endDate: endDateStr,
        limit: 50,
        cursor: cursor,
      );

      final entries = res['entries'] as List<dynamic>? ?? [];
      final hasMore = res['has_more'] as bool? ?? false;
      final nextCursor = res['next_cursor'] as String?;

      setState(() {
        _events = entries;
        _hasMore = hasMore;
        _nextCursor = nextCursor;
        _currentPage = targetPage;
        _isLoading = false;
      });

      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _resetPaginationAndReload() {
    setState(() {
      _currentPage = 1;
      _cursorHistory.clear();
      _cursorHistory.add(null);
      _events.clear();
      _nextCursor = null;
      _hasMore = false;
    });
    _fetchPage(1, null);
  }

  void _onCityChanged(String newCity) {
    if (_selectedCity == newCity) return;
    setState(() {
      _selectedCity = newCity;
    });
    _resetPaginationAndReload();
  }

  void _onCategoryToggled(String cat) {
    setState(() {
      if (_selectedCategories.contains(cat)) {
        _selectedCategories.remove(cat);
      } else {
        _selectedCategories.add(cat);
      }
    });
    _resetPaginationAndReload();
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
      helpText: '选择开始日期',
    );
    if (picked != null && picked != _startDate) {
      setState(() {
        _startDate = picked;
        // 如果开始时间晚于结束时间，则清空结束时间或同步
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = null;
        }
      });
      _resetPaginationAndReload();
    }
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? (_startDate ?? now),
      firstDate: _startDate ?? DateTime(2024),
      lastDate: DateTime(2030),
      helpText: '选择结束日期',
    );
    if (picked != null && picked != _endDate) {
      setState(() {
        _endDate = picked;
      });
      _resetPaginationAndReload();
    }
  }

  void _clearDates() {
    if (_startDate == null && _endDate == null) return;
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _resetPaginationAndReload();
  }

  void _onNextPage() {
    if (!_hasMore || _nextCursor == null || _isLoading) return;
    final nextPage = _currentPage + 1;
    if (_cursorHistory.length <= _currentPage) {
      _cursorHistory.add(_nextCursor);
    }
    _fetchPage(nextPage, _nextCursor);
  }

  void _onPrevPage() {
    if (_currentPage <= 1 || _isLoading) return;
    final prevPage = _currentPage - 1;
    final prevCursor = _cursorHistory[prevPage - 1];
    _fetchPage(prevPage, prevCursor);
  }

  String _formatDateTime(String? isoString, String? tz) {
    if (isoString == null || isoString.isEmpty) return '时间未定';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      final formatted = DateFormat('yyyy-MM-dd HH:mm').format(dt);
      return tz != null && tz.isNotEmpty ? '$formatted ($tz)' : formatted;
    } catch (_) {
      return isoString;
    }
  }

  void _showEventDetail(Map<String, dynamic> item) {
    final event = item['event'] as Map<String, dynamic>? ?? {};
    final eventApiId = event['api_id'] as String? ?? item['api_id'] as String? ?? '';
    final eventName = event['name'] as String? ?? '活动详情';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final tz = event['timezone'] as String? ?? '';
    final geo = event['geo_address_info'] as Map<String, dynamic>? ?? {};
    final address = geo['full_address'] ?? geo['address'] ?? geo['city'] ?? '线上活动 / 地点未标明';
    final ticketInfo = item['ticket_info'] as Map<String, dynamic>? ?? {};
    final isFree = ticketInfo['is_free'] as bool? ?? true;
    final requireApproval = ticketInfo['require_approval'] as bool? ?? false;
    final urlSlug = event['url'] as String? ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollCtrl) {
            return _EventDetailContent(
              api: _api,
              scrollController: scrollCtrl,
              eventApiId: eventApiId,
              eventName: eventName,
              startAtText: _formatDateTime(startAt, tz),
              endAtText: endAt != null ? _formatDateTime(endAt, tz) : null,
              address: address.toString(),
              isFree: isFree,
              requireApproval: requireApproval,
              urlSlug: urlSlug,
            );
          },
        );
      },
    );
  }

  Future<void> _showDumpMarkdownDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final startDateStr = _startDate != null ? DateFormat('yyyy-MM-dd').format(_startDate!) : null;
      final endDateStr = _endDate != null ? DateFormat('yyyy-MM-dd').format(_endDate!) : null;
      final currentCursor = _cursorHistory[_currentPage - 1];

      final res = await _api.getLumaDumpMarkdown(
        city: _selectedCity,
        categories: _selectedCategories.isNotEmpty ? _selectedCategories.toList() : null,
        startDate: startDateStr,
        endDate: endDateStr,
        page: _currentPage,
        cursor: currentCursor,
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      final dumpContent = res['content'] as String? ?? res['raw_content'] as String? ?? '';
      final totalEvents = res['total_events'] ?? _events.length;
      final charCount = res['char_count'] ?? dumpContent.length;
      final estimatedTokens = res['estimated_tokens'] ?? (charCount / 3.5).round();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (ctx) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.article_outlined, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('当前页 Markdown Dump'),
              ],
            ),
            content: SizedBox(
              width: 700,
              height: 500,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark ? Colors.white12 : Colors.grey.shade300,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatChip(Icons.event, '本页活动', '$totalEvents 个', false, isDark),
                        _buildStatChip(Icons.text_fields, '总字符数', '$charCount 字符', false, isDark),
                        _buildStatChip(Icons.token_outlined, '预估 Token', '~$estimatedTokens tokens', true, isDark),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '带行号的完整 Markdown 内容（可用于 Prompt 预估或引用）：',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF141414) : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isDark ? Colors.white12 : Colors.grey.shade300,
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          dumpContent,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制 Markdown'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: dumpContent));
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已复制当前页 Markdown Dump（~$estimatedTokens tokens）'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取 Dump 失败: $e')),
        );
      }
    }
  }

  Widget _buildStatChip(IconData icon, String label, String value, bool isHighlight, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isHighlight ? Colors.orangeAccent : Colors.blueAccent),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.grey.shade600)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isHighlight ? Colors.orangeAccent : (isDark ? Colors.white : Colors.black87),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Luma 活动列表'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync_outlined),
            tooltip: 'Luma Vault 手动同步',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LumaSyncScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: '获取当前页 Dump Markdown (预估 Token)',
            onPressed: _showDumpMarkdownDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              final cursor = _cursorHistory[_currentPage - 1];
              _fetchPage(_currentPage, cursor);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 顶部综合筛选面板（地点、多选类别、时间范围） ──
          _buildFilterPanel(isDark),

          // ── 活动列表主体 ──
          Expanded(
            child: _buildListBody(),
          ),

          // ── 底部分页导航栏（左右翻页，每页50个） ──
          _buildPaginationBar(isDark),
        ],
      ),
    );
  }

  Widget _buildFilterPanel(bool isDark) {
    final df = DateFormat('yyyy-MM-dd');
    final hasDateFilter = _startDate != null || _endDate != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white12 : Colors.grey.shade300,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 地点选择器（单选，必须选择其一，默认旧金山）
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 18, color: Colors.blueAccent),
              const SizedBox(width: 6),
              const Text(
                '地点:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _cities.entries.map((entry) {
                      final isSelected = _selectedCity == entry.key;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(entry.value),
                          selected: isSelected,
                          onSelected: (selected) {
                            if (selected) _onCityChanged(entry.key);
                          },
                          selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                          labelStyle: TextStyle(
                            color: isSelected
                                ? Colors.blueAccent
                                : (isDark ? Colors.white70 : Colors.black87),
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            fontSize: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 2. 类别多选选择器（tech, ai, crypto，多选，全不选为全部）
          Row(
            children: [
              const Icon(Icons.category_outlined, size: 18, color: Colors.orangeAccent),
              const SizedBox(width: 6),
              const Text(
                '类别:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 全部（快捷提示芯片）
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: const Text('全部'),
                          selected: _selectedCategories.isEmpty,
                          onSelected: (selected) {
                            if (selected && _selectedCategories.isNotEmpty) {
                              setState(() {
                                _selectedCategories.clear();
                              });
                              _resetPaginationAndReload();
                            }
                          },
                          selectedColor: Colors.orangeAccent.withValues(alpha: 0.2),
                          labelStyle: TextStyle(
                            color: _selectedCategories.isEmpty
                                ? Colors.orangeAccent
                                : (isDark ? Colors.white70 : Colors.black87),
                            fontWeight: _selectedCategories.isEmpty ? FontWeight.w600 : FontWeight.normal,
                            fontSize: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      ..._categoryLabels.entries.map((entry) {
                        final isSelected = _selectedCategories.contains(entry.key);
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(entry.value),
                            selected: isSelected,
                            onSelected: (_) => _onCategoryToggled(entry.key),
                            selectedColor: Colors.orangeAccent.withValues(alpha: 0.2),
                            labelStyle: TextStyle(
                              color: isSelected
                                  ? Colors.orangeAccent
                                  : (isDark ? Colors.white70 : Colors.black87),
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              fontSize: 12,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 3. 时间范围选择器（开始时间、结束时间，支持单独/组合输入与清除）
          Row(
            children: [
              const Icon(Icons.date_range_outlined, size: 18, color: Colors.green),
              const SizedBox(width: 6),
              const Text(
                '时间:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(width: 8),

              // 开始日期按钮
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                    color: _startDate != null ? Colors.blueAccent : Colors.grey.shade400,
                  ),
                ),
                icon: const Icon(Icons.event, size: 14),
                label: Text(
                  _startDate != null ? df.format(_startDate!) : '开始日期',
                  style: TextStyle(
                    fontSize: 12,
                    color: _startDate != null ? Colors.blueAccent : (isDark ? Colors.white70 : Colors.black87),
                  ),
                ),
                onPressed: _pickStartDate,
              ),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('~', style: TextStyle(fontWeight: FontWeight.bold)),
              ),

              // 结束日期按钮
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                    color: _endDate != null ? Colors.blueAccent : Colors.grey.shade400,
                  ),
                ),
                icon: const Icon(Icons.event, size: 14),
                label: Text(
                  _endDate != null ? df.format(_endDate!) : '结束日期',
                  style: TextStyle(
                    fontSize: 12,
                    color: _endDate != null ? Colors.blueAccent : (isDark ? Colors.white70 : Colors.black87),
                  ),
                ),
                onPressed: _pickEndDate,
              ),

              if (hasDateFilter) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  tooltip: '清除时间筛选',
                  onPressed: _clearDates,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              const Text(
                '加载活动失败',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                onPressed: () {
                  final cursor = _cursorHistory[_currentPage - 1];
                  _fetchPage(_currentPage, cursor);
                },
              )
            ],
          ),
        ),
      );
    }

    if (_events.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy_outlined, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '当前筛选条件下暂无活动',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _events[index] as Map<String, dynamic>;
        final event = item['event'] as Map<String, dynamic>? ?? {};
        final name = event['name'] as String? ?? '未命名活动';
        final startAt = event['start_at'] as String?;
        final tz = event['timezone'] as String? ?? '';
        final geo = event['geo_address_info'] as Map<String, dynamic>? ?? {};
        final address = geo['city'] ?? geo['address'] ?? geo['full_address'] ?? '地点未标明';
        final coverUrl = event['cover_url'] as String?;
        final ticketInfo = item['ticket_info'] as Map<String, dynamic>? ?? {};
        final isFree = ticketInfo['is_free'] as bool? ?? true;
        final requireApproval = ticketInfo['require_approval'] as bool? ?? false;
        final hosts = item['hosts'] as List<dynamic>? ?? [];
        final hostName = hosts.isNotEmpty ? (hosts[0]['name'] as String? ?? '') : '';

        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isDark ? Colors.white12 : Colors.grey.shade200,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面图或占位图
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: coverUrl != null && coverUrl.isNotEmpty
                      ? Image.network(
                          coverUrl,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildPlaceholderImage(),
                        )
                      : _buildPlaceholderImage(),
                ),
                const SizedBox(width: 12),

                // 活动核心信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _formatDateTime(startAt, tz),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.place_outlined, size: 14, color: Colors.grey.shade600),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              address.toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                      if (hostName.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.person_outline, size: 14, color: Colors.grey.shade600),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '主办: $hostName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),

                      // 标签与“查看详情”按钮
                      Row(
                        children: [
                          // 费用标签
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isFree
                                  ? Colors.green.withValues(alpha: 0.15)
                                  : Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isFree ? '免费' : '付费',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isFree ? Colors.green.shade700 : Colors.orange.shade800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),

                          // 审核标签
                          if (requireApproval)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.purple.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '需批准',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.purple,
                                ),
                              ),
                            ),

                          const Spacer(),

                          // 查看详情按钮
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => _showEventDetail(item),
                            child: const Row(
                              children: [
                                Text('查看详情', style: TextStyle(fontSize: 13)),
                                SizedBox(width: 2),
                                Icon(Icons.chevron_right, size: 16),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      width: 80,
      height: 80,
      color: Colors.blueGrey.withValues(alpha: 0.15),
      child: const Icon(Icons.event_outlined, color: Colors.blueGrey, size: 32),
    );
  }

  Widget _buildPaginationBar(bool isDark) {
    final canPrev = _currentPage > 1 && !_isLoading;
    final canNext = _hasMore && !_isLoading;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white12 : Colors.grey.shade300,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('上一页'),
              onPressed: canPrev ? _onPrevPage : null,
              style: ElevatedButton.styleFrom(
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            Text(
              '第 $_currentPage 页 (本页 ${_events.length} 条)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            ElevatedButton.icon(
              label: const Text('下一页'),
              icon: const Icon(Icons.arrow_forward, size: 16),
              onPressed: canNext ? _onNextPage : null,
              style: ElevatedButton.styleFrom(
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventDetailContent extends StatefulWidget {
  final ApiService api;
  final ScrollController scrollController;
  final String eventApiId;
  final String eventName;
  final String startAtText;
  final String? endAtText;
  final String address;
  final bool isFree;
  final bool requireApproval;
  final String urlSlug;

  const _EventDetailContent({
    required this.api,
    required this.scrollController,
    required this.eventApiId,
    required this.eventName,
    required this.startAtText,
    required this.endAtText,
    required this.address,
    required this.isFree,
    required this.requireApproval,
    required this.urlSlug,
  });

  @override
  State<_EventDetailContent> createState() => _EventDetailContentState();
}

class _EventDetailContentState extends State<_EventDetailContent> {
  bool _loadingDetail = true;
  String _markdownDescription = '';
  List<dynamic> _ticketTypes = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    if (widget.eventApiId.isEmpty) {
      setState(() => _loadingDetail = false);
      return;
    }
    try {
      final data = await widget.api.getLumaEventDetail(widget.eventApiId);
      setState(() {
        _markdownDescription = data['description_markdown'] as String? ?? '';
        _ticketTypes = data['ticket_types'] as List<dynamic>? ?? [];
        _loadingDetail = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingDetail = false;
      });
    }
  }

  void _openInLuma() async {
    if (widget.urlSlug.isEmpty) return;
    final uri = Uri.parse('https://luma.com/${widget.urlSlug}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部拖拽指示器
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // 标题与关闭按钮
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  widget.eventName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const Divider(),

          // 核心元数据卡片（时间地点、费用、审核要求、票种）
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildInfoRow(
                  Icons.schedule,
                  '时间',
                  widget.endAtText != null
                      ? '${widget.startAtText} ~ ${widget.endAtText}'
                      : widget.startAtText,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.place_outlined,
                  '地点',
                  widget.address,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.payments_outlined,
                  '费用',
                  widget.isFree ? '免费' : '付费活动',
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.how_to_reg_outlined,
                  '审核机制',
                  widget.requireApproval ? '需要主办方申请批准 / 审核' : '无需申请批准，可直接参加',
                ),
                if (_ticketTypes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildInfoRow(
                    Icons.confirmation_number_outlined,
                    '票种信息',
                    _ticketTypes.map((t) {
                      final tName = t['name'] as String? ?? '标准票';
                      final isTFree = t['type'] == 'free' || t['cents'] == null;
                      final cents = t['cents'];
                      final priceStr = isTFree ? '免费' : (cents is num ? '\$${(cents / 100).toStringAsFixed(2)}' : '收费');
                      return '$tName ($priceStr)';
                    }).join(', '),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 外部跳转按钮
          if (widget.urlSlug.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('在 Luma 官网查看与报名'),
                onPressed: _openInLuma,
              ),
            ),

          const SizedBox(height: 12),
          const Text(
            '活动完整说明',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),

          // 完整正文说明
          Expanded(
            child: _loadingDetail
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(
                          '获取详细说明失败: $_error',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : SingleChildScrollView(
                        controller: widget.scrollController,
                        child: _markdownDescription.isNotEmpty
                            ? MarkdownBody(
                                data: _markdownDescription,
                                selectable: true,
                                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                  tableColumnWidth: const IntrinsicColumnWidth(),
                                  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  tablePadding: const EdgeInsets.symmetric(vertical: 8),
                                  tableBorder: TableBorder.all(
                                    color: Colors.grey.shade300,
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
                                    await launchUrl(
                                      Uri.parse(urlStr),
                                      mode: LaunchMode.externalApplication,
                                      webOnlyWindowName: '_blank',
                                    );
                                  } catch (e) {
                                    debugPrint('Failed to open URL $href: $e');
                                  }
                                },
                              )
                            : Text(
                                '主办方暂未提供详细图文说明。',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Colors.blueAccent),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
